import AVFoundation
import AVKit
import UIKit

/// What a simulator use shows: the simulator itself while it is in use,
/// the recording filed in the thread's media afterwards, or nothing.
enum SimulatorContent: Equatable {
    case live(SimulatorTarget)
    case recording(mediaID: String)
    case unavailable
}

/// A simulator an agent is using now, or used in a turn and recorded.
struct SimulatorUse: Equatable {
    /// Squircle's session ID, or `t3:<thread>:<device>` for a device T3
    /// opened for a working thread without Squircle recording it.
    let id: String
    let threadID: String
    let deviceName: String
    let started: Date
    let content: SimulatorContent

    init(id: String, threadID: String, deviceName: String, started: Date, content: SimulatorContent) {
        self.id = id; self.threadID = threadID; self.deviceName = deviceName; self.started = started; self.content = content
    }

    /// From the service's fields: live, or recorded once a recording is filed.
    init(id: String, threadID: String, target: SimulatorTarget, deviceName: String, started: Date, live: Bool, recordingID: String? = nil) {
        let content: SimulatorContent = live ? .live(target) : recordingID.map { .recording(mediaID: $0) } ?? .unavailable
        self.init(id: id, threadID: threadID, deviceName: deviceName, started: started, content: content)
    }

    /// The simulator to stream, while it is in use.
    var target: SimulatorTarget? { if case .live(let target) = content { target } else { nil } }
    var live: Bool { target != nil }
    /// The recording in the thread's media, once filed.
    var recordingID: String? { if case .recording(let id) = content { id } else { nil } }
}

/// Draws decoded simulator pictures flat, through the system's video layer:
/// no 3D scene, no per-frame drawing of our own. Its renderer runs on the
/// host clock; a `SimulatorOutput` feeds it pictures with their times.
@MainActor
final class SimulatorScreen: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    var renderer: AVSampleBufferVideoRenderer { display.sampleBufferRenderer }
    /// Pixel size of the latest picture; zero before the first.
    private(set) var pictureSize: CGSize = .zero
    fileprivate(set) var target: SimulatorTarget?
    var onPictureSize: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        display.videoGravity = .resizeAspect
        backgroundColor = UIColor(white: 0.06, alpha: 1)
        isUserInteractionEnabled = false
        accessibilityIgnoresInvertColors = true
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            display.controlTimebase = timebase
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Height over width of what is shown, or a phone's when nothing has arrived.
    var aspect: CGFloat { pictureSize.width > 0 ? pictureSize.height / pictureSize.width : 2.17 }

    #if DEBUG
    private var showings = 0
    #endif

    /// The size of the picture now shown.
    func showing(_ buffer: CVPixelBuffer) {
        #if DEBUG
        showings += 1
        if showings % 240 == 0 {
            let renderer = renderer
            Task {
                guard let metrics = await renderer.videoPerformanceMetrics else { return }
                print("Simulator screen: \(metrics.totalNumberOfFrames) frames, \(metrics.numberOfDroppedFrames) dropped, \(metrics.numberOfCorruptedFrames) corrupted")
            }
        }
        #endif
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if size != pictureSize {
            pictureSize = size
            onPictureSize?()
        }
    }
}

/// One T3 stream per simulator, shared by every screen showing it (a PiP
/// and the turn it belongs to), running only while some screen shows it.
/// Its owner calls `close()` when it goes away: a running stream holds
/// itself until stopped.
@MainActor
final class SimulatorFeeds {
    private struct Weak { weak var screen: SimulatorScreen? }
    private final class Feed {
        let stream: T3DeviceStream
        var output: SimulatorOutput { stream.output }
        var screens: [Weak] = []
        var last: CVPixelBuffer?
        /// Stops the stream once nothing has shown it for a moment.
        var linger: Task<Void, Never>?
        var orientation = "portrait"
        var lastInput: CGPoint?
        init(stream: T3DeviceStream) { self.stream = stream }
    }
    private var feeds: [SimulatorTarget: Feed] = [:]
    private let model: SquircleModel
    /// Streams run only in the foreground; once closed, nothing attaches.
    private enum OwnerState { case foreground, background, closed }
    private var owner = OwnerState.foreground
    private var observers: [Task<Void, Never>] = []
    /// Told when a feed's interactivity changes (input became ready or was
    /// lost), for as long as the returned observer lives.
    func observeInteractive(_ handler: @escaping () -> Void) -> Observer {
        let observer = Observer()
        interactiveObservers.append((WeakObserver(observer), handler))
        return observer
    }
    final class Observer {}
    private struct WeakObserver { weak var observer: Observer?; init(_ observer: Observer) { self.observer = observer } }
    private var interactiveObservers: [(WeakObserver, () -> Void)] = []
    private func interactiveChanged() {
        interactiveObservers.removeAll { $0.0.observer == nil }
        interactiveObservers.forEach { $0.1() }
    }

    init(model: SquircleModel) {
        self.model = model
        for (name, active) in [(UIApplication.didEnterBackgroundNotification, false), (UIApplication.didBecomeActiveNotification, true)] {
            observers.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard let self else { return }
                    setActive(active)
                }
            })
        }
    }

    /// Stops every stream and observer; nothing attaches afterwards.
    func close() {
        owner = .closed
        observers.forEach { $0.cancel() }
        observers = []
        for feed in feeds.values { feed.linger?.cancel(); feed.stream.stop() }
        feeds = [:]
    }

    private func setActive(_ value: Bool) {
        guard owner != .closed else { return }
        owner = value ? .foreground : .background
        for feed in feeds.values { if value { feed.stream.start() } else { feed.stream.stop() } }
    }

    /// Shows `target` on `screen` (nil: nothing), sharing a running stream.
    func attach(_ screen: SimulatorScreen, to target: SimulatorTarget?) {
        guard screen.target != target else { return }
        if let old = screen.target, let feed = feeds[old] {
            feed.output.remove(screen.renderer)
            feed.screens.removeAll { $0.screen == nil || $0.screen === screen }
            release(old)
        }
        screen.target = target
        guard owner != .closed, let target, let feed = feeds[target] ?? makeFeed(target) else { return }
        feed.linger?.cancel()
        feed.linger = nil
        feed.screens.append(Weak(screen: screen))
        feed.output.add(screen.renderer, showing: feed.last)
        if let last = feed.last { screen.showing(last) }
    }

    /// A stream nobody shows stops after a moment, not at once: a picture
    /// moving between the PiP and its turn, or a reused cell, would otherwise
    /// reconnect from scratch (seconds on a cellular link).
    private func release(_ target: SimulatorTarget) {
        guard let feed = feeds[target] else { return }
        feed.screens.removeAll { $0.screen == nil }
        guard feed.screens.isEmpty, feed.linger == nil else { return }
        feed.linger = Task { [weak self, weak feed] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let feed, feeds[target] === feed else { return }
            feed.screens.removeAll { $0.screen == nil }
            guard feed.screens.isEmpty else { feed.linger = nil; return }
            feed.stream.stop()
            feeds[target] = nil
        }
    }

    private func makeFeed(_ target: SimulatorTarget) -> Feed? {
        guard let http = model.gateway?.http else { return nil }
        let feed = Feed(stream: T3DeviceStream(http: http, base: model.devices["hubBasePath"].string ?? "/api/device-hub",
                                               target: target, output: SimulatorOutput()))
        feed.stream.onFrame = { [weak self, weak feed, weak stream = feed.stream] buffer in
            // A feed nobody owns any more must not keep its stream running.
            guard let feed else { stream?.stop(); return }
            feed.last = buffer
            for weak in feed.screens { weak.screen?.showing(buffer) }
            if feed.screens.contains(where: { $0.screen == nil }) { self?.release(target) }
        }
        feed.stream.onScreen = { [weak feed] in feed?.orientation = $0["orientation"].string ?? "portrait" }
        feed.stream.onInteractive = { [weak self] _ in self?.interactiveChanged() }
        feeds[target] = feed
        if owner == .foreground { feed.stream.start() }
        return feed
    }

    func isInteractive(_ target: SimulatorTarget) -> Bool { feeds[target]?.stream.isInteractive == true }

    /// A touch on `screen`, in its own coordinates. False when it missed the picture.
    @discardableResult
    func touch(_ phase: String, at point: CGPoint, on screen: SimulatorScreen) -> Bool {
        guard let target = screen.target, let feed = feeds[target], feed.stream.isInteractive, screen.pictureSize.width > 0 else { return false }
        let mapped = SimulatorSurface.point(point, bounds: screen.bounds, size: screen.pictureSize, orientation: feed.orientation)
        guard let input = mapped ?? (phase == "begin" ? nil : feed.lastInput) else { return false }
        feed.lastInput = phase == "end" ? nil : input
        feed.stream.touch(phase, point: input)
        return true
    }

    func home(_ target: SimulatorTarget) {
        guard let stream = feeds[target]?.stream else { return }
        Task { try? await stream.send(tag: 4, payload: ["button": "home"]) }
    }
}

/// Floating pictures of the simulators this app's agents are using right
/// now. One sits small in a corner the person drags it to; two or more
/// collapse there into a deck (the most recently started on top, the rest
/// peeking behind it, a count badge) that fans out into a labelled row when
/// tapped. Tapping a picture asks for it large (`onExpand`, the media
/// viewer); while it is lent out its place stays empty. Only pictures that
/// can be seen decode, and one still waiting for its first.
/// Everything shown is derived from `uses`, the corner, and three springs.
@MainActor
final class SimulatorDock: UIView {
    enum Corner: String { case topLeft, topRight, bottomLeft, bottomRight }

    var onExpand: ((SimulatorUse) -> Void)?
    /// Uses whose own block in the conversation is on screen show there instead.
    var docked = Set<String>() { didSet { if docked != oldValue { animateLayout() } } }
    var bottomInset: CGFloat = 120 { didSet { if bottomInset != oldValue { setNeedsLayout() } } }
    /// The picture the viewer shows large: its place is kept, empty.
    var lent = Set<String>() { didSet { if lent != oldValue { layoutDock() } } }
    private(set) var uses: [SimulatorUse] = []
    private var currentThread: String?
    private var titles: [String: String] = [:]
    /// The app's agent's thread: its pictures are labelled with the big
    /// jelly, every other thread's with that worker's.
    var agentThread: String?
    private let feeds: SimulatorFeeds
    private var pips: [String: PiP] = [:]
    private var order: [String] = []

    private var corner: Corner
    /// The deck's top-left while it is dragged or settling into a corner.
    private let originX = SpringDriver()
    private let originY = SpringDriver()
    private var dragging = false
    private var dragStart = CGPoint.zero
    /// Where the person sent the dock.
    enum Route: Equatable { case collapsed, fanned }
    private var route = Route.collapsed
    /// 0 = in the deck, 1 = fanned out in a row.
    private let fan = SpringDriver()
    #if DEBUG
    private var loggedDock = ""
    #endif

    private let backdrop = UIView()
    private let badge = Theme.label("", Theme.Text.caption, color: Theme.onAccent)

    init(feeds: SimulatorFeeds) {
        self.feeds = feeds
        corner = Corner(rawValue: UserDefaults.standard.string(forKey: "squircle.simulator.corner") ?? "") ?? .topRight
        super.init(frame: .zero)
        backdrop.backgroundColor = UIColor.black
        backdrop.alpha = 0
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(gather)))
        backdrop.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(backdropPanned(_:))))
        addSubview(backdrop)
        badge.backgroundColor = Theme.accent
        badge.textAlignment = .center
        badge.layer.cornerRadius = 9 // half its 18-point height: a capsule
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true
        badge.isUserInteractionEnabled = false
        badge.alpha = 0
        addSubview(badge)
        fan.parameters = SpringDriver.Parameters(response: 0.4, damping: 0.8)
        originX.parameters = SpringDriver.Parameters(response: 0.38, damping: 0.8)
        originY.parameters = originX.parameters
        for driver in [fan, originX, originY] {
            driver.onChange = { [weak self] _ in self?.layoutDock() }
            driver.onRest = { [weak self] _ in self?.sync() }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SQUIRCLE_SIM_FAN"] == "1" { Task { [weak self] in await self?.demoFan() } }
        #endif
    }

    #if DEBUG
    /// `SQUIRCLE_SIM_FAN=1`: fans the deck out, opens the oldest picture,
    /// fans again and gathers, through the same paths as taps.
    private func demoFan() async {
        let steps: [(Double, (SimulatorDock) -> Void)] = [
            (8, { dock in dock.deck.first.map { dock.tapped($0.id) } }),
            (3, { dock in dock.deck.last.map { dock.tapped($0.id) } }),
            (5, { dock in dock.deck.first.map { dock.tapped($0.id) } }),
            (2, { $0.gather() }),
        ]
        for (delay, step) in steps {
            try? await Task.sleep(for: .seconds(delay))
            step(self)
        }
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Simulators in use, the conversation on screen and thread titles.
    func update(uses next: [SimulatorUse], currentThread: String?, titles: [String: String]) {
        #if DEBUG
        // `SQUIRCLE_SIM_COPIES=N`: the first live simulator N times over, for checking the deck.
        var next = next
        if let copies = ProcessInfo.processInfo.environment["SQUIRCLE_SIM_COPIES"].flatMap(Int.init), let first = next.first {
            next += (1..<max(copies, 1)).map { SimulatorUse(id: first.id + "#\($0)", threadID: first.threadID, deviceName: first.deviceName,
                                                            started: first.started.addingTimeInterval(Double($0)), content: first.content) }
        }
        #endif
        self.currentThread = currentThread
        self.titles = titles
        let ids = next.map(\.id)
        guard next != uses || ids != order else { layoutDock(); return }
        uses = next
        for (id, pip) in pips where !ids.contains(id) {
            pips[id] = nil
            feeds.attach(pip.screen, to: nil)
            UIView.animate(springDuration: 0.35, bounce: 0) {
                pip.alpha = 0
                pip.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            } completion: { _ in pip.removeFromSuperview() }
        }
        for use in next where pips[use.id] == nil {
            let pip = PiP(use: use)
            pip.screen.onPictureSize = { [weak self] in self?.animateLayout() }
            pip.onTap = { [weak self] in self?.tapped(use.id) }
            pip.onPan = { [weak self] gesture in self?.panned(gesture) }
            insertSubview(pip, belowSubview: badge)
            pips[use.id] = pip
            pip.alpha = 0
            pip.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }
        order = ids
        sync()
        animateLayout()
    }

    /// The picture showing `id` while it is in the dock, for the viewer to
    /// fly from and back to.
    func spot(_ id: String) -> MediaSpot? {
        guard deck.contains(where: { $0.id == id }), let pip = pips[id] else { return nil }
        return MediaSpot(pip, style: pip.screen.layer)
    }

    // MARK: State

    /// A tap on a picture: the deck fans out; a single picture or one in
    /// the row comes large (the row gathers behind it).
    private func tapped(_ id: String) {
        guard let use = uses.first(where: { $0.id == id }) else { return }
        if deck.count > 1, route == .collapsed {
            Theme.openHaptic()
            route = .fanned
            sync()
        } else {
            route = .collapsed
            sync()
            onExpand?(use)
        }
    }

    @objc private func gather() {
        guard route == .fanned else { return }
        Theme.selectionHaptic()
        route = .collapsed
        sync()
    }

    /// The springs head to whatever the route implies.
    private func sync() {
        if deck.count < 2, route == .fanned { route = .collapsed }
        let fanTarget: CGFloat = route == .fanned ? 1 : 0
        if fan.target != fanTarget || (!fan.isAnimating && fan.value != fanTarget) {
            fan.redirect(to: fanTarget)
        }
        if !dragging, !originX.isAnimating, !originY.isAnimating {
            let rest = cornerOrigin(corner)
            originX.set(rest.x)
            originY.set(rest.y)
        }
        restack()
        layoutDock()
    }

    /// The deck's top picture above the rest.
    private func restack() {
        for use in deck.reversed() { if let pip = pips[use.id] { insertSubview(pip, belowSubview: badge) } }
    }

    // MARK: Geometry

    private static let deckWidth: CGFloat = 80
    private static let peek: CGFloat = 6
    private static let gap = Theme.Space.row
    private static let captionHeight: CGFloat = 16

    /// Only a simulator whose feed has drawn a picture joins the dock: a
    /// session whose video never starts would be an empty black card.
    private var shown: [SimulatorUse] { uses.filter { !docked.contains($0.id) && pictured($0) } }
    private func pictured(_ use: SimulatorUse) -> Bool { (pips[use.id]?.screen.pictureSize.width ?? 0) > 0 }
    /// Most recently started first: the deck's top picture and the row's corner end.
    private var deck: [SimulatorUse] { shown.reversed() }

    private func showsCaption(_ use: SimulatorUse) -> Bool { use.threadID != currentThread }

    private func aspect(_ use: SimulatorUse?) -> CGFloat { use.flatMap { pips[$0.id]?.screen.aspect } ?? 2.17 }

    private var deckSize: CGSize {
        let deck = self.deck
        let height = (Self.deckWidth * aspect(deck.first)).rounded()
        let caption = deck.count == 1 && showsCaption(deck[0]) ? Self.captionHeight + Theme.Space.tight : 0
        return CGSize(width: Self.deckWidth, height: height + Self.peek * CGFloat(min(max(deck.count - 1, 0), 2)) + caption)
    }

    /// Picture `index` of the deck: the top one at the origin, each one
    /// behind a little smaller with its lower edge peeking out.
    private func deckFrame(_ index: Int, top: SimulatorUse?) -> CGRect {
        let height = (Self.deckWidth * aspect(top)).rounded()
        let depth = CGFloat(min(index, 3))
        let scale = 1 - 0.08 * depth
        let size = CGSize(width: Self.deckWidth * scale, height: height * scale)
        return CGRect(x: originX.value + (Self.deckWidth - size.width) / 2,
                      y: originY.value + height + Self.peek * depth - size.height, width: size.width, height: size.height)
    }

    /// Picture `index` of the row fanned out from the corner, captions beneath.
    private func fanFrame(_ index: Int, of count: Int, use: SimulatorUse) -> CGRect {
        let area = self.area
        let width = min(112, (area.width - Self.gap * CGFloat(count - 1)) / CGFloat(max(count, 1))).rounded(.down)
        let height = (width * aspect(use)).rounded()
        let step = CGFloat(index) * (width + Self.gap)
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: left ? area.minX + step : area.maxX - width - step,
                      y: top ? area.minY : max(area.minY, area.maxY - height - Self.captionHeight - Theme.Space.tight),
                      width: width, height: height)
    }

    private var area: CGRect {
        CGRect(x: Theme.Space.rowPad, y: safeAreaInsets.top + 56, width: bounds.width - 2 * Theme.Space.rowPad,
               height: max(0, bounds.height - bottomInset - safeAreaInsets.top - 56))
    }

    private func cornerOrigin(_ corner: Corner) -> CGPoint {
        let area = self.area, size = deckSize
        let x = corner == .topLeft || corner == .bottomLeft ? area.minX : area.maxX - size.width
        let y = corner == .topLeft || corner == .topRight ? area.minY : max(area.minY, area.maxY - size.height)
        return CGPoint(x: x, y: y)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        sync()
    }

    private func animateLayout() {
        UIView.animate(springDuration: 0.4, bounce: 0.12, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.sync()
        }
    }

    /// Everything one picture is, derived at once from the route and the
    /// springs: where it is drawn, whether it can be seen, whether it takes
    /// taps and whether it decodes. Only a picture that can be seen holds a
    /// feed; one lent to the viewer keeps its place and its feed, unseen.
    private struct FrameProjection {
        var frame: CGRect
        var alpha: CGFloat
        var shade: CGFloat
        var caption: CGFloat
        var touchable: Bool
        var feed: SimulatorTarget?
    }

    private func projection(_ use: SimulatorUse, deck: [SimulatorUse], f: CGFloat) -> FrameProjection {
        let index = deck.firstIndex(of: use)
        var frame: CGRect, alpha: CGFloat, shade: CGFloat = 0
        if let index {
            frame = .lerp(deckFrame(index, top: deck.first), fanFrame(index, of: deck.count, use: use), f)
            alpha = index <= 2 ? 1 : f
            shade = 0.18 * CGFloat(min(index, 2)) * (1 - f)
        } else {
            frame = deckFrame(0, top: deck.first)
            alpha = 0
        }
        let lent = self.lent.contains(use.id)
        let caption: CGFloat = deck.count > 1 ? f : (showsCaption(use) ? 1 : 0)
        let reachable = index == 0 || (index != nil && route == .fanned)
        // Behind the deck's top only an edge peeks out: it keeps its last picture.
        let spread = route == .fanned || f > 0.001
        // One not yet pictured streams unseen until its first picture.
        let decodes = alpha > 0.001 && (lent || index == 0 || (index != nil && spread))
            || (!pictured(use) && !docked.contains(use.id))
        return FrameProjection(frame: frame, alpha: lent ? 0 : alpha, shade: shade, caption: caption,
                               touchable: reachable && !lent, feed: decodes ? use.target : nil)
    }

    /// Every PiP's frame, feed, the badge and backdrop, from the state alone.
    private func layoutDock() {
        guard bounds.width > 0 else { return }
        let f = fan.value.clamped()
        let deck = self.deck
        let fanned = route == .fanned
        #if DEBUG
        var decoding = Set<String>()
        defer {
            let state = "\(route) lent \(lent.map { $0.suffix(2) }) decoding \(uses.filter { decoding.contains($0.id) }.map { $0.id.suffix(2) }) shown \(deck.map { $0.id.suffix(2) })"
            if state != loggedDock {
                loggedDock = state
                print("Simulator dock: " + state)
            }
        }
        #endif
        for use in uses {
            guard let pip = pips[use.id] else { continue }
            let p = projection(use, deck: deck, f: f)
            pip.transform = .identity
            pip.frame = p.frame
            pip.alpha = p.alpha
            pip.shade.alpha = p.shade
            pip.label(titles[use.threadID] ?? "Thread",
                      jelly: use.threadID == agentThread ? .agent(.working) : .worker(use.threadID, .working))
            pip.caption.alpha = p.caption
            pip.isUserInteractionEnabled = p.touchable
            feeds.attach(pip.screen, to: p.feed)
            #if DEBUG
            if p.feed != nil { decoding.insert(use.id) }
            #endif
            pip.accessibilityLabel = deck.count > 1 && !fanned && deck.first == use
                ? "\(deck.count) simulators"
                : (titles[use.threadID] ?? "Agent") + " simulator, " + use.deviceName
        }
        let top = deckFrame(0, top: deck.first)
        badge.text = "\(deck.count)"
        let badgeWidth = max(18, badge.intrinsicContentSize.width + Theme.Space.rowPad)
        badge.frame = CGRect(x: top.maxX - badgeWidth / 2 - Theme.Space.tight, y: top.minY - 5,
                             width: badgeWidth, height: 18)
        badge.alpha = deck.count > 1 && lent.isEmpty ? 1 - f : 0
        backdrop.alpha = 0.2 * f
        backdrop.isUserInteractionEnabled = fanned
        accessibilityElements = deck.prefix(fanned ? deck.count : 1).compactMap { pips[$0.id] }
    }

    // MARK: Gestures

    /// In the deck: the whole deck follows the finger, then springs to the
    /// corner it was thrown toward. Fanned out: a drag gathers the row.
    private func panned(_ gesture: UIPanGestureRecognizer) {
        if route == .fanned {
            if gesture.state == .began { gather() }
            return
        }
        switch gesture.state {
        case .began:
            dragging = true
            originX.stop(); originY.stop()
            dragStart = CGPoint(x: originX.value, y: originY.value)
        case .changed:
            let t = gesture.translation(in: self)
            originX.set(dragStart.x + t.x)
            originY.set(dragStart.y + t.y)
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            let v = gesture.velocity(in: self)
            let size = deckSize
            let projected = CGPoint(x: originX.value + size.width / 2 + v.x * 0.2, y: originY.value + size.height / 2 + v.y * 0.2)
            let area = self.area
            let left = projected.x < area.midX, top = projected.y < area.midY
            let next: Corner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
            if next != corner { Theme.selectionHaptic() }
            corner = next
            UserDefaults.standard.set(next.rawValue, forKey: "squircle.simulator.corner")
            let rest = cornerOrigin(next)
            originX.animate(to: rest.x, initialVelocity: v.x)
            originY.animate(to: rest.y, initialVelocity: v.y)
        default: break
        }
    }

    /// Fanned out: any drag outside gathers the row.
    @objc private func backdropPanned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { gather() }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// One floating simulator picture with its thread's name beneath.
@MainActor
private final class PiP: UIView {
    let use: SimulatorUse
    let screen = SimulatorScreen()
    let caption = Theme.label("", Theme.Text.caption, color: .secondaryLabel)
    /// Darkens a picture lying behind the deck's top one.
    let shade = UIView()
    private let frameView = UIView()
    private let dot = UIView()
    var onTap: (() -> Void)?
    var onPan: ((UIPanGestureRecognizer) -> Void)?
    /// A device screen's corner at this size: real geometry, not a token.
    private static let cornerRadius: CGFloat = 12

    init(use: SimulatorUse) {
        self.use = use
        super.init(frame: .zero)
        frameView.layer.cornerCurve = .continuous
        frameView.layer.cornerRadius = Self.cornerRadius
        frameView.layer.shadowColor = UIColor.black.cgColor
        frameView.layer.shadowOpacity = 0.22
        frameView.layer.shadowRadius = 14
        frameView.layer.shadowOffset = CGSize(width: 0, height: 6)
        frameView.isUserInteractionEnabled = false
        screen.layer.cornerCurve = .continuous
        screen.layer.cornerRadius = Self.cornerRadius
        screen.clipsToBounds = true
        shade.backgroundColor = .black
        shade.alpha = 0
        shade.layer.cornerCurve = .continuous
        shade.layer.cornerRadius = Self.cornerRadius
        shade.isUserInteractionEnabled = false
        dot.backgroundColor = Theme.failure
        dot.layer.cornerRadius = 3.5
        dot.isUserInteractionEnabled = false
        caption.textAlignment = .center
        caption.lineBreakMode = .byTruncatingTail
        [frameView, screen, shade, dot, caption].forEach(addSubview)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "simulator.pip"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let picture = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: bounds.height))
        frameView.frame = picture
        frameView.layer.shadowPath = UIBezierPath(roundedRect: picture, cornerRadius: Self.cornerRadius).cgPath
        screen.frame = picture
        shade.frame = picture
        dot.frame = CGRect(x: Theme.Space.row, y: Theme.Space.row, width: 7, height: 7)
        caption.frame = CGRect(x: 0, y: picture.maxY + Theme.Space.tight, width: bounds.width, height: 16)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -4, dy: -4).contains(point)
    }

    private var labelled: (String, JellyLook)?

    /// Its thread's name, led by the jelly of the agent driving it.
    func label(_ title: String, jelly: JellyLook) {
        guard labelled?.0 != title || labelled?.1 != jelly else { return }
        labelled = (title, jelly)
        let text = NSMutableAttributedString()
        let canvas = JellyCanvas.tight(12)
        if let image = JellySprites.shared.image(jelly, canvas, traits: traitCollection) {
            let attachment = NSTextAttachment(image: image)
            let body = canvas.fitting(jelly).body
            attachment.bounds = CGRect(x: 0, y: (caption.font.capHeight - 12) / 2 - (image.size.height - body.maxY),
                                       width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: title))
        caption.attributedText = text
    }

    @objc private func tapped() { onTap?() }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) { onPan?(gesture) }
}

/// The simulator a turn used: live while the agent uses it, then the
/// recording, playing muted in place. Tapping it opens it large.
final class SimulatorCell: TimelineCell {
    static let height: CGFloat = 300
    var onTap: (() -> Void)?
    private(set) var use: SimulatorUse?
    let screen = SimulatorScreen()
    private weak var feeds: SimulatorFeeds?
    /// False while its conversation is out of sight (covered or off screen).
    var showing = true {
        didSet {
            guard showing != oldValue else { return }
            attachFeed()
            playRecording()
        }
    }
    private let frameView = UIView()
    private let playerLayer = AVPlayerLayer()
    /// The recording's last screen, until (or instead of) the movie: it
    /// stays until the movie's first picture is ready, never a black frame.
    private let posterView = UIImageView()
    private var readiness: NSKeyValueObservation?
    /// Which recording's poster the view shows or is being decoded for.
    private var posterID: String?
    /// Posters decoded off the main thread at the size they show, by recording.
    private static let posters = NSCache<NSString, UIImage>()
    /// The recording's player, its looper and the file it plays, together.
    private struct Recorded { let url: URL; let player: AVQueuePlayer; let looper: AVPlayerLooper }
    /// What drives the picture: the shared live feed, or a recording.
    private enum Playback { case stopped, live(SimulatorTarget), recorded(Recorded) }
    private var playback = Playback.stopped
    private let dot = UIView()
    private let button = UIControl()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        frameView.layer.cornerRadius = 22 // a device screen's corner at this size
        frameView.layer.cornerCurve = .continuous
        frameView.clipsToBounds = true
        frameView.layer.borderWidth = 2.5
        frameView.backgroundColor = UIColor(white: 0.06, alpha: 1)
        frameView.isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        frameView.layer.addSublayer(playerLayer)
        readiness = playerLayer.observe(\.isReadyForDisplay) { [weak self] _, _ in
            Task { @MainActor in self?.showPoster() }
        }
        posterView.contentMode = .scaleAspectFit
        frameView.addSubview(posterView)
        frameView.addSubview(screen)
        dot.backgroundColor = Theme.failure
        dot.layer.cornerRadius = 4
        frameView.addSubview(dot)
        button.addSubview(frameView)
        button.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.onTap?() }, for: .touchUpInside)
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityIdentifier = "thread.simulator"
        contentView.addSubview(button)
        updateBorder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: SimulatorCell, _: UITraitCollection) in cell.updateBorder() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `tappable` false: a preview only, not a button (a host that can't
    /// bring a live simulator large).
    /// `poster`: the recording's poster file, decoded here off the main thread.
    func configure(_ use: SimulatorUse, feeds: SimulatorFeeds?, video: URL?, poster: Data? = nil, tappable: Bool) {
        self.use = use
        if self.feeds !== feeds { self.feeds?.attach(screen, to: nil) }
        self.feeds = feeds
        switch (use.content, video) {
        case (.live(let target), _):
            playback = .live(target)
        case (_, let video?) where !Motion.reduced:
            if case .recorded(let current) = playback, current.url == video { break }
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            playback = .recorded(Recorded(url: video, player: queue, looper: AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: video))))
        default:
            playback = .stopped
        }
        if case .recorded(let recorded) = playback { playerLayer.player = recorded.player } else { playerLayer.player?.pause(); playerLayer.player = nil }
        let live = if case .live = playback { true } else { false }
        let recorded = if case .recorded = playback { true } else { false }
        screen.isHidden = !live
        dot.isHidden = !live
        attachFeed()
        playRecording()
        button.isEnabled = tappable
        button.accessibilityTraits = tappable ? .button : .image
        button.accessibilityLabel = (live ? "Live simulator, " : "Simulator recording, ") + use.deviceName
        setPoster(poster, for: use.recordingID)
        showPoster()
        setNeedsLayout()
    }

    /// The poster, as soon as it is decoded; a row that moved on to another
    /// recording meanwhile keeps its own.
    private func setPoster(_ data: Data?, for recording: String?) {
        guard let recording, let data else { posterID = nil; posterView.image = nil; return }
        if let decoded = Self.posters.object(forKey: recording as NSString) { posterID = recording; posterView.image = decoded; return }
        guard posterID != recording || posterView.image == nil else { return }
        posterID = recording
        posterView.image = nil
        let height = Self.height * 3
        Task { [weak self] in
            guard let image = await Downsample.image(data, scale: { height / max(1, $0.height) }) else { return }
            Self.posters.setObject(image, forKey: recording as NSString)
            guard let self, posterID == recording else { return }
            posterView.image = image
        }
    }

    /// Live: the stream. Recorded: the poster until the movie has a picture.
    private func showPoster() {
        switch playback {
        case .live: posterView.isHidden = true
        case .recorded: posterView.isHidden = playerLayer.isReadyForDisplay
        case .stopped: posterView.isHidden = false
        }
    }

    /// Only a cell in a window holds a live stream: one scrolled away,
    /// waiting for reuse or in a hidden conversation lets it go.
    private func attachFeed() {
        guard case .live(let target) = playback, window != nil, showing else { feeds?.attach(screen, to: nil); return }
        feeds?.attach(screen, to: target)
    }

    /// A recording plays only while its cell can be seen.
    private func playRecording() {
        guard case .recorded(let recorded) = playback else { return }
        if window != nil, showing { recorded.player.play() } else { recorded.player.pause() }
    }

    /// Where the media viewer flies from and back to.
    var spot: MediaSpot { MediaSpot(button, style: frameView.layer) }
    /// The recording playing in place, for the viewer to carry on with.
    var recordingPlayer: AVPlayer? { if case .recorded(let recorded) = playback { recorded.player } else { nil } }
    var poster: UIImage? { posterView.image }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.alpha = 1
        if case .recorded(let recorded) = playback { recorded.player.pause() }
        feeds?.attach(screen, to: nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        playRecording()
        attachFeed()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = Self.height
        let width = (height / 2.17).rounded()
        button.frame = CGRect(x: Theme.Space.margin, y: gap.top, width: width, height: height)
        frameView.frame = button.bounds
        screen.frame = frameView.bounds
        posterView.frame = frameView.bounds
        dot.frame = CGRect(x: Theme.Space.rowPad, y: Theme.Space.rowPad, width: 8, height: 8)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = frameView.bounds
        CATransaction.commit()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: Self.height + gap.top + gap.bottom) }
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority h: UILayoutPriority,
                                          verticalFittingPriority v: UILayoutPriority) -> CGSize {
        sizeThatFits(targetSize)
    }

    private func updateBorder() { frameView.layer.borderColor = UIColor.label.resolvedColor(with: traitCollection).withAlphaComponent(0.85).cgColor }
}
