import UIKit

/// Where the user has asked to be. The only navigation state there is:
/// everything on screen is derived from it and from two springs that always
/// move toward what it implies, so no sequence of taps can leave the screen
/// somewhere it should not be.
enum Route: Equatable {
    case grid
    /// The app's agent: the conversation an app opens to.
    case app(String)
    /// Another of the app's threads, over its agent.
    case thread(app: String, ThreadDestination)

    var app: String? {
        switch self {
        case .grid: nil
        case .app(let id), .thread(let id, _): id
        }
    }
    var thread: ThreadDestination? { if case .thread(_, let thread) = self { thread } else { nil } }
}

/// A conversation over the app's agent: one of its T3 threads, or a new
/// conversation T3 hasn't been told about yet (each its own).
enum ThreadDestination: Hashable {
    case existing(String)
    case draft(UUID)

    var threadID: String? { if case .existing(let id) = self { id } else { nil } }
}

/// What a notification asked to open, until it is on screen.
private enum PendingOpen {
    /// The Mac's catalog is being asked for the app or build it names.
    case lookingUp(PushTarget)
    /// The catalog couldn't be read; it is tried again as apps arrive.
    case waiting(PushTarget)

    var target: PushTarget {
        switch self { case .lookingUp(let target), .waiting(let target): target }
    }
}

/// The root: every app's real device. Home is a grid of still portraits of
/// those devices that scroll natively, in the order the user arranged them
/// (long-press one, then drag it). Opening an app pushes in the
/// conversation with its agent while Home falls back beneath it. The app's
/// other threads open from the agent's Threads page or its update lines,
/// pushing in over it the same way. Simulators the app's agents are using
/// float over its conversations (`SimulatorDock`).
///
/// Navigation is a route plus two springs (`appSpring` grid→agent, `spring`
/// agent→thread). Each spring's target is a function of the route and of what
/// is mounted. What is mounted (the agent, the thread over it) changes only
/// while its spring is at zero, i.e. off screen. Every frame is a pure
/// function of those values, including which views take touches.
@MainActor
final class StudioViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let model: SquircleModel
    /// Renders the grid's still device portraits.
    private let stage = DeviceStage()
    private lazy var feeds = SimulatorFeeds(model: model)
    private lazy var dock = SimulatorDock(feeds: feeds)
    /// The simulator shown large, while it is (or is flying back).
    private weak var simulatorViewer: MediaViewer?
    /// The grid and its controls.
    private let home = UIView()
    private let grid = UIScrollView()
    private let connection = Theme.glassButton(symbol: "macbook", identifier: "connection.status", accessibilityLabel: "Mac connection")
    private let add = Theme.glassButton(symbol: "plus", identifier: "project.add", accessibilityLabel: "Add app")
    /// How many things wait on you across apps; opens them. Hidden at none.
    private let waitingButton = Theme.glassButton(title: "", identifier: "waiting.open")
    /// Holds the app's agent; touches pass through when empty.
    private let agentHost = PassthroughView()
    /// Holds a thread over the agent; touches pass through when empty.
    private let threadHost = PassthroughView()
    /// 0 = grid, 1 = agent.
    private let appSpring = SpringDriver()
    /// 0 = agent, 1 = thread over it.
    private let spring = SpringDriver()
    private var cells: [String: GridCell] = [:]
    private var bindings: [String: ScreenshotBinding] = [:]
    /// Home's order, the Mac's (see `SquircleModel.arrangeApps`).
    private var projects: [AppProject] = []
    /// Pending model render (at most one) and portrait drawing.
    private var renderTask: Task<Void, Never>?
    private var portraitTask: Task<Void, Never>?
    private var laidOut: StageLayout?
    /// Bumped whenever an app's screen changes; part of each portrait's key.
    private var screenVersions: [String: Int] = [:]

    // MARK: Navigation state

    private var route = Route.grid
    /// A conversation in place, with what it was mounted for: the two are
    /// set and cleared together.
    private struct Mounted<Key: Equatable> {
        let key: Key
        let controller: ThreadViewController
    }
    /// The app whose agent (and device) is mounted. Changes only at `appSpring` 0.
    private var mountedApp: Mounted<String>?
    /// The conversation over the agent. Changes only at `spring` 0.
    private var mountedThread: Mounted<ThreadDestination>?
    /// The app's threads closed lately, newest first: off screen and let go
    /// of the model, so going back to one puts it back as it was instead of
    /// building its page and every row again.
    private var parked: [Mounted<ThreadDestination>] = []
    /// Making a thread's page ahead of its push (`prepareThread`), into `parked`.
    private var preparing: (key: ThreadDestination, task: Task<Void, Never>)?
    private var selectedID: String? { mountedApp?.key }
    private var agent: ThreadViewController? { mountedApp?.controller }
    private var thread: ThreadViewController? { mountedThread?.controller }
    /// A finger on the back edge owns one spring; targets wait for release.
    private var dragging: SpringDriver?
    private var dragStart: CGFloat = 0
    /// Inside `sync()`: the scene is drawn once, from the finished state.
    private var syncing = false
    /// The conversation on screen changed (nil: none), for notifications.
    var onViewing: ((String?) -> Void)?
    /// A notification tapped before what it names arrived from the Mac.
    private var pendingOpen: PendingOpen?

    // MARK: Arranging state

    /// An app a finger holds on Home, and the place it would drop into.
    private struct Lift: Equatable {
        let id: String
        var index: Int
        /// The finger in the grid's content, and the held cell's centre less it.
        var finger: CGPoint
        let grab: CGPoint
        var center: CGPoint { CGPoint(x: finger.x + grab.x, y: finger.y + grab.y) }
    }
    private var lift: Lift?
    /// 0 = resting, 1 = held: how far `raised` is lifted off the grid. It
    /// stays raised until the spring lands it.
    private let liftSpring = SpringDriver()
    private var raised: String?
    private let arrange = UILongPressGestureRecognizer()
    private var autoscroll: Task<Void, Never>?
    /// Home as shown: the held app in the place it would drop into.
    private var shown: [AppProject] {
        guard let lift, let from = projects.firstIndex(where: { $0.id == lift.id }) else { return projects }
        var order = projects
        order.insert(order.remove(at: from), at: min(lift.index, order.count))
        return order
    }

    init(model: SquircleModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        JellyRenderer.warm()
        view.backgroundColor = Theme.paper
        view.addSubview(stage)
        view.addSubview(home)
        view.addSubview(agentHost)
        view.addSubview(threadHost)
        view.addSubview(dock)
        dock.onExpand = { [weak self] use in self?.expandSimulator(use) }

        grid.alwaysBounceVertical = true
        grid.showsVerticalScrollIndicator = false
        grid.contentInsetAdjustmentBehavior = .never
        grid.accessibilityIdentifier = "app.grid"
        if #available(iOS 26.0, *) { grid.topEdgeEffect.style = .soft }
        home.addSubview(grid)
        [connection, add, waitingButton].forEach(home.addSubview)
        waitingButton.isHidden = true
        waitingButton.addAction(UIAction { [weak self] _ in self?.presentWaiting() }, for: .touchUpInside)
        connection.showsMenuAsPrimaryAction = true
        add.addAction(UIAction { [weak self] _ in self?.presentImport() }, for: .touchUpInside)
        arrange.addTarget(self, action: #selector(arrangePressed(_:)))
        arrange.minimumPressDuration = 0.35
        arrange.delegate = self
        grid.addGestureRecognizer(arrange)
        // A finger down on an app: its agent's page can start being made; a scroll stops that.
        grid.addGestureRecognizer(TouchDown { [weak self] point in
            guard let self, let index = app(at: point) else { return }
            prepareApp(shown[index].id)
        })
        grid.panGestureRecognizer.addTarget(self, action: #selector(gridPanned(_:)))
        liftSpring.parameters = .init(response: 0.32, damping: 0.78)
        liftSpring.onChange = { [weak self] _ in self?.applyScene() }
        liftSpring.onRest = { [weak self] value in
            guard let self, value <= 0.001, lift == nil else { return }
            raised = nil
            applyScene()
        }


        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(backPanned(_:)))
        edge.edges = .left
        edge.delegate = self
        view.addGestureRecognizer(edge)

        for driver in [appSpring, spring] {
            driver.onChange = { [weak self] value in
                guard let self else { return }
                // Off screen: whatever the route wants mounted can mount now.
                if value <= 0.001 { sync() } else { applyScene() }
            }
            driver.onRest = { [weak self] _ in self?.rested() }
        }

        Task { [weak self, updates = model.updates] in
            for await _ in updates {
                guard let self else { return }
                // A burst of model changes renders the latest state once,
                // 80 ms after its first change, however long the burst lasts.
                guard renderTask == nil else { continue }
                renderTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard let self else { return }
                    renderTask = nil
                    render()
                }
            }
        }
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIAccessibility.reduceMotionStatusDidChangeNotification) {
                self?.relayout()
            }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: StudioViewController, _: UITraitCollection) in
            controller.relayout()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: StudioViewController, _: UITraitCollection) in
            controller.schedulePortraits()
        }
        // Portraits skipped while in the background are drawn on return.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
                self?.schedulePortraits()
            }
        }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The window's keyboard guide (and the text window behind it) is made
        // the first time a view asks for it: here, at launch, rather than by
        // the first conversation page put in place.
        _ = view.keyboardLayoutGuide
        // The first text view made pays for setting text views up; the first page made ahead uses this one.
        if spareComposer == nil, !madeComposer { madeComposer = true; spareComposer = Composer(placeholder: "Message") }
        #if DEBUG
        #if !SQUIRCLE_OVERLAY
        MotionAudit.shared.note("gallery.visible", values: ["since_launch_ms": (CACurrentMediaTime() - SquircleApp.launchedAt) * 1000])
        #endif
        if !hooksStarted { hooksStarted = true; startVerificationHooks() }
        #endif
    }

    #if DEBUG
    /// Once per launch: a full-screen movie or sheet closing shows this again.
    private var hooksStarted = false
    /// Verification only (never in Release). Holds real states still for a
    /// screen capture: `SQUIRCLE_GRID` (grid scroll in points), `SQUIRCLE_APP`
    /// (open the app with this name), `SQUIRCLE_APP_SCRUB` (0…1 of opening it)
    /// and `SQUIRCLE_SCRUB` (0…1 of a thread over its agent); `SQUIRCLE_SIM_EXPAND=1` (or a simulator's name) brings
    /// the first (or that) simulator large; `SQUIRCLE_BUILDS=1` shows the app's builds and
    /// `SQUIRCLE_NO_DOCK=1` hides simulators for stills; `SQUIRCLE_TASKS=1|threads` opens Tasks on either tab (`SQUIRCLE_DEMO_TASKS=1` shows made-up tasks, `=PATH` a copy of a real list; `SQUIRCLE_DEMO_SENT=1` with no Mac connection shows a made-up app "Demo" whose agent sent to and heard from workers). `SQUIRCLE_OPEN_TARGET` opens a notification payload; `SQUIRCLE_DEMO=1` loops through them; `SQUIRCLE_DEMO_VIDEO=PATH` opens a movie full screen; `SQUIRCLE_STRESS=1`
    /// navigates as fast as a hurried person and checks every frame.
    private func startVerificationHooks() {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> CGFloat? { environment[key].flatMap(Double.init).map { CGFloat($0) } }
        if let slow = value("SQUIRCLE_SLOW") { SpringDriver.debugSlowMotion = Double(slow) }
        if environment["SQUIRCLE_NO_DOCK"] == "1" { dock.isHidden = true }
        // `SQUIRCLE_PERF_APP`: once connected, open this app (traced).
        if let name = environment["SQUIRCLE_PERF_APP"] {
            // A headless simulator never makes the scene active; the phone does.
            model.startMetadataUpdates()
            Task { [weak self] in
                guard let model = self?.model else { return }
                await model.until { model.connected && model.projects.contains { $0.name == name } }
                try? await Task.sleep(for: .seconds(value("SQUIRCLE_PERF_WAIT").map(Double.init) ?? 3))
                guard let self, let project = projects.first(where: { $0.name == name }) else { return }
                ConnectionTrace.mark("tap.app", name)
                openApp(project.id); appSpring.set(1)
                guard let thread = environment["SQUIRCLE_PERF_THREAD"] else { return }
                try? await Task.sleep(for: .seconds(3))
                ConnectionTrace.mark("tap.thread", thread)
                openThread(thread)
            }
        }
        Task { [weak self, model] in
            // Home's apps first: from the copy on disk or the Mac.
            let name = environment["SQUIRCLE_APP"]
            guard name != nil || value("SQUIRCLE_GRID") != nil else { return }
            await model.until { name.map { name in model.projects.contains { $0.name == name } } ?? !model.projects.isEmpty }
            guard let self else { return }
            render()
            if let y = value("SQUIRCLE_GRID") { grid.contentOffset.y = y; applyScene() }
            guard let name, let project = projects.first(where: { $0.name == name }) else { return }
            openApp(project.id)
            if let scrub = value("SQUIRCLE_APP_SCRUB") { hold(appSpring, at: scrub); return }
            appSpring.set(1)
            guard let scrub = value("SQUIRCLE_SCRUB") else {
                if let n = environment["SQUIRCLE_MEDIA"].flatMap(Int.init) {
                    Task { [weak self] in try? await Task.sleep(for: .seconds(3)); self?.agent?.debugScrollToMedia(n, kind: environment["SQUIRCLE_MEDIA_KIND"]) }
                }
                if let n = environment["SQUIRCLE_ACTION"].flatMap(Int.init) {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(4))
                        await self?.agent?.debugScrollToAction(n, open: environment["SQUIRCLE_ACTION_OPEN"])
                    }
                }
                if let text = environment["SQUIRCLE_SEND"] {
                    Task { [weak self] in try? await Task.sleep(for: .seconds(2)); self?.agent?.debugSend(text) }
                }
                if let tab = environment["SQUIRCLE_TASKS"] {
                    Task { [weak self] in try? await Task.sleep(for: .seconds(2)); self?.presentTasks(threads: tab == "threads") }
                }
                if environment["SQUIRCLE_BUILDS"] == "1" {
                    Task { [weak self] in try? await Task.sleep(for: .seconds(2)); self?.presentBuilds() }
                }
                return
            }
            let sessions = model.sessions(for: project)
            let named = environment["SQUIRCLE_THREAD"].flatMap { title in sessions.first { $0.title == title } ?? sessions.first { $0.title.contains(title) } }
            openThread(environment["SQUIRCLE_DRAFT"] == "1" ? nil : (named ?? sessions.first)?.id)
            if environment["SQUIRCLE_DEMO_QUESTION"] == "1" { thread?.debugShowQuestion() }
            let later: (@escaping @MainActor () -> Void) -> Void = { work in
                Task { try? await Task.sleep(for: .seconds(2.5)); work() }
            }
            if environment["SQUIRCLE_DEMO_LENS"] == "1" { later { [weak self] in self?.thread?.debugLens() } }
            if let n = environment["SQUIRCLE_MEDIA"].flatMap(Int.init) {
                Task { [weak self] in try? await Task.sleep(for: .seconds(4)); self?.thread?.debugScrollToMedia(n, kind: environment["SQUIRCLE_MEDIA_KIND"]) }
            }
            if environment["SQUIRCLE_DEMO_PULSE"] == "1" { later { [weak self] in self?.thread?.debugPulse() } }
            // `SQUIRCLE_SEND` here sends into the opened thread or draft, with
            // `SQUIRCLE_ATTACH` (an image file) as its picture.
            if let text = environment["SQUIRCLE_SEND"] {
                later { [weak self] in
                    if let path = environment["SQUIRCLE_ATTACH"], let image = UIImage(contentsOfFile: path).flatMap({ ImageAttachment($0) }) {
                        self?.model.attach(image)
                    }
                    self?.thread?.debugSend(text)
                }
            }
            if scrub < 1 { hold(spring, at: scrub) }
            if environment["SQUIRCLE_THEN_BACK"] == "1" {
                Task { [weak self] in try? await Task.sleep(for: .seconds(5)); self?.closeThread() }
            }
        }
        // `SQUIRCLE_DEMO_VIDEO=PATH`: that movie large, as a recording opens.
        if let path = environment["SQUIRCLE_DEMO_VIDEO"] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let window = self?.view.window else { return }
                let url = URL(fileURLWithPath: path)
                let video = MediaViewer.open(.video(poster: nil, size: nil, player: nil, url: { url }), from: MediaOrigin { nil }, in: window)
                // `SQUIRCLE_DEMO_SCRUB=FROM,TO,SECONDS[;…]`: drags its scrubber
                // between those fractions, each two seconds after the last.
                for step in (environment["SQUIRCLE_DEMO_SCRUB"] ?? "").split(separator: ";") {
                    let n = step.split(separator: ",").compactMap { Double($0) }
                    guard n.count == 3 else { continue }
                    try? await Task.sleep(for: .seconds(2))
                    await video.debugScrub(from: Float(n[0]), to: Float(n[1]), duration: n[2])
                }
                // `SQUIRCLE_DEMO_UNMUTE=1`: unmute, mute, unmute, pause, play and
                // close, as its controls would.
                guard environment["SQUIRCLE_DEMO_UNMUTE"] == "1" else { return }
                for step in ["unmute", "mute", "unmute", "pause", "play", "close"] {
                    try? await Task.sleep(for: .seconds(3))
                    NSLog("SQUIRCLE-AUDIO demo %@", step)
                    if step == "close" { video.dismiss() } else { video.debugControl(step) }
                }
            }
        }
        if let wanted = environment["SQUIRCLE_SIM_EXPAND"] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(9))
                guard let self, let use = dock.uses.first(where: { wanted == "1" || $0.deviceName == wanted }) else { return }
                expandSimulator(use)
                await MediaViewer.debugDrags(in: view.window)
            }
        }
        // `SQUIRCLE_WAITING=1`: what waits on you, once the Mac has listed it.
        if environment["SQUIRCLE_WAITING"] == "1" {
            Task { [weak self] in try? await Task.sleep(for: .seconds(3)); self?.presentWaiting() }
        }
        // `SQUIRCLE_OPEN_TARGET`: a notification's `squircle` payload as JSON, opened as if tapped.
        if let json = environment["SQUIRCLE_OPEN_TARGET"], let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
           let target = PushTarget(userInfo: ["squircle": payload]) {
            Task { [weak self] in try? await Task.sleep(for: .seconds(3)); self?.open(target) }
        }
        // `SQUIRCLE_JELLY_GLYPHS=DIR`: the Live Activity's jellies, drawn by
        // the shader into the widget's asset catalog (the widget can't run
        // Metal): `DIR` is `app/Squircle/Widgets/Assets.xcassets`.
        if let directory = environment["SQUIRCLE_JELLY_GLYPHS"] { renderJellyGlyphs(into: URL(fileURLWithPath: directory)) }
        if environment["SQUIRCLE_STRESS"] == "1" {
            let seconds = value("SQUIRCLE_STRESS_SECONDS").map(Double.init) ?? 30
            Task { [weak self] in await self?.stress(for: seconds) }
        }
        if let name = environment["SQUIRCLE_NAV_LOOP"] {
            Task { [weak self] in await self?.navigationLoop(app: name, rounds: Int(value("SQUIRCLE_NAV_ROUNDS") ?? 4)) }
        }
        if environment["SQUIRCLE_DEMO"] == "1" {
            Task { [weak self] in
                while true {
                    try? await Task.sleep(for: .seconds(2.5))
                    guard let self else { return }
                    switch route {
                    case .grid: if let first = projects.first { openApp(first.id) }
                    case .app:
                        if let project = selectedProject, let first = model.sessions(for: project).first,
                           Int.random(in: 0...1) == 0 { openThread(first.id) } else { closeApp() }
                    case .thread: closeThread()
                    }
                }
            }
        }
    }

    private func renderJellyGlyphs(into directory: URL) {
        let moods: [(String, JellyLook.Mood)] = [("Working", .working), ("NeedsYou", .needsYou), ("Done", .done)]
        for (name, mood) in moods {
            let set = directory.appendingPathComponent("Jelly\(name).imageset")
            try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            var images: [[String: Any]] = []
            for dark in [false, true] {
                let traits = UITraitCollection { $0.userInterfaceStyle = dark ? .dark : .light; $0.displayScale = 3 }
                guard let image = JellySprites.shared.image(.agent(mood), .tight(34), traits: traits), let png = image.pngData() else { continue }
                let file = "jelly-\(name.lowercased())\(dark ? "-dark" : "")@3x.png"
                try? png.write(to: set.appendingPathComponent(file))
                var entry: [String: Any] = ["idiom": "universal", "filename": file, "scale": "3x"]
                if dark { entry["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
                images.append(entry)
            }
            let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
            try? JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
                .write(to: set.appendingPathComponent("Contents.json"))
        }
        NSLog("JELLY glyphs written to %@", directory.path)
    }

    /// Holds one spring still at a value, as a finger would.
    private func hold(_ driver: SpringDriver, at value: CGFloat) {
        driver.stop()
        dragging = driver
        driver.set(value)
    }

    /// Verification only (`SQUIRCLE_NAV_LOOP=APP NAME`): opens the app's
    /// agent from Home, then each of its most recent threads in turn and
    /// back with a left-edge swipe, `SQUIRCLE_NAV_ROUNDS` times, and logs
    /// the late frames of every push and swipe (`NAV …` lines).
    /// `SQUIRCLE_NAV_THREADS=ID,ID,…` names the threads instead.
    private func navigationLoop(app name: String, rounds: Int) async {
        while !(model.connected && projects.contains { $0.name == name }) { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(3))
        guard let project = projects.first(where: { $0.name == name }) else { return }
        var total = (frames: 0, hitches: 0, ms: 0.0)
        var total120 = (0, 0.0)
        func measured(_ label: String, seconds: Double, _ action: () async -> Void) async {
            var stamps: [(CFTimeInterval, CFTimeInterval)] = []
            let link = CADisplayLink(target: DisplayLinkProxy { stamps.append(($0.timestamp, $0.duration)) },
                                     selector: #selector(DisplayLinkProxy.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            // Each pass of the main run loop: one longer than 8.3 ms misses a 120 Hz frame.
            var passes: [Double] = []
            var woke = CACurrentMediaTime()
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { woke = now } else { passes.append((now - woke) * 1000) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            let end = ContinuousClock.now + .seconds(seconds)
            await action()
            try? await Task.sleep(until: end)
            link.invalidate()
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let gaps = zip(stamps.dropFirst(), stamps).map { ($0.0 - $1.0, $1.1) }
            let late = gaps.filter { $0.0 > 1.5 * $0.1 }
            let ms = late.reduce(0) { $0 + ($1.0 - $1.1) * 1000 }
            let long = passes.filter { $0 > 8.3 }
            total = (total.frames + stamps.count, total.hitches + late.count, total.ms + ms)
            total120 = (total120.0 + long.count, total120.1 + long.reduce(0) { $0 + $1 - 8.3 })
            NSLog("NAV %@ frames=%d hitches=%d hitch_ms=%.0f worst_ms=%.1f over8=%d main_max=%.1f", label, stamps.count, late.count, ms,
                  (gaps.map(\.0).max() ?? 0) * 1000, long.count, passes.max() ?? 0)
        }
        func swipeBack() async {
            beginBack()
            for step in 1...16 {
                moveBack(to: 1 - CGFloat(step) / 16 * 0.5)
                await DisplayFrame.next()
            }
            endBack(velocity: 2, closing: true)
        }
        for _ in 0..<rounds {
            if ProcessInfo.processInfo.environment["SQUIRCLE_NAV_NOHEAD"] == nil {
                await measured("touch-app", seconds: 0) {
                    prepareApp(project.id)
                    for _ in 0..<12 { await DisplayFrame.next() }
                }
            }
            await measured("open-app", seconds: 1.2) { openApp(project.id) }
            let named = ProcessInfo.processInfo.environment["SQUIRCLE_NAV_THREADS"]?.split(separator: ",").map(String.init)
            let threads = named ?? model.sessions(for: project).filter { $0.id != model.agentThreadID(for: project) }.prefix(3).map(\.id)
            // As the agent's lines or Tasks listing them would.
            model.prefetch(threads: Array(threads))
            for id in threads {
                // A tap: the finger is down about a tenth of a second before it lifts.
                if ProcessInfo.processInfo.environment["SQUIRCLE_NAV_NOHEAD"] == nil {
                    await measured("touch", seconds: 0) {
                        prepareThread(id)
                        for _ in 0..<12 { await DisplayFrame.next() }
                    }
                }
                await measured("push", seconds: 1.0) { openThread(id) }
                await measured("back", seconds: 1.0) { await swipeBack() }
            }
            await measured("back-home", seconds: 1.2) { await swipeBack() }
        }
        NSLog("NAV total frames=%d hitches=%d hitch_ms=%.0f over8=%d over8_ms=%.0f", total.frames, total.hitches, total.ms, total120.0, total120.1)
    }

    /// Verification only: taps and back swipes as fast as a hurried person,
    /// through the same entry points as the controls, while `audit` checks
    /// every frame. At the end, the screen must have settled on the route.
    private func stress(for seconds: Double) async {
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            var actions: [() -> Void] = []
            if let driver = dragging {
                let target = (driver.value + CGFloat.random(in: -0.4...0.4)).clamped()
                actions.append { [weak self] in self?.moveBack(to: target) }
                actions.append { [weak self] in self?.endBack(velocity: CGFloat.random(in: -2...2), closing: Bool.random()) }
            } else {
                switch route {
                case .grid:
                    for project in projects.prefix(3) { actions.append { [weak self] in self?.openApp(project.id) } }
                    // Holding, dragging and dropping apps, mixed in with the rest.
                    if lift == nil {
                        let index = Int.random(in: 0..<max(1, projects.count))
                        actions.append { [weak self] in
                            guard let self else { return }
                            let frame = layout.cellFrame(index)
                            beginLift(at: CGPoint(x: frame.midX, y: frame.midY))
                        }
                    } else {
                        actions.append { [weak self] in
                            guard let self else { return }
                            moveLift(to: CGPoint(x: .random(in: 0...grid.bounds.width), y: .random(in: 0...grid.contentSize.height)))
                        }
                        actions.append { [weak self] in self?.dropLift() }
                    }
                case .app:
                    actions.append { [weak self] in self?.closeApp() }
                    if let project = selectedProject {
                        for session in model.sessions(for: project).prefix(2) { actions.append { [weak self] in self?.openThread(session.id) } }
                    }
                    actions.append { [weak self] in self?.openThread(nil) }
                case .thread:
                    actions.append { [weak self] in self?.closeThread() }
                }
                if route != .grid { actions.append { [weak self] in self?.beginBack() } }
            }
            actions.randomElement()?()
            try? await Task.sleep(for: .milliseconds(Int.random(in: 20...450)))
        }
        if dragging != nil { endBack(velocity: 0, closing: Bool.random()) }
        dropLift()
        await appSpring.rest()
        await spring.rest()
        let settled = !appSpring.isAnimating && !spring.isAnimating
            && appSpring.value == appTarget && spring.value == threadTarget
            && selectedID == (route.app ?? selectedID) && mountedThread?.key == route.thread
        NSLog("STRESS end route=%@ settled=%d a=%.3f t=%.3f violations=%d", "\(route)", settled,
              appSpring.value, spring.value, auditViolations)
    }

    private var auditViolations = 0

    /// Every frame: at rest exactly the routed screen is showing, and the
    /// simulators float only over the app's screens.
    private func audit(a: CGFloat, t: CGFloat) {
        func fail(_ what: String) {
            auditViolations += 1
            NSLog("AUDIT %@ route=%@ a=%.3f t=%.3f", what, "\(route)", a, t)
        }
        if route == .grid, !appSpring.isAnimating, dragging == nil, dock.alpha > 0.001 { fail("simulators over Home") }
        if lift != nil, route != .grid { fail("an app held off Home") }
        // Each app rests in its place in Home's order; only a held one follows the finger.
        for (index, project) in shown.enumerated() where laidOut != nil && project.id != lift?.id {
            let frame = layout.cellFrame(index)
            if let cell = cells[project.id], cell.center != CGPoint(x: frame.midX, y: frame.midY) { fail("app out of its place") }
        }
        if let problem = JellyDirector.shared.debugViolation() { fail(problem) }
        guard !appSpring.isAnimating, !spring.isAnimating, dragging == nil else { return }
        switch route {
        case .grid: if home.isHidden || home.alpha < 0.99 { fail("grid not showing at rest") }
        case .app: if agent == nil || agentHost.isHidden || a < 1 || t > 0 || agent?.view.transform != .identity { fail("agent not showing at rest") }
        case .thread: if thread == nil || t < 1 || thread?.view.transform != .identity { fail("thread not showing at rest") }
        }
    }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        stage.frame = bounds
        dock.frame = bounds
        dock.bottomInset = view.safeAreaInsets.bottom + 150
        home.place(in: bounds)
        agentHost.frame = bounds
        grid.frame = bounds
        threadHost.frame = bounds
        agent?.view.place(in: bounds)
        thread?.view.place(in: bounds)
        let current = makeLayout()
        if current != laidOut {
            laidOut = current
            layoutGrid()
        }
        // Controls rise in with transforms; `place` keeps their resting spot exact.
        let safe = view.safeAreaInsets
        connection.place(in: CGRect(x: 16, y: safe.top + 4, width: 44, height: 44))
        add.place(in: CGRect(x: bounds.width - 60, y: safe.top + 4, width: 44, height: 44))
        let waitingWidth = min(bounds.width - 152, waitingButton.sizeThatFits(CGSize(width: bounds.width, height: 44)).width)
        waitingButton.place(in: CGRect(x: (bounds.width - waitingWidth) / 2, y: safe.top + 4, width: waitingWidth, height: 44))
        applyScene()
    }

    private func relayout() {
        laidOut = nil
        view.setNeedsLayout()
    }

    private func makeLayout() -> StageLayout {
        StageLayout(size: view.bounds.size, safe: view.safeAreaInsets, reducedMotion: Motion.reduced)
    }

    private var layout: StageLayout { laidOut ?? makeLayout() }
    private var selectedProject: AppProject? { projects.first { $0.id == selectedID } }

    // MARK: Model

    private func render() {
        projects = model.projects
        // On Home, the first apps' agents are read ahead, ready for a finger to come down on one.
        if route == .grid { model.prefetch(threads: projects.prefix(6).compactMap(model.agentThreadID)) }
        let ids = Set(projects.map(\.id))
        // An app that disappeared from the Mac takes its route, or the finger's hold, with it.
        if let app = route.app, !ids.contains(app) { route = .grid }
        if let held = lift?.id, !ids.contains(held) { lift = nil }
        for id in Array(cells.keys) where !ids.contains(id) {
            cells.removeValue(forKey: id)?.removeFromSuperview()
            bindings[id] = nil
        }
        stage.sync(ids: projects.map(\.id))
        for project in projects {
            let cell = cells[project.id] ?? {
                let cell = GridCell(id: project.id)
                cell.addAction(UIAction { [weak self] _ in self?.openApp(project.id) }, for: .touchUpInside)
                cell.accessibilityCustomActions = [("Move earlier", -1), ("Move later", 1)].map { name, step in
                    UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.move(project.id, by: step) ?? false }
                }
                cells[project.id] = cell
                grid.addSubview(cell)
                return cell
            }()
            let sessions = model.sessions(for: project, includingAgent: true)
            cell.configure(name: project.name,
                           phase: sessions.contains { $0.phase == .needsYou } ? .needsYou
                               : sessions.contains { $0.phase == .working } ? .working : .idle)
            let binding = bindings[project.id] ?? {
                let binding = ScreenshotBinding(id: project.id, stage: stage)
                binding.onChange = { [weak self] in
                    self?.screenVersions[project.id, default: 0] += 1
                    self?.schedulePortraits()
                }
                return binding
            }()
            bindings[project.id] = binding
            binding.update(model: model, project: project)
        }
        renderControls()
        renderSimulators()
        UpdateCurtain.sync(in: view, build: model.updatingTo) { [weak self] in self?.model.cancelUpdate() }
        if laidOut != nil { layoutGrid() }
        sync()
        schedulePortraits()
        if case .waiting(let target) = pendingOpen, let resolved = resolve(target) { show(target, resolved) }
    }

    /// The simulators the open app's agents are using, over its conversations.
    private func renderSimulators() {
        // Home, once the app has slid away: no simulator floats or streams.
        guard let project = selectedProject, route.app != nil || appSpring.value > 0.001 else { dock.update(uses: [], currentThread: nil, titles: [:]); return }
        var titles: [String: String] = [:]
        for session in model.sessions(for: project, includingAgent: true) { titles[session.id] = session.displayTitle(in: project) }
        if let agent = model.agentThreadID(for: project) { titles[agent] = project.name }
        let front = route.thread != nil ? thread : agent
        dock.agentThread = model.agentThreadID(for: project)
        let uses = model.activeSimulators(for: project)
        dock.update(uses: uses, currentThread: front?.currentSessionID, titles: titles)
        // A simulator shown large goes back once its agent is done with it.
        if let viewer = simulatorViewer, case .simulator(let use, _, _) = viewer.media, !uses.contains(where: { $0.id == use.id }) {
            viewer.dismiss()
        }
    }

    private func renderControls() {
        let summary = model.connectionSummary
        if connection.accessibilityValue != summary.title {
            connection.accessibilityValue = summary.title
            connection.configuration?.image = UIImage(systemName: "macbook")?.withTintColor(summary.tint, renderingMode: .alwaysOriginal)
        }
        connection.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self.map { [ConnectionMenu.section($0.model)] } ?? [])
        }])
        let waiting = model.waiting.count
        let title = waiting > 0 ? "\(waiting) waiting" : ""
        if waitingButton.configuration?.title != title {
            waitingButton.configuration?.title = title
            waitingButton.configuration?.baseForegroundColor = Theme.accent
            waitingButton.accessibilityLabel = waiting == 1 ? "1 thing waiting on you" : "\(waiting) things waiting on you"
            waitingButton.isHidden = waiting == 0
            view.setNeedsLayout()
        }
    }

    /// Every cell in its place in `shown`; the held one under the finger.
    /// Animated, each cell moves on one spring from wherever it is.
    private func layoutGrid(animated: Bool = false) {
        let layout = self.layout, shown = self.shown, held = lift
        grid.contentSize = CGSize(width: view.bounds.width, height: layout.gridContentHeight(count: shown.count))
        let place = { [cells] in
            for (index, project) in shown.enumerated() {
                guard let cell = cells[project.id] else { continue }
                let frame = layout.cellFrame(index)
                cell.bounds = CGRect(origin: .zero, size: frame.size)
                cell.phoneHeight = layout.gridPhoneHeight
                if project.id != held?.id { cell.center = CGPoint(x: frame.midX, y: frame.midY) }
            }
        }
        if animated {
            UIView.animate(springDuration: 0.42, bounce: 0, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: place)
        } else {
            place()
        }
        if let held, let cell = cells[held.id] { cell.center = held.center }
        schedulePortraits()
    }

    // MARK: Navigation

    /// Where each spring is headed: open only while the route wants exactly
    /// what is mounted. Anything else first goes back to zero, off screen.
    private var appTarget: CGFloat { route.app != nil && route.app == selectedID ? 1 : 0 }
    private var threadTarget: CGFloat {
        appTarget == 1 && route.thread != nil && route.thread == mountedThread?.key ? 1 : 0
    }

    func openApp(_ id: String) {
        guard presentedViewController == nil, projects.contains(where: { $0.id == id }) else { return }
        if route.app != id { Theme.openHaptic() }
        route = .app(id)
        sync()
    }

    func closeApp() {
        guard route != .grid, presentedViewController == nil else { return }
        Theme.selectionHaptic()
        route = .grid
        sync()
    }

    /// A thread of the mounted app; nil starts a new conversation.
    func openThread(_ sessionID: String?) {
        guard presentedViewController == nil, let app = selectedID, route.app == app else { return }
        Theme.openHaptic()
        route = .thread(app: app, sessionID.map(ThreadDestination.existing) ?? .draft(UUID()))
        sync()
    }

    func closeThread() {
        guard case .thread(let app, _) = route, presentedViewController == nil else { return }
        view.endEditing(true)
        route = .app(app)
        sync()
    }

    /// A tapped notification or Live Activity: its app, then its thread or
    /// build. Whatever was presented gives way. A target the apps and
    /// builds on hand don't explain waits while the Mac is asked again, and
    /// is dropped only once the Mac's answer doesn't have it either.
    func open(_ target: PushTarget) {
        if target == .waiting {
            pendingOpen = nil
            if presentedViewController != nil { dismiss(animated: false) }
            presentWaiting()
            return
        }
        if let resolved = resolve(target) { show(target, resolved); return }
        pendingOpen = .lookingUp(target)
        Task { [weak self] in
            guard let self else { return }
            let failure = await model.refreshMetadata(fresh: true)
            guard case .lookingUp(let current)? = pendingOpen, current == target else { return }
            if let resolved = resolve(target) { show(target, resolved) }
            else if failure == nil, model.connected, !projects.isEmpty { pendingOpen = nil; showMissing(target) }
            else { pendingOpen = .waiting(target) }
        }
    }

    /// The app a target names, and its build when it names one, from what
    /// the phone has now; nil until both are known.
    private func resolve(_ target: PushTarget) -> (project: AppProject, build: AppBuild?)? {
        var build: AppBuild?
        if let id = target.build {
            guard let found = model.builds.first(where: { $0.id.lowercased() == id.lowercased() }) else { return nil }
            build = found
        }
        let named: AppProject? = switch target.appRef {
        case .project(let id)?: projects.first { $0.id == id }
        case .bundle(let id)?: projects.first { $0.bundleID == id }
        case .catalog(let id)?: projects.first { $0.metadataID == id }
        case nil: nil
        }
        // A failed build names only itself: its request says whose it is.
        let owner = named ?? build.flatMap { build in
            projects.first { model.builds(for: $0).contains { $0.id == build.id } }
                ?? build.bundleID.flatMap { bundle in projects.first { $0.bundleID == bundle } }
        }
        guard let owner else { return nil }
        return (owner, build)
    }

    private func show(_ target: PushTarget, _ resolved: (project: AppProject, build: AppBuild?)) {
        pendingOpen = nil
        if presentedViewController != nil { dismiss(animated: false) }
        view.endEditing(true)
        let id = resolved.project.id
        if let thread = target.thread, thread != model.agentThreadID(for: resolved.project) {
            route = .thread(app: id, .existing(thread))
        } else {
            route = .app(id)
        }
        sync()
        guard let build = resolved.build else { return }
        let navigation = UINavigationController(rootViewController: BuildDetailViewController(model: model, build: build))
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    /// The Mac answered and doesn't have what the notification named.
    private func showMissing(_ target: PushTarget) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: target.build != nil ? "Build not found" : "App not found",
                                      message: "It’s no longer on your Mac.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Makes what is mounted and where the springs head agree with the route.
    /// Safe to call at any moment, any number of times.
    private func sync() {
        guard !syncing else { return }
        // Leaving Home drops whatever a finger was holding there.
        if route != .grid, lift != nil { dropLift() }
        syncing = true
        defer {
            syncing = false
            renderSimulators()
            applyScene()
            onViewing?(route == .grid ? nil : route.thread != nil ? thread?.currentSessionID : agent?.currentSessionID)
        }
        // The thread level only exists inside its app; it leaves first.
        if spring.value <= 0.001, let mounted = mountedThread, route.thread != mounted.key || route.app != selectedID {
            unmountThread()
        }
        if appSpring.value <= 0.001, let app = route.app, app != selectedID {
            unmountThread()
            unmountAgent()
            mountApp(app)
        }
        if spring.value <= 0.001, mountedThread == nil, let key = route.thread, route.app == selectedID {
            mountThread(key)
        }
        for (driver, target) in [(appSpring, appTarget), (spring, threadTarget)] where driver !== dragging {
            if driver.target != target || (!driver.isAnimating && driver.value != target) {
                driver.redirect(to: target)
            }
        }
    }

    private func rested() {
        sync()
        guard dragging == nil, !appSpring.isAnimating, !spring.isAnimating else { return }
        let focus: Any? = switch route {
        case .grid: selectedID.flatMap { cells[$0] }
        case .app: agent?.view
        case .thread: thread?.view
        }
        UIAccessibility.post(notification: .screenChanged, argument: focus)
    }

    private func mountApp(_ id: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        model.selectProject(project)
        if let prepared = preparedApp, prepared.key == id {
            // Made since a finger went down on it: put in place, the rest built now.
            preparedApp = nil
            preparingApp?.cancel(); preparingApp = nil
            prepared.controller.loadViewIfNeeded()
            attach(prepared.controller, in: agentHost)
            reveal(prepared.controller)
            prepared.controller.resume()
            mountedApp = prepared
            return
        }
        let controller = agentPage(for: project, ahead: false)
        host(controller, in: agentHost)
        mountedApp = Mounted(key: id, controller: controller)
    }

    private func agentPage(for project: AppProject, ahead: Bool, composer: Composer? = nil) -> ThreadViewController {
        let controller = ThreadViewController(model: model, project: project, sessionID: model.agentThreadID(for: project), agent: true,
                                              ahead: ahead, composer: composer)
        controller.onOpenThread = { [weak self] id in self?.openThread(id) }
        controller.onPrepareThread = { [weak self] id in self?.prepareThread(id) }
        controller.onScrollBegan = { [weak self] in self?.stopPreparing() }
        controller.onTasks = { [weak self] in self?.presentTasks() }
        controller.onOpenTask = { [weak self] id in self?.presentTasks(task: id) }
        controller.onWaiting = { [weak self] in self?.presentWaiting(firstApp: project.id) }
        controller.onBuilds = { [weak self] in self?.presentBuilds() }
        controller.onBack = { [weak self] in self?.closeApp() }
        return controller
    }

    /// An app's agent page made off screen since a finger went down on the
    /// app on Home (`prepareApp`), until it opens or another is made.
    private var preparedApp: Mounted<String>?
    /// A composer made at launch for the first page made ahead.
    private var spareComposer: Composer?
    private var madeComposer = false
    private func takeComposer() -> Composer {
        defer { spareComposer = nil }
        return spareComposer ?? Composer(placeholder: "Message")
    }
    private var preparingApp: Task<Void, Never>?

    /// The finger is down on an app on Home: its agent's page is made ahead
    /// from its copy, one step a frame, as a thread's is (`prepareThread`).
    func prepareApp(_ id: String) {
        guard route == .grid, id != selectedID, preparedApp?.key != id, let project = projects.first(where: { $0.id == id }),
              let agentID = model.agentThreadID(for: project) else { return }
        preparingApp?.cancel()
        if let stale = preparedApp { dismount(stale.controller) }
        preparedApp = nil
        model.prefetch(threads: [agentID])
        preparingApp = Task { [weak self] in
            guard let self else { return }
            let composer = takeComposer()
            await DisplayFrame.next()
            guard !Task.isCancelled else { return }
            let controller = agentPage(for: project, ahead: true, composer: composer)
            preparedApp = Mounted(key: id, controller: controller)
            await DisplayFrame.next()
            guard !Task.isCancelled else { return }
            controller.loadViewIfNeeded()
            await DisplayFrame.next()
            guard !Task.isCancelled else { return }
            attach(controller, in: agentHost)
            await buildAhead(controller, conversation: .thread(agentID, appID: project.id))
        }
    }

    /// A page made ahead gets its rows, once its conversation's copy is at
    /// hand, an eighth of a screen at a time, as many as fit in a few
    /// milliseconds a frame.
    private func buildAhead(_ controller: ThreadViewController, conversation: ConversationID) async {
        if model.content(of: conversation) == nil {
            for await _ in model.updates where model.content(of: conversation) != nil || Task.isCancelled { break }
        }
        var done = false
        while !done {
            await DisplayFrame.next()
            guard !Task.isCancelled else { return }
            // Another step only if one like the last still fits.
            let frame = CACurrentMediaTime()
            var last: CFTimeInterval = 0
            repeat {
                let started = CACurrentMediaTime()
                done = controller.prepareRows()
                last = CACurrentMediaTime() - started
            } while !done && CACurrentMediaTime() - frame + last < 0.004
        }
    }

    private func unmountAgent() {
        guard let mounted = mountedApp else { return }
        mountedApp = nil
        dock.docked = []
        dismount(mounted.controller)
        dropParked()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        preparingApp?.cancel(); preparingApp = nil
        if let stale = preparedApp { dismount(stale.controller); preparedApp = nil }
        dropParked()
    }

    /// Threads kept for the app left behind, or for memory, go for good.
    private func dropParked() {
        preparing?.task.cancel()
        preparing = nil
        parked.forEach { dismount($0.controller) }
        parked = []
    }

    /// Adds a conversation as an opaque page that covers what is beneath it
    /// as it slides in, never text over text.
    private func host(_ controller: ThreadViewController, in host: UIView) {
        attach(controller, in: host)
        reveal(controller)
        controller.view.layoutIfNeeded()
    }

    /// Into the hierarchy, off screen at the right; parked pages stay there.
    private func attach(_ controller: ThreadViewController, in host: UIView) {
        guard controller.parent == nil else { return }
        controller.host = self
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.backgroundColor = Theme.paper
        controller.view.layer.shadowColor = UIColor.black.cgColor
        controller.view.layer.shadowRadius = 18
        controller.view.layer.shadowOffset = CGSize(width: -6, height: 0)
        controller.view.layer.shadowPath = UIBezierPath(rect: view.bounds).cgPath
        conceal(controller)
        host.addSubview(controller.view)
        controller.didMove(toParent: self)
    }

    /// The page about to slide in (`applyScene` moves it and gives it touches).
    private func reveal(_ controller: ThreadViewController) {
        controller.view.superview?.bringSubviewToFront(controller.view)
        controller.view.layer.shadowOpacity = 0.14
    }

    /// A page off screen at the right, out of reach: its shadow would show at the edge.
    private func conceal(_ controller: ThreadViewController) {
        controller.view.transform = CGAffineTransform(translationX: view.bounds.width, y: 0)
        controller.view.layer.shadowOpacity = 0
        controller.view.isUserInteractionEnabled = false
        controller.view.accessibilityElementsHidden = true
    }

    private func dismount(_ controller: ThreadViewController) {
        controller.tearDown()
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    /// The page for a thread of the app's that is likely to open next (a
    /// finger is down on the line that opens it, or its row in Tasks was
    /// tapped and the sheet is leaving), made off screen a few milliseconds
    /// per frame. Its push takes it as it is and builds whatever is left.
    func prepareThread(_ id: String) {
        guard let project = selectedProject, route == .app(project.id) else { return }
        let key = ThreadDestination.existing(id)
        guard preparing?.key != key, !parked.contains(where: { $0.key == key }) else { return }
        preparing?.task.cancel()
        preparing = (key, Task { [weak self] in
            guard let self else { return }
            // One step a frame: its field, the page (or a parked one put to
            // use), its view, putting it in place off screen, then its rows.
            let controller: ThreadViewController
            if let kept = reusablePage() {
                kept.retarget(to: id)
                controller = kept
            } else {
                let composer = takeComposer()
                await DisplayFrame.next()
                guard !Task.isCancelled else { return }
                controller = ThreadViewController(model: model, project: project, sessionID: id, ahead: true, composer: composer)
                controller.onBack = { [weak self] in self?.closeThread() }
            }
            park(Mounted(key: key, controller: controller))
            await DisplayFrame.next()
            guard !Task.isCancelled else { return }
            controller.loadViewIfNeeded()
            await DisplayFrame.next()
            guard !Task.isCancelled else { return }
            attach(controller, in: threadHost)
            await buildAhead(controller, conversation: .thread(id, appID: project.id))
            if !Task.isCancelled, preparing?.key == key { preparing = nil }
        })
    }

    /// A page for a thread with none parked: once a few are kept, the
    /// oldest is put to use for it (its view and cells are already made);
    /// else a new one, made ahead (inactive until `resume`).
    private func page(for id: String, project: AppProject) -> ThreadViewController {
        if let kept = reusablePage() {
            kept.retarget(to: id)
            return kept
        }
        let controller = ThreadViewController(model: model, project: project, sessionID: id, ahead: true)
        controller.onBack = { [weak self] in self?.closeThread() }
        return controller
    }

    /// The oldest parked page, taken out to be put to use, once a few are kept.
    private func reusablePage() -> ThreadViewController? {
        guard parked.count >= 3, let oldest = parked.last, oldest.controller.isViewLoaded else { return nil }
        parked.removeLast()
        return oldest.controller
    }

    @objc private func gridPanned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { stopPreparing() }
    }

    /// A finger began scrolling instead of tapping: making pages ahead stops
    /// (what is made so far is kept) and leaves the frames to the scroll.
    private func stopPreparing() {
        preparing?.task.cancel()
        preparing = nil
        preparingApp?.cancel()
        preparingApp = nil
    }

    /// Keeps a page off screen to come back to; the oldest go.
    private func park(_ page: Mounted<ThreadDestination>) {
        parked.insert(page, at: 0)
        while parked.count > 5 { dismount(parked.removeLast().controller) }
    }

    private func mountThread(_ key: ThreadDestination) {
        guard let project = selectedProject else { return }
        agent?.deactivate()
        if let index = parked.firstIndex(where: { $0.key == key }) {
            let kept = parked.remove(at: index)
            if preparing?.key == key { preparing?.task.cancel(); preparing = nil }
            kept.controller.loadViewIfNeeded()
            attach(kept.controller, in: threadHost)
            reveal(kept.controller)
            kept.controller.resume()
            mountedThread = kept
            return
        }
        if case .existing(let id) = key, parked.count >= 3 {
            // No head start: a parked page put to use builds its rows now.
            let controller = page(for: id, project: project)
            attach(controller, in: threadHost)
            reveal(controller)
            controller.resume()
            mountedThread = Mounted(key: key, controller: controller)
            return
        }
        let controller = ThreadViewController(model: model, project: project, sessionID: key.threadID)
        controller.onBack = { [weak self] in self?.closeThread() }
        host(controller, in: threadHost)
        mountedThread = Mounted(key: key, controller: controller)
    }

    private func unmountThread() {
        guard let mounted = mountedThread else { return }
        mountedThread = nil
        dock.docked = []
        // A draft has nothing to come back to; a thread is kept a while.
        if case .existing = mounted.key {
            mounted.controller.park()
            conceal(mounted.controller)
            park(mounted)
        } else {
            dismount(mounted.controller)
        }
        agent?.reactivate()
    }

    // MARK: Arranging

    /// Long-press an app, then drag it: the others make way under the
    /// finger, and it drops into the place it is over.
    @objc private func arrangePressed(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: grid)
        switch press.state {
        case .began: beginLift(at: point)
        case .changed: moveLift(to: point)
        case .ended, .cancelled, .failed: dropLift()
        default: break
        }
    }

    /// The app whose place holds `point` (in the grid's content).
    private func app(at point: CGPoint) -> Int? {
        shown.indices.first { layout.cellFrame($0).contains(point) }
    }

    private func beginLift(at point: CGPoint) {
        guard lift == nil, route == .grid, presentedViewController == nil, let index = app(at: point) else { return }
        let id = shown[index].id, frame = layout.cellFrame(index)
        Theme.selectionHaptic()
        lift = Lift(id: id, index: index, finger: point, grab: CGPoint(x: frame.midX - point.x, y: frame.midY - point.y))
        raised = id
        if let cell = cells[id] { grid.bringSubviewToFront(cell) }
        liftSpring.animate(to: 1)
        layoutGrid(animated: true)
    }

    private func moveLift(to point: CGPoint) {
        guard var held = lift else { return }
        held.finger = point
        held.index = slot(at: held.center)
        lift = held
        layoutGrid(animated: true)
        scrollNearEdges()
    }

    /// The place a cell centred at `point` drops into.
    private func slot(at point: CGPoint) -> Int {
        let layout = self.layout
        let column = Int(((point.x - StageLayout.gridMargin + StageLayout.gridGap / 2) / (layout.cellWidth + StageLayout.gridGap)).rounded(.down))
        let row = Int(((point.y - layout.gridTop) / layout.rowPitch).rounded(.down))
        let index = max(0, row) * layout.columns + min(max(0, column), layout.columns - 1)
        return min(index, max(0, projects.count - 1))
    }

    private func dropLift() {
        guard lift != nil else { return }
        let order = shown
        lift = nil
        autoscroll?.cancel()
        autoscroll = nil
        if order.map(\.id) != projects.map(\.id) {
            projects = order
            model.arrangeApps(order.map(\.id))
        }
        liftSpring.animate(to: 0)
        layoutGrid(animated: true)
    }

    /// VoiceOver's way to arrange Home: one place earlier or later.
    private func move(_ id: String, by step: Int) -> Bool {
        guard lift == nil, route == .grid, let from = projects.firstIndex(where: { $0.id == id }),
              projects.indices.contains(from + step) else { return false }
        projects.swapAt(from, from + step)
        model.arrangeApps(projects.map(\.id))
        layoutGrid(animated: true)
        return true
    }

    /// A finger holding an app near the grid's top or bottom edge scrolls
    /// it, faster the closer it is, and the app goes along.
    private func scrollNearEdges() {
        guard autoscroll == nil else { return }
        autoscroll = Task { [weak self] in
            while let self, !Task.isCancelled, let held = lift {
                let y = held.finger.y - grid.contentOffset.y, band: CGFloat = 70
                let top = layout.gridTop + band, bottom = grid.bounds.height - view.safeAreaInsets.bottom - band
                let speed = y < top ? -(top - y) / band * 14 : y > bottom ? (y - bottom) / band * 14 : 0
                let maxY = max(0, grid.contentSize.height - grid.bounds.height)
                let offset = (grid.contentOffset.y + speed).clamped(0, maxY)
                guard offset != grid.contentOffset.y else { break }
                let moved = offset - grid.contentOffset.y
                grid.contentOffset.y = offset
                moveLift(to: CGPoint(x: held.finger.x, y: held.finger.y + moved))
                await DisplayFrame.next()
            }
            self?.autoscroll = nil
        }
    }

    // MARK: Back

    /// Swipe in from the left edge to go back a level, following the finger.
    @objc private func backPanned(_ gesture: UIPanGestureRecognizer) {
        let width = max(1, view.bounds.width)
        switch gesture.state {
        case .began: beginBack()
        case .changed:
            guard dragging != nil else { return }
            moveBack(to: dragStart - gesture.translation(in: view).x / width)
        case .ended, .cancelled, .failed:
            guard let driver = dragging else { return }
            let velocity = -gesture.velocity(in: view).x / width
            let closing = gesture.state == .ended && driver.value + velocity * 0.18 < 0.5
            #if DEBUG
            MotionAudit.shared.note("back", values: ["progress": driver.value, "velocity": velocity, "closing": closing])
            #endif
            endBack(velocity: velocity, closing: closing)
        default: break
        }
    }

    /// The top level on screen: the thread if it is showing, else the app.
    private func beginBack() {
        guard dragging == nil, route != .grid else { return }
        let driver = route.thread != nil && threadTarget == 1 ? spring : appSpring
        guard driver === spring || appTarget == 1 else { return }
        driver.stop()
        dragging = driver
        dragStart = driver.value
        applyScene()
    }

    private func moveBack(to value: CGFloat) {
        dragging?.set(value.clamped())
    }

    private func endBack(velocity: CGFloat, closing: Bool) {
        guard let driver = dragging else { return }
        dragging = nil
        if closing {
            if driver === spring { closeThread() } else { closeApp() }
        }
        let target = driver === spring ? threadTarget : appTarget
        driver.animate(to: target, initialVelocity: velocity)
        sync()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === arrange {
            return route == .grid && presentedViewController == nil && projects.count > 1
                && app(at: arrange.location(in: grid)) != nil
        }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, presentedViewController == nil,
              pan.velocity(in: view).x >= 0, dragging == nil else { return false }
        if route.thread != nil {
            guard let thread, threadTarget == 1 else { return false }
            return thread.allowsBackSwipe(at: pan.location(in: thread.view))
        }
        guard let agent, appTarget == 1 else { return false }
        return agent.allowsBackSwipe(at: pan.location(in: agent.view))
    }

    /// Scrolling waits until a touch is known not to be a back swipe, so the
    /// two never move together.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer !== arrange && otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }

    // MARK: Portraits

    private var displayScale: CGFloat { view.window?.windowScene?.screen.scale ?? traitCollection.displayScale }
    private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

    private func gridPose(_ index: Int) -> PhonePose {
        layout.gridPose(cell: layout.cellFrame(index), column: index % layout.columns)
    }

    /// What a portrait shows; a different key means it must be drawn again.
    private func portraitKey(_ id: String, _ pose: PhonePose) -> String {
        "\(screenVersions[id] ?? 0):\(pose.height):\(pose.yaw):\(pose.pitch):\(dark)"
    }

    /// Redraws stale portraits one per frame, so a grid of many apps never
    /// stalls one.
    private func schedulePortraits() {
        guard portraitTask == nil, laidOut != nil else { return }
        portraitTask = Task { [weak self] in
            while let self, drawNextPortrait() { await DisplayFrame.next() }
            self?.portraitTask = nil
        }
    }

    /// Draws one stale grid portrait. False when none is stale, or when
    /// none can be drawn now. iOS forbids GPU work in the background, where
    /// it still flips the appearance for its app switcher snapshots; a
    /// portrait drawn then comes back solid black. Those wait for the return
    /// to the foreground, and a failed draw stays stale for the next pass.
    private func drawNextPortrait() -> Bool {
        guard UIApplication.shared.applicationState != .background else { return false }
        for (index, project) in shown.enumerated() {
            guard let cell = cells[project.id] else { continue }
            let pose = gridPose(index), key = portraitKey(project.id, pose)
            guard cell.portraitKey != key else { continue }
            // Apps busy at once trade places as each moves on; a portrait
            // already drawn for this column comes back without a render.
            if let drawn = cell.drawn.first(where: { $0.key == key }) {
                cell.portraitKey = key
                cell.portrait.image = drawn.image
                continue
            }
            guard let image = stage.portrait(for: project.id, pose: pose, scale: displayScale) else { return false }
            cell.portraitKey = key
            cell.portrait.image = image
            cell.drawn.removeAll { !$0.key.hasPrefix(key.prefix { $0 != ":" } + ":") }
            cell.drawn.insert((key, image), at: 0)
            if cell.drawn.count > 3 { cell.drawn.removeLast() }
            return true
        }
        return false
    }

    // MARK: Scene

    /// Every frame, from the route and the two springs alone: where the
    /// selected device stands and whether the stage or a portrait draws it,
    /// what is visible, and which screen takes touches.
    private func applyScene() {
        let width = view.bounds.width
        guard width > 0, !syncing else { return }
        let layout = self.layout
        // A spring may overshoot its end a little; screens never travel past it.
        let a = appSpring.value.clamped(), t = spring.value.clamped()
        let scroll = grid.contentOffset.y
        var origin = CGPoint(x: width / 2, y: view.safeAreaInsets.top + 58)
        let shown = self.shown
        if let id = selectedID, let index = shown.firstIndex(where: { $0.id == id }) {
            let cell = layout.cellFrame(index).offsetBy(dx: 0, dy: -scroll)
            origin = CGPoint(x: cell.midX, y: cell.minY + layout.gridPhoneHeight / 2)
        }

        // Home falls back as the conversation slides over it: every device
        // drifts away from the opened one, shrinks and fades.
        home.update(\.alpha, to: (1 - a * 1.6).clamped())
        home.update(\.isHidden, to: a >= 1 && !appSpring.isAnimating && dragging == nil)
        let raise = 1 + 0.08 * liftSpring.value
        for (index, project) in shown.enumerated() {
            guard let cell = cells[project.id] else { continue }
            let frame = layout.cellFrame(index).offsetBy(dx: 0, dy: -scroll)
            let recede = layout.recede(frame, from: origin, progress: a)
            let transform = project.id == raised ? CATransform3DScale(recede, raise, raise, 1) : recede
            if !CATransform3DEqualToTransform(cell.layer.transform, transform) { cell.layer.transform = transform }
            cell.update(\.alpha, to: layout.recedeAlpha(progress: a))
            cell.captionAlpha = project.id == selectedID ? (1 - a * 4).clamped() : 1
        }
        dock.update(\.alpha, to: a)
        dock.update(\.isUserInteractionEnabled, to: route.app != nil && a > 0.5)

        // Flat pushes. The agent's conversation slides over Home; a thread
        // slides over the agent while the agent drifts a third as far left.
        // The device travels on its own.
        agentHost.update(\.isHidden, to: a <= 0.001)
        agent?.setTransitionProgress(a * (1 - t))
        agent?.view.update(\.transform, to: CGAffineTransform(translationX: width * (1 - a) - (layout.reducedMotion ? 0 : width * 0.3 * t), y: 0))
        thread?.setTransitionProgress(t)
        thread?.view.update(\.transform, to: CGAffineTransform(translationX: width * (1 - t), y: 0))
        // The agent, fully covered and still, may change unseen.
        agent?.outOfSight = thread != nil && t >= 1 && !spring.isAnimating && dragging == nil

        // Touches go to the screen the route names, from the first frame of its
        // transition. A conversation on its way out still covers the one
        // beneath, so touches on it stop there.
        let onGrid = route == .grid
        let onAgent = route.app != nil && route.app == selectedID && route.thread == nil
        let onThread = threadTarget == 1
        home.update(\.isUserInteractionEnabled, to: onGrid)
        home.update(\.accessibilityElementsHidden, to: !onGrid)
        agent?.view.update(\.isUserInteractionEnabled, to: onAgent)
        agent?.view.update(\.accessibilityElementsHidden, to: !onAgent)
        thread?.view.update(\.isUserInteractionEnabled, to: onThread)
        thread?.view.update(\.accessibilityElementsHidden, to: !onThread)
        threadHost.swallowsTouches = thread != nil && !onThread
        #if DEBUG
        audit(a: a, t: t)
        #endif
    }

    // MARK: Sheets

    private func presentBuilds() {
        guard let project = selectedProject, presentedViewController == nil, route == .app(project.id) else { return }
        Theme.selectionHaptic()
        let controller = BuildsViewController(model: model, project: project)
        controller.onNewThread = { [weak self, weak controller] in
            controller?.dismiss(animated: true) { self?.openThread(nil) }
        }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        present(controller, animated: true)
    }

    private func presentTasks(threads: Bool = false, task: String? = nil) {
        guard let project = selectedProject, presentedViewController == nil, route == .app(project.id) else { return }
        Theme.selectionHaptic()
        let controller = TasksViewController(model: model, project: project, threads: threads, task: task)
        controller.onOpen = { [weak self, weak controller] id in
            // Made while the sheet leaves.
            if let id { self?.prepareThread(id) }
            controller?.dismiss(animated: true) { self?.openThread(id) }
        }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }

    /// Everything waiting on you, across apps (`firstApp` first). Answering
    /// happens in the sheet; a needs-you task opens its app or thread.
    private func presentWaiting(firstApp: String? = nil) {
        guard presentedViewController == nil else { return }
        Theme.selectionHaptic()
        let controller = WaitingViewController(model: model, firstApp: firstApp)
        controller.onOpen = { [weak self] project, thread in
            guard let self else { return }
            view.endEditing(true)
            let agent = projects.first { $0.id == project }.flatMap(model.agentThreadID)
            if let thread, thread != agent {
                route = .thread(app: project, .existing(thread))
            } else {
                route = .app(project)
            }
            sync()
        }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }

    private func presentImport() {
        guard route == .grid, presentedViewController == nil else { return }
        let importer = AppImportNavigationController(model: model)
        importer.onImport = { [weak self, weak importer] project in
            importer?.dismiss(animated: true) {
                guard let self else { return }
                self.render()
                guard let index = self.projects.firstIndex(where: { $0.id == project.id }) else { return }
                let frame = self.layout.cellFrame(index)
                self.grid.scrollRectToVisible(frame.insetBy(dx: 0, dy: -self.layout.gridTop), animated: !Motion.reduced)
            }
        }
        present(importer, animated: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        switch route {
        case .thread: closeThread(); return true
        case .app: closeApp(); return true
        case .grid: return false
        }
    }
}

extension StudioViewController: ConversationHost {
    var simulatorFeeds: SimulatorFeeds { feeds }
    var expandsSimulators: Bool { true }
    var showsAgentJelly: Bool { true }
    /// Large and touchable, flown up from its block in the conversation
    /// or its picture in the dock, and back to whichever shows it then.
    func expandSimulator(_ use: SimulatorUse) {
        guard use.live, simulatorViewer?.route != .open, let window = view.window else { return }
        let front = route.thread != nil ? thread : agent
        let other = use.threadID != front?.currentSessionID
        let origin = MediaOrigin(locate: { [weak self] in
            guard let self else { return nil }
            return (route.thread != nil ? thread : agent)?.simulatorSpot(use.id) ?? dock.spot(use.id)
        }, conceal: { [weak self] hidden in
            if hidden { self?.dock.lent.insert(use.id) } else { self?.dock.lent.remove(use.id) }
        })
        simulatorViewer = MediaViewer.open(.simulator(use, feeds: feeds, openThread: other ? { [weak self] in
            guard let self else { return }
            if use.threadID == agent?.currentSessionID { closeThread() } else if route.thread?.threadID != use.threadID { openThread(use.threadID) }
        } : nil), from: origin, in: window)
    }
    func conversation(_ conversation: ThreadViewController, showsSimulators ids: Set<String>) {
        guard conversation === (thread ?? agent) else { return }
        dock.docked = ids
    }
}

/// A container that is never itself the target of a touch, unless it is
/// told to swallow touches that land on its (non-interactive) content.
final class PassthroughView: UIView {
    var swallowsTouches = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if swallowsTouches, subviews.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return self }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// One app in the grid: a still portrait of its device, which scrolls with
/// the grid like any view, and its name. While the app's agent works (or
/// needs you) it peeks over the device's top edge, eyes on the screen; idle,
/// it sinks back behind it.
@MainActor
final class GridCell: UIControl {
    let id: String
    let portrait = UIImageView()
    var portraitKey = ""
    /// Recent portraits by key, newest first, for the current screen.
    var drawn: [(key: String, image: UIImage)] = []
    var phoneHeight: CGFloat = 0 { didSet { setNeedsLayout() } }
    var captionAlpha: CGFloat = 1 {
        didSet { if captionAlpha != oldValue { name.alpha = captionAlpha; peek.alpha = captionAlpha } }
    }
    private let name = Theme.label("", Theme.appCaptionFont())
    /// The app's agent, behind the portrait's top edge.
    private let peek = JellyView(.agent(.working), canvas: .roomy(GridCell.peekSize))
    private static let peekSize: CGFloat = 26
    private var peeking = false

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "project.cell"
        accessibilityValue = id
        name.textAlignment = .center
        name.lineBreakMode = .byTruncatingTail
        peek.isHidden = true
        [peek, portrait, name].forEach {
            $0.isUserInteractionEnabled = false
            addSubview($0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name text: String, phase: ChatSession.Phase) {
        if name.text != text { name.text = text }
        if phase != .idle { peek.look = .agent(JellyLook.Mood(phase)) }
        setPeeking(phase != .idle)
        accessibilityLabel = text
        accessibilityValue = phase == .needsYou ? "Needs you" : (phase == .working ? "Working" : nil)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = DeviceStage.portraitSize(height: phoneHeight)
        portrait.bounds = CGRect(origin: .zero, size: size)
        portrait.center = CGPoint(x: bounds.midX, y: phoneHeight / 2)
        let top = phoneHeight + 12
        let width = min(bounds.width, ceil(name.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 21)).width))
        name.frame = CGRect(x: (bounds.width - width) / 2, y: top, width: width, height: 21)
        // Its body rests a little over half above the device's top edge (the
        // portrait's picture has room around the device).
        let s = Self.peekSize
        peek.place(in: CGRect(x: bounds.midX - s / 2, y: portrait.center.y - phoneHeight / 2 - s * 0.58, width: s, height: s))
    }

    /// Rises over the edge, or sinks behind it, on one interruptible spring.
    private func setPeeking(_ on: Bool) {
        guard on != peeking else { return }
        peeking = on
        peek.animates = on
        let down = CGAffineTransform(translationX: 0, y: Self.peekSize * 0.75)
        if on, peek.isHidden {
            peek.isHidden = false
            peek.transform = down
        }
        let moves = window != nil && !Motion.reduced
        let change = { self.peek.transform = on ? .identity : down }
        guard moves else {
            change()
            peek.isHidden = !on
            return
        }
        UIView.animate(springDuration: on ? 0.55 : 0.4, bounce: on ? 0.32 : 0, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: change) { _ in
            // Sunk out of sight: hidden, so it never draws behind the screen.
            if !self.peeking { self.peek.isHidden = true }
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue, !Motion.reduced else { return }
            let scale: CGFloat = isHighlighted ? 0.95 : 1
            UIView.animate(springDuration: 0.3, bounce: 0.25, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.portrait.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }
}
