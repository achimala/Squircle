#if SQUIRCLE_OVERLAY || DEBUG
import Darwin
import MachO
import OSLog
import Synchronization
import UIKit

/// Records how the host app performs, from inside its own process: every
/// frame's timing, the main thread's stack about once a millisecond, CPU,
/// memory, thermal state, touches and the app's log. The Mac names the app's
/// frames from the build's dSYM (`squircle perf`).
@MainActor
final class PerfRecorder {
    private let sampler: MainThreadSampler
    private var link: CADisplayLink?
    private let started = CACurrentMediaTime()
    private let startDate = Date()
    private var frames: [Double] = []
    private var hitchScreens: [(Double, String)] = []
    private var refresh: Double = 60
    private let touches: TouchTracker
    private var events: [[String: Any]] = []
    private var observers: [NSObjectProtocol] = []
    private weak var overlay: UIWindow?

    init(below overlay: UIWindow) {
        self.overlay = overlay
        sampler = MainThreadSampler()
        touches = TouchTracker(origin: started)
        frames.reserveCapacity(8_000)
        sampler.start()
        let link = CADisplayLink(target: Ticker { [weak self] link in self?.tick(link) }, selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        touches.attach(to: overlay.windowScene?.windows.filter { $0 !== overlay } ?? [])
        let center = NotificationCenter.default
        for (name, kind) in [(UIApplication.didEnterBackgroundNotification, "background"),
                             (UIApplication.willEnterForegroundNotification, "foreground"),
                             (UIApplication.didReceiveMemoryWarningNotification, "memory-warning")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.event(kind) }
            })
        }
    }

    var hitchCount: Int { Self.hitches(frames, refresh: refresh).count }

    private func event(_ kind: String) {
        events.append(["t": CACurrentMediaTime() - started, "kind": kind])
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.timestamp - started
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0 { refresh = (1 / interval).rounded() }
        // A late frame: note what was on screen while it was late.
        if let last = frames.last, now - last > 1.5 / refresh {
            hitchScreens.append((last, overlay.flatMap(Self.screenName(below:)) ?? ""))
        }
        frames.append(now)
    }

    /// Stops and writes the capture as JSON; returns its file, how long it
    /// ran and its frame times (for the thumbnail).
    func finish() async -> (url: URL, duration: Double, frames: [Double], hitches: Int)? {
        link?.invalidate()
        link = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        let duration = CACurrentMediaTime() - started
        let raw = sampler.stop()
        let touchEvents = touches.detach()
        let frames = self.frames, refresh = self.refresh, screens = hitchScreens
        let hitches = Self.hitches(frames, refresh: refresh).map { hitch -> [String: Any] in
            let screen = screens.last { abs($0.0 - hitch.start) < 0.0005 }?.1 ?? ""
            return ["start": hitch.start, "duration": hitch.duration, "screen": screen]
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
        let header: [String: Any] = [
            "format": "squircle-perf", "version": 1,
            "app": app,
            "device": ["model": Self.machine(), "system": device.systemName + " " + device.systemVersion,
                       "simulator": ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil],
            "started_at": startDate.timeIntervalSince1970,
            "duration": duration,
            "refresh_hz": refresh,
            "sample_interval_ms": MainThreadSampler.interval * 1000,
            "frames": frames.map { ($0 * 10_000).rounded() / 10_000 },
            "hitches": hitches,
            "events": (events + touchEvents).sorted { ($0["t"] as? Double ?? 0) < ($1["t"] as? Double ?? 0) }
        ]
        let origin = started
        return await Task.detached(priority: .userInitiated) {
            var json = header
            json.merge(raw.export(origin: origin)) { a, _ in a }
            json["logs"] = Self.logs(since: Date(timeIntervalSince1970: (header["started_at"] as? Double) ?? 0))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).perf.json")
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                  (try? data.write(to: url)) != nil else { return nil }
            return (url, duration, frames, hitches.count)
        }.value
    }

    /// Frames that arrived more than half a frame late: when the late frame
    /// was due, and how long past due it came.
    nonisolated static func hitches(_ frames: [Double], refresh: Double) -> [(start: Double, duration: Double)] {
        let period = 1 / max(1, refresh)
        var out: [(Double, Double)] = []
        for i in frames.indices.dropFirst() {
            let gap = frames[i] - frames[i - 1]
            if gap > period * 1.5 { out.append((frames[i - 1], gap - period)) }
        }
        return out
    }

    /// The innermost view controller showing in the app's key window.
    private static func screenName(below overlay: UIWindow) -> String? {
        let windows = overlay.windowScene?.windows.filter { $0 !== overlay && !$0.isHidden } ?? []
        guard var top = (windows.first { $0.isKeyWindow } ?? windows.last)?.rootViewController else { return nil }
        while true {
            if let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            else if let nav = top as? UINavigationController, let next = nav.visibleViewController { top = next }
            else if let tabs = top as? UITabBarController, let next = tabs.selectedViewController { top = next }
            else { break }
        }
        return String(describing: type(of: top))
    }

    private static func machine() -> String {
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return model }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The app's own log lines while it recorded, newest 400.
    nonisolated private static func logs(since start: Date) -> [[String: Any]] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: start)) else { return [] }
        var lines: [[String: Any]] = []
        for case let entry as OSLogEntryLog in entries where entry.date >= start {
            let level: String
            switch entry.level {
            case .debug: level = "debug"
            case .info: level = "info"
            case .notice: level = "notice"
            case .error: level = "error"
            case .fault: level = "fault"
            default: level = "default"
            }
            lines.append(["t": entry.date.timeIntervalSince(start), "level": level,
                          "subsystem": entry.subsystem, "category": entry.category,
                          "message": String(entry.composedMessage.prefix(500))])
        }
        return Array(lines.suffix(400))
    }
}

/// CADisplayLink holds its target strongly; this breaks the cycle.
final class Ticker: NSObject {
    private let action: (CADisplayLink) -> Void
    init(_ action: @escaping (CADisplayLink) -> Void) { self.action = action }
    @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { action(link) } }
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

/// Samples the main thread's call stack from a background thread.
///
/// Never freezes the app: between suspending the main thread and resuming it,
/// the sampler makes one kernel call (`thread_get_state`) and reads memory
/// only inside the main thread's own stack, so it can never wait on a lock
/// the main thread holds (malloc, the Swift runtime, dyld). Everything that
/// allocates happens after the resume. A sample that can't be read is
/// skipped; the main thread is resumed on every path.
final class MainThreadSampler: Thread, @unchecked Sendable {
    static let interval = 0.001
    private static let maxDepth = 192

    private let target: thread_act_t
    private let stackLow: UInt64
    private let stackHigh: UInt64
    private let done = Atomic<Bool>(false)
    private let exited = NSCondition()
    private var hasExited = false
    /// Filled only after each resume.
    private var stacks: [[UInt64]] = []
    private var index: [[UInt64]: Int] = [:]
    private var samples: [(Double, Int32)] = []
    private var metrics: [[String: Any]] = []

    /// Call on the main thread.
    override init() {
        precondition(Foundation.Thread.isMainThread)
        target = mach_thread_self()
        let top = UInt64(UInt(bitPattern: pthread_get_stackaddr_np(pthread_self())))
        stackHigh = top
        stackLow = top - UInt64(pthread_get_stacksize_np(pthread_self()))
        super.init()
        name = "Squircle perf sampler"
        qualityOfService = .userInteractive
        samples.reserveCapacity(70_000)
    }

    deinit {
        mach_port_deallocate(mach_task_self_, target)
    }

    override func main() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let toSeconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let buffer = UnsafeMutablePointer<UInt64>.allocate(capacity: Self.maxDepth)
        defer { buffer.deallocate() }
        var nextMetrics = 0.0
        var lastCPU: (wall: Double, main: Double, all: Double)?
        while !done.load(ordering: .relaxed) {
            let now = Double(mach_absolute_time()) * toSeconds
            let depth = capture(into: buffer)
            if depth > 0 {
                let stack = Array(UnsafeBufferPointer(start: buffer, count: depth))
                let id: Int
                if let known = index[stack] { id = known } else {
                    id = stacks.count
                    stacks.append(stack)
                    index[stack] = id
                }
                if samples.count < 200_000 { samples.append((now, Int32(id))) }
            }
            if now >= nextMetrics {
                nextMetrics = now + 0.25
                let cpu = Self.cpuTimes(main: target)
                var sample: [String: Any] = ["t": now, "memory_mb": Self.footprint() / 1_048_576,
                                             "thermal": Self.thermal(ProcessInfo.processInfo.thermalState)]
                if let last = lastCPU, now > last.wall {
                    sample["cpu"] = ((cpu.all - last.all) / (now - last.wall) * 100).rounded()
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

    /// One stack, leaf first, into `buffer`. Nothing in here allocates.
    private func capture(into buffer: UnsafeMutablePointer<UInt64>) -> Int {
        #if arch(arm64)
        // Plain locals: no lazily initialised globals, which take a lock.
        let mask: UInt64 = 0x0000_000F_FFFF_FFFF, maxDepth = 192, low = stackLow, high = stackHigh
        guard thread_suspend(target) == KERN_SUCCESS else { return 0 }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(target, ARM_THREAD_STATE64, $0, &count) }
        }
        var depth = 0
        if read == KERN_SUCCESS {
            buffer[0] = UInt64(state.__pc) & mask
            buffer[1] = UInt64(state.__lr) & mask
            depth = 2
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
        thread_resume(target)
        return depth
        #else
        return 0
        #endif
    }

    /// Stops sampling and hands over what it recorded.
    func stop() -> MainThreadSamples {
        done.store(true, ordering: .relaxed)
        exited.lock()
        while !hasExited, isExecuting { _ = exited.wait(until: Date().addingTimeInterval(1)) }
        exited.unlock()
        return MainThreadSamples(stacks: stacks, samples: samples, metrics: metrics)
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

    private static func thermal(_ state: ProcessInfo.ThermalState) -> String {
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
struct MainThreadSamples: @unchecked Sendable {
    let stacks: [[UInt64]]
    let samples: [(Double, Int32)]
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
