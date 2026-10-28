#if SQUIRCLE_OVERLAY || DEBUG
import Darwin
import MachO
import Synchronization
import UIKit

/// Records how the host app performs, from inside its own process: every
/// display refresh, what actually reached the screen (each CAMetalLayer
/// drawable's presented time), GPU time per command buffer and per pass,
/// every thread's stacks and CPU, memory, thermal and power state, frame-rate
/// requests and touches. The Mac names the app's frames from
/// the build's dSYM (`squircle perf`). Not the app's log: `OSLogStore` reads
/// the process's whole log to find a window of it, which took seconds in the
/// simulator and longer on the phone, every time a recording stopped.
@MainActor
final class PerfRecorder: CaptureProducer {
    private let sampler: ThreadSampler
    private let probe: GPUProbe
    private var link: CADisplayLink?
    private let started = CACurrentMediaTime()
    private let startDate = Date()
    private var frames: [FrameTiming] = []
    private var hitchScreens: [(Double, String)] = []
    /// The app left the foreground or became inactive since the last frame:
    /// the next frame's gap is no frame.
    private var interrupted = false
    private let touches: TouchTracker
    private var events: [[String: Any]] = []
    private var observers: [NSObjectProtocol] = []
    private weak var overlay: UIWindow?
    private weak var scene: UIWindowScene?

    convenience init(below overlay: UIWindow) { self.init(scene: overlay.windowScene, excluding: overlay) }

    init(scene: UIWindowScene?, excluding overlay: UIWindow?) {
        self.overlay = overlay
        self.scene = scene
        sampler = ThreadSampler()
        probe = GPUProbe()
        touches = TouchTracker(origin: started)
        frames.reserveCapacity(8_000)
        sampler.start()
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] link in self?.tick(link) }, selector: #selector(DisplayLinkProxy.tick(_:)))
        // At the display's full rate: a default link runs at 60 Hz on
        // ProMotion and would miss every other frame of a 120 Hz scroll.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        probe.watchFrameRates(origin: started)
        touches.attach(to: scene?.windows.filter { $0 !== overlay } ?? [])
        let center = NotificationCenter.default
        for (name, kind) in [(ProcessInfo.thermalStateDidChangeNotification, "thermal"),
                             (Notification.Name.NSProcessInfoPowerStateDidChange, "low-power")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.event(kind) }
            })
        }
        for (name, kind) in [(UIApplication.didEnterBackgroundNotification, "background"),
                             (UIApplication.willEnterForegroundNotification, "foreground"),
                             (UIApplication.willResignActiveNotification, "inactive"),
                             (UIApplication.didBecomeActiveNotification, "active"),
                             (UIApplication.didReceiveMemoryWarningNotification, "memory-warning")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.event(kind) }
            })
        }
    }

    deinit {
        // Never left running past its owner, finished or not.
        sampler.abandon()
        probe.uninstall()
        link?.invalidate()
    }

    private func event(_ kind: String) {
        var event: [String: Any] = ["t": CACurrentMediaTime() - started, "kind": kind]
        switch kind {
        case "thermal": event["state"] = ThreadSampler.thermal(ProcessInfo.processInfo.thermalState)
        case "low-power": event["on"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        case "memory-warning": break
        default: interrupted = true
        }
        events.append(event)
    }

    private func tick(_ link: CADisplayLink) {
        let frame = FrameTiming(time: link.timestamp - started, period: max(0.001, link.targetTimestamp - link.timestamp),
                                resumed: interrupted || frames.isEmpty)
        interrupted = false
        // A late frame: note what was on screen while it was late.
        if let last = frames.last, let gap = FrameGap(from: last, to: frame), gap.late {
            hitchScreens.append((last.time, Self.screenName(in: scene, excluding: overlay) ?? ""))
        }
        frames.append(frame)
    }

    func cancel() {
        stopProducing()
        _ = sampler.stop()
        probe.uninstall()
    }

    private func stopProducing() {
        link?.invalidate()
        link = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        _ = touches.detach()
    }

    /// Stops and writes the capture as JSON; returns its file, how long it
    /// ran and its frame times (for the thumbnail).
    func finish() async -> CaptureOutput? {
        let touchEvents = touches.events
        stopProducing()
        let duration = CACurrentMediaTime() - started
        let raw = sampler.stop()
        let metal = probe.finish(origin: started)
        let frames = self.frames, screens = hitchScreens
        // The thumbnail charts what reached the screen: new Metal frames when
        // the app draws with Metal, display refreshes otherwise.
        let presented = Self.presented(metal, period: frames.last?.period ?? 1.0 / 60)
        let gaps = FrameGap.all(presented.count > 1 ? presented : frames)
        // Late display refreshes (the main thread missed one), with the screen they were on.
        let hitches = FrameGap.all(frames).filter(\.late).map { hitch -> [String: Any] in
            let screen = screens.last { abs($0.0 - hitch.start) < 0.0005 }?.1 ?? ""
            return ["start": hitch.start, "duration": hitch.overdue, "period": hitch.period, "screen": screen]
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let device = UIDevice.current
        var app: [String: Any] = [
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "name": info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "executable": info["CFBundleExecutable"] as? String ?? ""
        ]
        if let id = info["SquircleBuildID"] as? String, !id.isEmpty { app["squircle_build_id"] = id }
        let screen = scene?.screen ?? UIScreen.main
        let header: [String: Any] = [
            "format": "squircle-perf", "version": 2,
            "app": app,
            "device": ["model": Self.machine(), "system": device.systemName + " " + device.systemVersion, "os_build": Self.osBuild(),
                       "simulator": ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil],
            "started_at": startDate.timeIntervalSince1970,
            "duration": duration,
            "refresh_hz": FrameGap.usualRate(frames),
            "display": ["max_fps": screen.maximumFramesPerSecond,
                        // Without it an iPhone app's own display links stay at 60 Hz.
                        "promotion_unlocked": info["CADisableMinimumFrameDurationOnPhone"] as? Bool ?? false,
                        "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
                        "thermal": ThreadSampler.thermal(ProcessInfo.processInfo.thermalState)] as [String: Any],
            "main_thread": Double(raw.mainID),
            "metal": metal,
            "sample_interval_ms": ThreadSampler.interval * 1000,
            "thread_sample_interval_ms": ThreadSampler.interval * Double(ThreadSampler.othersEvery) * 1000,
            "frames": frames.map { ($0.time * 10_000).rounded() / 10_000 },
            // Each frame's expected period, and the frames that follow a
            // pause (the app inactive or away): their gap is no frame.
            "periods": frames.map { ($0.period * 100_000).rounded() / 100_000 },
            "resumed": frames.indices.filter { frames[$0].resumed },
            "hitches": hitches,
            "events": (events + touchEvents + (metal["events"] as? [[String: Any]] ?? [])).sorted { ($0["t"] as? Double ?? 0) < ($1["t"] as? Double ?? 0) }
        ]
        let origin = started
        return await Task.detached(priority: .userInitiated) {
            var json = header
            json.merge(raw.export(origin: origin)) { a, _ in a }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).perf.json")
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                  (try? data.write(to: url)) != nil else { return nil }
            return CaptureOutput.performance(url: url, duration: duration, gaps: gaps, hitches: gaps.filter(\.late).count)
        }.value
    }

    #if DEBUG
    /// Verification only, in a Debug overlay injected into an app in the
    /// simulator, with no paired connection: `SQUIRCLE_PERF_HEADLESS=PATH`
    /// records for `SQUIRCLE_PERF_SECONDS` (default 10), starting
    /// `SQUIRCLE_PERF_DELAY` seconds (default 3) after the app's first scene
    /// is active, and writes the capture to PATH.
    nonisolated static func headlessIfAsked() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SQUIRCLE_PERF_HEADLESS"] else { return }
        let delay = environment["SQUIRCLE_PERF_DELAY"].flatMap(Double.init) ?? 3
        let seconds = environment["SQUIRCLE_PERF_SECONDS"].flatMap(Double.init) ?? 10
        Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: UIScene.didActivateNotification) { break }
            try? await Task.sleep(for: .seconds(delay))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            let recorder = PerfRecorder(scene: scene, excluding: nil)
            try? await Task.sleep(for: .seconds(seconds))
            guard let output = await recorder.finish() else { return print("SQUIRCLE_PERF failed") }
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.moveItem(at: output.url, to: URL(fileURLWithPath: path))
            print("SQUIRCLE_PERF wrote \(path)")
        }
    }
    #endif

    /// Screen frames with new Metal content: every distinct time a drawable
    /// reached the screen, as frames for the thumbnail.
    private static func presented(_ metal: [String: Any], period: Double) -> [FrameTiming] {
        let drawables = metal["drawables"] as? [[Double]] ?? []
        // On-glass times where the device reports them, else present calls.
        var times = drawables.compactMap { $0.count > 3 && $0[3] > 0 ? $0[3] : nil }
        if times.isEmpty { times = drawables.compactMap { $0.count > 5 && $0[5] > 0 ? $0[5] : nil } }
        var frames: [FrameTiming] = []
        for time in times.sorted() {
            guard let last = frames.last else {
                frames.append(FrameTiming(time: time, period: period, resumed: true))
                continue
            }
            // Layers shown together are one frame; after a still screen,
            // the gap is no late frame.
            if time - last.time > 0.002 { frames.append(FrameTiming(time: time, period: period, resumed: time - last.time > 0.25)) }
        }
        return frames
    }

    /// The innermost view controller showing in the app's key window.
    private static func screenName(in scene: UIWindowScene?, excluding overlay: UIWindow?) -> String? {
        let windows = scene?.windows.filter { $0 !== overlay && !$0.isHidden } ?? []
        guard var top = (windows.first { $0.isKeyWindow } ?? windows.last)?.rootViewController else { return nil }
        while true {
            if let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            else if let nav = top as? UINavigationController, let next = nav.visibleViewController { top = next }
            else if let tabs = top as? UITabBarController, let next = tabs.selectedViewController { top = next }
            else { break }
        }
        return String(describing: type(of: top))
    }

    /// The OS build, e.g. 24A435: which of Xcode's device symbols match.
    private static func osBuild() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("kern.osversion", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    private static func machine() -> String {
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return model }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// One display-link frame: when it came and the period the display was
/// running at, which is when the next one is due.
struct FrameTiming: Equatable, Sendable {
    let time: Double
    let period: Double
    /// The first frame, or the first after the app was inactive or away.
    let resumed: Bool
}

/// The time between two frames, against the deadline the first one set.
struct FrameGap: Equatable, Sendable {
    let start: Double
    let end: Double
    let period: Double

    /// Nil across a pause: that time is not a frame.
    init?(from previous: FrameTiming, to next: FrameTiming) {
        guard !next.resumed else { return nil }
        (start, end, period) = (previous.time, next.time, previous.period)
    }

    var length: Double { end - start }
    /// More than half a frame past due.
    var late: Bool { length > period * 1.5 }
    /// How long past due it came.
    var overdue: Double { length - period }

    static func all(_ frames: [FrameTiming]) -> [FrameGap] {
        zip(frames, frames.dropFirst()).compactMap { FrameGap(from: $0, to: $1) }
    }

    /// The rate most frames ran at, for the summary.
    static func usualRate(_ frames: [FrameTiming]) -> Double {
        var counts: [Double: Int] = [:]
        for frame in frames { counts[(1 / frame.period).rounded(), default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? 60
    }
}

/// Sees every touch in the app's windows without taking part: it never
/// recognizes, never delays or cancels a touch, and can't be prevented.
final class TouchTracker {
    private let origin: Double
    private var recognizers: [Observer] = []
    private(set) var events: [[String: Any]] = []
    /// Where fingers are now, for drawing into a screen recording.
    private(set) var live: [ObjectIdentifier: CGPoint] = [:]

    init(origin: Double) { self.origin = origin }

    @MainActor func attach(to windows: [UIWindow]) {
        for window in windows {
            let observer = Observer(tracker: self)
            window.addGestureRecognizer(observer)
            recognizers.append(observer)
        }
    }

    @MainActor func detach() -> [[String: Any]] {
        for recognizer in recognizers { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizers = []
        live = [:]
        return events
    }

    fileprivate func record(_ touches: Set<UITouch>, phase: String, in view: UIView?) {
        for touch in touches {
            let point = touch.location(in: nil)
            let key = ObjectIdentifier(touch)
            if phase == "up" { live[key] = nil } else { live[key] = point }
            guard phase != "move" else { continue }
            if events.count < 5_000 {
                events.append(["t": touch.timestamp - origin, "kind": "touch-" + phase,
                               "x": (point.x * 10).rounded() / 10, "y": (point.y * 10).rounded() / 10])
            }
        }
    }

    private final class Observer: UIGestureRecognizer {
        weak var tracker: TouchTracker?
        init(tracker: TouchTracker) {
            self.tracker = tracker
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { tracker?.record(touches, phase: "down", in: view) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { tracker?.record(touches, phase: "move", in: view) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
        private func finish(_ touches: Set<UITouch>) {
            tracker?.record(touches, phase: "up", in: view)
            if numberOfTouches <= touches.count { state = .failed }
        }
    }
}

/// Samples the app's threads' call stacks from a background thread: the
/// main thread about once a millisecond (wall time, so its waits show), and
/// every thread that used CPU about every 4 ms, each sample weighted by the
/// CPU time that thread used since its last one.
///
/// Never freezes the app: between suspending a thread and resuming it, the
/// sampler makes kernel calls only (`thread_get_state`, and `mach_vm_region`
/// the first time it sees a thread, for its stack's bounds) and reads memory
/// only inside that thread's own stack, so it can never wait on a lock the
/// thread holds (malloc, the Swift runtime, dyld). Everything that allocates
/// happens after the resume. A sample that can't be read is skipped; the
/// thread is resumed on every path.
final class ThreadSampler: Thread, @unchecked Sendable {
    static let interval = 0.001
    static let othersEvery = 4
    private static let maxDepth = 192

    private let mainThread: thread_act_t
    let mainID: UInt64
    private let mainBounds: (UInt64, UInt64)
    private let done = Atomic<Bool>(false)
    private let exited = NSCondition()
    private var hasExited = false
    /// Filled only after each resume.
    private var stacks: [[UInt64]] = []
    private var index: [[UInt64]: Int] = [:]
    private var samples: [(Double, Int32)] = []
    /// (time, stack, thread ID, CPU microseconds since that thread's last sample)
    private var threadSamples: [(Double, Int32, UInt64, Int32)] = []
    private var threads: [UInt64: ThreadRecord] = [:]
    private var bounds: [UInt64: (UInt64, UInt64)] = [:]
    private var metrics: [[String: Any]] = []

    struct ThreadRecord { var name: String; var cpu: UInt64; var first: UInt64; var priority: Int32 }

    /// Call on the main thread.
    override init() {
        precondition(Foundation.Thread.isMainThread)
        mainThread = mach_thread_self()
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        mainID = id
        let top = UInt64(UInt(bitPattern: pthread_get_stackaddr_np(pthread_self())))
        mainBounds = (top - UInt64(pthread_get_stacksize_np(pthread_self())), top)
        super.init()
        name = "Squircle perf sampler"
        qualityOfService = .userInteractive
        samples.reserveCapacity(70_000)
        threadSamples.reserveCapacity(70_000)
    }

    deinit {
        mach_port_deallocate(mach_task_self_, mainThread)
    }

    override func main() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let toSeconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let buffer = UnsafeMutablePointer<UInt64>.allocate(capacity: Self.maxDepth)
        defer { buffer.deallocate() }
        let me = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, me) }
        var nextMetrics = 0.0
        var lastCPU: (wall: Double, main: Double, all: Double)?
        var tick = 0
        while !done.load(ordering: .relaxed) {
            let now = Double(mach_absolute_time()) * toSeconds
            var known: (UInt64, UInt64)? = mainBounds
            let depth = Self.capture(mainThread, bounds: &known, into: buffer)
            if depth > 0, samples.count < 200_000 { samples.append((now, intern(buffer, depth))) }
            if tick % Self.othersEvery == 0 { sampleThreads(at: now, skipping: me, into: buffer) }
            tick += 1
            if now >= nextMetrics {
                nextMetrics = now + 0.25
                let cpu = Self.cpuTimes(main: mainThread)
                var sample: [String: Any] = ["t": now, "memory_mb": Self.footprint() / 1_048_576,
                                             "thermal": Self.thermal(ProcessInfo.processInfo.thermalState)]
                if let last = lastCPU, now > last.wall {
                    // A thread that exits takes its time with it: never below zero.
                    sample["cpu"] = max(0, ((cpu.all - last.all) / (now - last.wall) * 100).rounded())
                    sample["main_cpu"] = ((cpu.main - last.main) / (now - last.wall) * 100).rounded()
                }
                lastCPU = (now, cpu.main, cpu.all)
                metrics.append(sample)
            }
            usleep(UInt32(Self.interval * 1_000_000))
        }
        exited.lock()
        hasExited = true
        exited.signal()
        exited.unlock()
    }

    private func intern(_ buffer: UnsafeMutablePointer<UInt64>, _ depth: Int) -> Int32 {
        let stack = Array(UnsafeBufferPointer(start: buffer, count: depth))
        if let known = index[stack] { return Int32(known) }
        stacks.append(stack)
        index[stack] = stacks.count - 1
        return Int32(stacks.count - 1)
    }

    /// Every thread that ran since its last sample, the main thread too.
    private func sampleThreads(at now: Double, skipping me: thread_act_t, into buffer: UnsafeMutablePointer<UInt64>) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return }
        for i in 0..<Int(count) {
            let thread = list[i]
            defer { mach_port_deallocate(mach_task_self_, thread) }
            guard thread != me, let (id, cpu, name, priority, running) = Self.info(thread) else { continue }
            var record = threads[id] ?? ThreadRecord(name: name, cpu: cpu, first: cpu, priority: priority)
            let used = cpu &- record.cpu
            if !name.isEmpty { record.name = name }
            record.cpu = cpu
            record.priority = priority
            threads[id] = record
            // Real-time threads (audio) are timed but never held: a pause there is audible.
            guard used > 0 || running, priority < 97, threadSamples.count < 300_000 else { continue }
            var known = thread == mainThread ? mainBounds : bounds[id]
            let depth = Self.capture(thread, bounds: &known, into: buffer)
            if let known { bounds[id] = known }
            if depth > 0 { threadSamples.append((now, intern(buffer, depth), id, Int32(clamping: used / 1_000))) }
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    }

    /// A thread's ID, CPU nanoseconds, name, priority and whether it is running.
    private static func info(_ thread: thread_act_t) -> (UInt64, UInt64, String, Int32, Bool)? {
        var identifier = thread_identifier_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
        let gotID = withUnsafeMutablePointer(to: &identifier) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &size) }
        }
        var extended = thread_extended_info_data_t()
        size = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
        let gotInfo = withUnsafeMutablePointer(to: &extended) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &size) }
        }
        guard gotID == KERN_SUCCESS, gotInfo == KERN_SUCCESS else { return nil }
        let name = withUnsafeBytes(of: extended.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (identifier.thread_id, extended.pth_user_time &+ extended.pth_system_time, name, extended.pth_curpri,
                extended.pth_run_state == TH_STATE_RUNNING)
    }

    /// One stack, leaf first, into `buffer`. Nothing in here allocates.
    /// `bounds` is the thread's stack; when nil it is looked up from its
    /// stack pointer while the thread is held.
    private static func capture(_ target: thread_act_t, bounds: inout (UInt64, UInt64)?, into buffer: UnsafeMutablePointer<UInt64>) -> Int {
        #if arch(arm64)
        // Plain locals: no lazily initialised globals, which take a lock.
        let mask: UInt64 = 0x0000_000F_FFFF_FFFF, maxDepth = 192
        guard thread_suspend(target) == KERN_SUCCESS else { return 0 }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(target, ARM_THREAD_STATE64, $0, &count) }
        }
        var depth = 0
        if read == KERN_SUCCESS {
            if bounds == nil { bounds = stackRegion(containing: UInt64(state.__sp)) }
            buffer[0] = UInt64(state.__pc) & mask
            buffer[1] = UInt64(state.__lr) & mask
            depth = 2
            if let (low, high) = bounds {
                var fp = UInt64(state.__fp)
                // Each frame record is {previous fp, return address}, always
                // inside the stack and always further up it.
                while depth < maxDepth, fp >= low, fp + 16 <= high, fp & 0xF == 0 {
                    guard let record = UnsafePointer<UInt64>(bitPattern: UInt(fp)) else { break }
                    let next = record[0], ret = record[1] & mask
                    guard ret != 0 else { break }
                    // A leaf that saved its frame already has the lr as its return address.
                    if !(depth == 2 && ret == buffer[1]) {
                        buffer[depth] = ret
                        depth += 1
                    }
                    guard next > fp else { break }
                    fp = next
                }
            }
        }
        thread_resume(target)
        return depth
        #else
        return 0
        #endif
    }

    /// The VM region holding `sp`: the thread's stack.
    private static func stackRegion(containing sp: UInt64) -> (UInt64, UInt64)? {
        var address = vm_address_t(sp), size = vm_size_t(0)
        var info = vm_region_basic_info_data_64_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
        var object: mach_port_t = 0
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                vm_region_64(mach_task_self_, &address, &size, VM_REGION_BASIC_INFO_64, $0, &count, &object)
            }
        }
        guard result == KERN_SUCCESS, UInt64(address) <= sp, sp < UInt64(address + size) else { return nil }
        return (UInt64(address), UInt64(address + size))
    }

    /// Asks it to stop without waiting (its owner is gone).
    func abandon() { done.store(true, ordering: .relaxed) }

    /// Stops sampling and hands over what it recorded.
    func stop() -> ThreadSamples {
        done.store(true, ordering: .relaxed)
        exited.lock()
        while !hasExited, isExecuting { _ = exited.wait(until: Date().addingTimeInterval(1)) }
        exited.unlock()
        return ThreadSamples(stacks: stacks, samples: samples, threadSamples: threadSamples, threads: threads, mainID: mainID, metrics: metrics)
    }

    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) : 0
    }

    /// CPU seconds used by the main thread and by the whole process.
    private static func cpuTimes(main: thread_act_t) -> (main: Double, all: Double) {
        func seconds(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1e6 }
        var mainTime = 0.0, all = 0.0
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return (0, 0) }
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size) }
            }
            if ok == KERN_SUCCESS {
                let used = seconds(info.user_time) + seconds(info.system_time)
                all += used
                if threads[i] == main { mainTime = used }
            }
            mach_port_deallocate(mach_task_self_, threads[i])
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
        return (mainTime, all)
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// What the sampler recorded, turned into JSON with each address's image
/// and, where the phone knows it, its symbol.
struct ThreadSamples: @unchecked Sendable {
    let stacks: [[UInt64]]
    let samples: [(Double, Int32)]
    let threadSamples: [(Double, Int32, UInt64, Int32)]
    let threads: [UInt64: ThreadSampler.ThreadRecord]
    let mainID: UInt64
    let metrics: [[String: Any]]

    func export(origin: Double) -> [String: Any] {
        var addresses = Set<UInt64>()
        for stack in stacks { addresses.formUnion(stack) }
        let images = Self.images()
        var used = Set<Int>()
        var symbols: [String: [String: Any]] = [:]
        for address in addresses {
            guard let image = images.firstIndex(where: { address >= $0.start && address < $0.end }) else { continue }
            used.insert(image)
            var entry: [String: Any] = ["image": image]
            var info = Dl_info()
            // dladdr's name is only an exported symbol; the Mac does better for the app's own code.
            if dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0, let name = info.dli_sname {
                entry["symbol"] = String(cString: name)
                entry["offset"] = address - UInt64(UInt(bitPattern: info.dli_saddr))
            }
            symbols[Self.hex(address)] = entry
        }
        let round = { (t: Double) in ((t - origin) * 10_000).rounded() / 10_000 }
        return [
            "stacks": stacks.map { $0.map(Self.hex) },
            "samples": samples.map { [round($0.0), Double($0.1)] },
            // [time, stack, thread ID, CPU µs that thread used since its previous sample]
            "thread_samples": threadSamples.map { [round($0.0), Double($0.1), Double($0.2), Double($0.3)] },
            "threads": threads.sorted { $0.value.cpu &- $0.value.first > $1.value.cpu &- $1.value.first }.map { id, thread -> [String: Any] in
                ["id": Double(id), "name": thread.name, "main": id == mainID, "priority": thread.priority,
                 "cpu_ms": (Double(thread.cpu &- thread.first) / 1e5).rounded() / 10]
            },
            "metrics": metrics.map { sample in
                var copy = sample
                copy["t"] = round(sample["t"] as? Double ?? origin)
                return copy
            },
            "symbols": symbols,
            "images": images.enumerated().map { index, image -> [String: Any] in
                ["name": (image.path as NSString).lastPathComponent, "path": image.path, "uuid": image.uuid,
                 "load_address": Self.hex(image.start), "size": image.end - image.start, "used": used.contains(index),
                 "main": image.main]
            }
        ]
    }

    static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

    struct Image { let path: String; let uuid: String; let start: UInt64; let end: UInt64; let main: Bool }

    /// Every loaded image's __TEXT range and UUID.
    static func images() -> [Image] {
        let executable = Bundle.main.executablePath.map { ($0 as NSString).resolvingSymlinksInPath }
        var out: [Image] = []
        for i in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(i), let name = _dyld_get_image_name(i) else { continue }
            let path = String(cString: name)
            var uuid = "", start = UInt64(UInt(bitPattern: header)), size: UInt64 = 0
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let load = command.assumingMemoryBound(to: load_command.self).pointee
                if load.cmd == LC_UUID {
                    let bytes = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                    uuid = UUID(uuid: bytes).uuidString
                } else if load.cmd == LC_SEGMENT_64 {
                    let segment = command.assumingMemoryBound(to: segment_command_64.self).pointee
                    let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    if name == "__TEXT" { size = segment.vmsize }
                }
                command = command.advanced(by: Int(load.cmdsize))
            }
            start = UInt64(UInt(bitPattern: header))
            out.append(Image(path: path, uuid: uuid, start: start, end: start + size,
                             main: executable != nil && (path as NSString).resolvingSymlinksInPath == executable))
        }
        return out
    }
}
#endif
