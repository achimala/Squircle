import AVFoundation
import AVKit
import UIKit

/// A simulator an agent is using now, or used in a turn and recorded.
struct SimulatorUse: Equatable {
    /// Squircle's session ID, or `t3:<thread>:<device>` for a device T3
    /// opened for a working thread without Squircle recording it.
    let id: String
    let threadID: String
    let target: SimulatorTarget
    let deviceName: String
    let started: Date
    var live: Bool
    /// The recording in the thread's media, once filed.
    var recordingID: String?
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
    private var active = true
    private var closed = false
    private var observers: [Task<Void, Never>] = []
    /// A feed's interactivity changed (input became ready or was lost).
    var onInteractive: (() -> Void)?

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
        closed = true
        observers.forEach { $0.cancel() }
        observers = []
        for feed in feeds.values { feed.linger?.cancel(); feed.stream.stop() }
        feeds = [:]
    }

    private func setActive(_ value: Bool) {
        active = value
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
        guard !closed, let target, let feed = feeds[target] ?? makeFeed(target) else { return }
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
        feed.stream.onInteractive = { [weak self] _ in self?.onInteractive?() }
        feeds[target] = feed
        if active { feed.stream.start() }
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
        Task { try? await stream.send(tag: 4, payload: .from(["button": "home"])) }
    }
}

/// Floating pictures of the simulators this app's agents are using right
/// now. One sits small in a corner the person drags it to; two or more
/// collapse there into a deck (the most recently started on top, the rest
/// peeking behind it, a count badge) that fans out into a labelled row when
/// tapped. Tapping a picture brings it large and touchable; it shrinks back
/// with a swipe down or a tap outside. Only pictures that can be seen decode.
/// Everything shown is derived from `uses`, the corner, and four springs.
@MainActor
final class SimulatorDock: UIView {
    enum Corner: String { case topLeft, topRight, bottomLeft, bottomRight }

    var onOpenThread: ((String) -> Void)?
    /// Uses whose own block in the conversation is on screen show there instead.
    var docked = Set<String>() { didSet { if docked != oldValue { animateLayout() } } }
    var bottomInset: CGFloat = 120 { didSet { if bottomInset != oldValue { setNeedsLayout() } } }
    private(set) var uses: [SimulatorUse] = []
    private var currentThread: String?
    private var titles: [String: String] = [:]
    private let feeds: SimulatorFeeds
    private var pips: [String: PiP] = [:]
    private var order: [String] = []

    private var corner: Corner
    /// The deck's top-left while it is dragged or settling into a corner.
    private let originX = SpringDriver()
    private let originY = SpringDriver()
    private var dragging = false
    private var dragStart = CGPoint.zero
    /// 0 = in the deck, 1 = fanned out in a row.
    private let fan = SpringDriver()
    private var wantFanned = false
    /// 0 = in the deck or row, 1 = large. `expanded` changes only at 0.
    private let expansion = SpringDriver()
    private var expanded: String?
    private var wantExpanded: String?
    private var collapseStart: CGFloat = 0

    private let backdrop = UIView()
    private let badge = Theme.label("", Theme.font(.caption2, 11, .bold), color: .white)
    private let home = Theme.glassButton(symbol: "house", identifier: "simulator.home", accessibilityLabel: "Simulator Home")
    private let open = Theme.glassButton(symbol: "bubble.left.and.text.bubble.right", identifier: "simulator.thread", accessibilityLabel: "Open thread")
    private let shrink = Theme.glassButton(symbol: "chevron.down", identifier: "simulator.shrink", accessibilityLabel: "Shrink simulator")

    init(feeds: SimulatorFeeds) {
        self.feeds = feeds
        corner = Corner(rawValue: UserDefaults.standard.string(forKey: "squircle.simulator.corner") ?? "") ?? .topRight
        super.init(frame: .zero)
        backdrop.backgroundColor = UIColor.black
        backdrop.alpha = 0
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backdropTapped)))
        backdrop.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(collapsePanned(_:))))
        addSubview(backdrop)
        badge.backgroundColor = Theme.accent
        badge.textAlignment = .center
        badge.layer.cornerRadius = 9
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true
        badge.isUserInteractionEnabled = false
        badge.alpha = 0
        addSubview(badge)
        for button in [home, open, shrink] { addSubview(button) }
        home.addAction(UIAction { [weak self] _ in
            guard let self, let use = uses.first(where: { $0.id == self.expanded }) else { return }
            Theme.selectionHaptic()
            feeds.home(use.target)
        }, for: .touchUpInside)
        open.addAction(UIAction { [weak self] _ in
            guard let self, let use = uses.first(where: { $0.id == self.expanded }) else { return }
            Theme.selectionHaptic()
            collapse()
            onOpenThread?(use.threadID)
        }, for: .touchUpInside)
        shrink.addAction(UIAction { [weak self] _ in self?.collapse() }, for: .touchUpInside)
        expansion.parameters = SpringDriver.Parameters(response: 0.42, damping: 0.86)
        fan.parameters = SpringDriver.Parameters(response: 0.4, damping: 0.8)
        originX.parameters = SpringDriver.Parameters(response: 0.38, damping: 0.8)
        originY.parameters = originX.parameters
        for driver in [expansion, fan, originX, originY] {
            driver.onChange = { [weak self] _ in self?.layoutDock() }
            driver.onRest = { [weak self] _ in self?.sync() }
        }
        feeds.onInteractive = { [weak self] in self?.layoutDock() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SQUIRCLE_SIM_FAN"] == "1" { Task { [weak self] in await self?.demoFan() } }
        #endif
    }

    #if DEBUG
    /// `SQUIRCLE_SIM_FAN=1`: fans the deck out, opens the second picture,
    /// shrinks it, fans again and gathers, through the same paths as taps.
    private func demoFan() async {
        let steps: [(Double, (SimulatorDock) -> Void)] = [
            (8, { dock in dock.deck.first.map { dock.tapped($0.id) } }),
            (3, { dock in dock.deck.dropFirst().first.map { dock.tapped($0.id) } }),
            (3, { $0.collapse() }),
            (2, { dock in dock.deck.first.map { dock.tapped($0.id) } }),
            (2, { $0.backdropTapped() }),
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
            pip.onTouch = { [weak self, weak pip] phase, point in
                guard let self, let pip, expanded == pip.use.id, expansion.target == 1 else { return false }
                return feeds.touch(phase, at: point, on: pip.screen)
            }
            insertSubview(pip, belowSubview: badge)
            pips[use.id] = pip
            pip.alpha = 0
            pip.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }
        order = ids
        if let wanted = wantExpanded, !ids.contains(wanted) { wantExpanded = nil }
        sync()
        animateLayout()
    }

    // MARK: State

    /// Brings a simulator large (from its PiP or its block in the conversation).
    func expand(_ id: String) {
        guard expansion.target == 0 || expanded == id else { return }
        Theme.openHaptic()
        wantExpanded = id
        wantFanned = false
        sync()
    }

    /// A tap on a picture: the deck fans out; a single picture or one in the
    /// row comes large.
    private func tapped(_ id: String) {
        if deck.count > 1, fan.target == 0 {
            Theme.openHaptic()
            wantFanned = true
            sync()
        } else {
            expand(id)
        }
    }

    @objc private func collapse() {
        guard wantExpanded != nil else { return }
        Theme.selectionHaptic()
        wantExpanded = nil
        sync()
    }

    private func gather() {
        guard wantFanned else { return }
        Theme.selectionHaptic()
        wantFanned = false
        sync()
    }

    @objc private func backdropTapped() {
        if wantExpanded != nil { collapse() } else { gather() }
    }

    /// What is expanded changes only while nothing is; the springs head to
    /// whatever `wantExpanded` and `wantFanned` imply. Pictures that can't be
    /// seen (behind the deck's top, or docked in the conversation) stop
    /// decoding and keep their last frame.
    private func sync() {
        if expansion.value <= 0.001, !expansion.isAnimating, expanded != wantExpanded {
            expanded = wantExpanded
            restack()
        }
        let deck = self.deck
        if deck.count < 2 { wantFanned = false }
        let target: CGFloat = expanded != nil && expanded == wantExpanded ? 1 : 0
        if expansion.target != target || (!expansion.isAnimating && expansion.value != target) {
            expansion.redirect(to: target)
        }
        let fanTarget: CGFloat = wantFanned ? 1 : 0
        if fan.target != fanTarget || (!fan.isAnimating && fan.value != fanTarget) {
            fan.redirect(to: fanTarget)
        }
        if !dragging, !originX.isAnimating, !originY.isAnimating {
            let rest = cornerOrigin(corner)
            originX.set(rest.x)
            originY.set(rest.y)
        }
        let spread = fan.target == 1 || fan.value > 0.001
        for use in uses {
            guard let pip = pips[use.id] else { continue }
            let index = deck.firstIndex(of: use)
            let seen = use.id == expanded || use.id == wantExpanded || index == 0 || (index != nil && spread)
            feeds.attach(pip.screen, to: seen ? use.target : nil)
        }
        layoutDock()
    }

    /// The deck's top picture above the rest, the large one above all.
    private func restack() {
        for use in deck.reversed() { if let pip = pips[use.id] { insertSubview(pip, belowSubview: badge) } }
        if let id = expanded, let pip = pips[id] { insertSubview(pip, belowSubview: badge) }
    }

    // MARK: Geometry

    private static let deckWidth: CGFloat = 80
    private static let peek: CGFloat = 6
    private static let gap: CGFloat = 10
    private static let captionHeight: CGFloat = 16

    private var shown: [SimulatorUse] { uses.filter { !docked.contains($0.id) || $0.id == expanded } }
    /// Most recently started first: the deck's top picture and the row's corner end.
    private var deck: [SimulatorUse] { shown.reversed() }

    private func showsCaption(_ use: SimulatorUse) -> Bool { use.threadID != currentThread }

    private func aspect(_ use: SimulatorUse?) -> CGFloat { use.flatMap { pips[$0.id]?.screen.aspect } ?? 2.17 }

    private var deckSize: CGSize {
        let deck = self.deck
        let height = (Self.deckWidth * aspect(deck.first)).rounded()
        let caption = deck.count == 1 && showsCaption(deck[0]) ? Self.captionHeight + 4 : 0
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
                      y: top ? area.minY : max(area.minY, area.maxY - height - Self.captionHeight - 4),
                      width: width, height: height)
    }

    private var area: CGRect {
        CGRect(x: 12, y: safeAreaInsets.top + 56, width: bounds.width - 24,
               height: max(0, bounds.height - bottomInset - safeAreaInsets.top - 56))
    }

    private func cornerOrigin(_ corner: Corner) -> CGPoint {
        let area = self.area, size = deckSize
        let x = corner == .topLeft || corner == .bottomLeft ? area.minX : area.maxX - size.width
        let y = corner == .topLeft || corner == .topRight ? area.minY : max(area.minY, area.maxY - size.height)
        return CGPoint(x: x, y: y)
    }

    private var bigFrame: CGRect {
        let top = safeAreaInsets.top + 12
        let available = CGRect(x: 16, y: top, width: bounds.width - 32, height: bounds.height - top - safeAreaInsets.bottom - 84)
        let aspect = expanded.flatMap { pips[$0]?.screen.aspect } ?? 2.17
        let height = min(available.height, available.width * aspect)
        let width = height / aspect
        return CGRect(x: available.midX - width / 2, y: available.minY, width: width, height: height)
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

    /// Every PiP's frame, the badge, backdrop and controls, from the state alone.
    private func layoutDock() {
        guard bounds.width > 0 else { return }
        let e = expansion.value.clamped(), f = fan.value.clamped()
        let deck = self.deck
        let fanned = fan.target == 1
        for use in uses {
            guard let pip = pips[use.id] else { continue }
            let index = deck.firstIndex(of: use)
            let isExpanded = use.id == expanded
            var frame: CGRect
            var alpha: CGFloat
            if let index {
                frame = deckFrame(index, top: deck.first).lerp(to: fanFrame(index, of: deck.count, use: use), f)
                alpha = index <= 2 ? 1 : f
                pip.shade.alpha = 0.18 * CGFloat(min(index, 2)) * (1 - f)
            } else {
                frame = deckFrame(0, top: deck.first)
                alpha = 0
                pip.shade.alpha = 0
            }
            if isExpanded { frame = frame.lerp(to: bigFrame, e) }
            alpha = isExpanded ? 1 : alpha * (1 - e)
            pip.transform = .identity
            pip.frame = frame
            pip.cornerRadius = .lerp(12, 30, isExpanded ? e : 0)
            pip.caption.text = titles[use.threadID] ?? "Thread"
            let caption: CGFloat = deck.count > 1 ? f : (showsCaption(use) ? 1 : 0)
            pip.caption.alpha = isExpanded && e > 0.05 ? 0 : caption
            pip.alpha = alpha
            let reachable = index == 0 || (index != nil && fanned)
            pip.isUserInteractionEnabled = isExpanded || (reachable && e < 0.01 && expansion.target == 0)
            pip.interactive = isExpanded && e > 0.99
            pip.accessibilityLabel = deck.count > 1 && !fanned && index == 0
                ? "\(deck.count) simulators"
                : (titles[use.threadID] ?? "Agent") + " simulator, " + use.deviceName
        }
        let top = deckFrame(0, top: deck.first)
        badge.text = "\(deck.count)"
        let badgeWidth = max(18, badge.intrinsicContentSize.width + 10)
        badge.frame = CGRect(x: top.maxX - badgeWidth / 2 - 4, y: top.minY - 5,
                             width: badgeWidth, height: 18)
        badge.alpha = deck.count > 1 ? (1 - f) * (1 - e) : 0
        backdrop.alpha = max(0.42 * e, 0.2 * f)
        backdrop.isUserInteractionEnabled = expansion.target == 1 || fanned
        let big = bigFrame
        let buttonY = big.maxY + 16
        let showsOpen = expanded.flatMap { id in uses.first { $0.id == id } }.map { $0.threadID != currentThread } ?? false
        let buttons = [home] + (showsOpen ? [open] : []) + [shrink]
        let total = CGFloat(buttons.count) * 48 + CGFloat(buttons.count - 1) * 16
        for (index, button) in [home, open, shrink].enumerated() {
            let slot = buttons.firstIndex(of: button)
            button.isHidden = slot == nil
            let left = bounds.midX - total / 2 + CGFloat(slot ?? index) * 64
            button.transform = .identity
            button.frame = CGRect(x: left, y: buttonY, width: 48, height: 48)
            button.alpha = e
            button.transform = CGAffineTransform(translationX: 0, y: (1 - e) * 24)
            button.isUserInteractionEnabled = expansion.target == 1
        }
        if let id = expanded, let use = uses.first(where: { $0.id == id }) { home.isEnabled = feeds.isInteractive(use.target) }
        accessibilityElements = expansion.target == 1
            ? [expanded.flatMap { pips[$0] }, home, showsOpen ? open : nil, shrink].compactMap { $0 }
            : deck.prefix(fanned ? deck.count : 1).compactMap { pips[$0.id] }
    }

    // MARK: Gestures

    /// In the deck: the whole deck follows the finger, then springs to the
    /// corner it was thrown toward. Fanned out: a drag gathers the row.
    private func panned(_ gesture: UIPanGestureRecognizer) {
        guard expansion.target == 0 else { return }
        if fan.target == 1 {
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

    /// Expanded: dragging down outside the picture shrinks it with the finger.
    /// Fanned out: any drag outside gathers the row.
    @objc private func collapsePanned(_ gesture: UIPanGestureRecognizer) {
        guard expanded != nil else {
            if gesture.state == .began { gather() }
            return
        }
        let span = max(1, bounds.height * 0.5)
        switch gesture.state {
        case .began:
            expansion.stop()
            collapseStart = expansion.value
        case .changed:
            expansion.set((collapseStart - gesture.translation(in: self).y / span).clamped())
        case .ended, .cancelled, .failed:
            let velocity = -gesture.velocity(in: self).y / span
            let closing = expansion.value + velocity * 0.2 < 0.6
            if closing { wantExpanded = nil; Theme.selectionHaptic() }
            expansion.animate(to: closing ? 0 : 1, initialVelocity: velocity)
        default: break
        }
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
    let caption = Theme.label("", Theme.font(.caption2, 11, .semibold), color: .secondaryLabel)
    /// Darkens a picture lying behind the deck's top one.
    let shade = UIView()
    private let frameView = UIView()
    private let dot = UIView()
    var onTap: (() -> Void)?
    var onPan: ((UIPanGestureRecognizer) -> Void)?
    var onTouch: ((_ phase: String, _ point: CGPoint) -> Bool)?
    /// Large: raw touches go to the simulator instead of moving the PiP.
    var interactive = false {
        didSet { tap.isEnabled = !interactive; pan.isEnabled = !interactive }
    }
    var cornerRadius: CGFloat = 12 {
        didSet { frameView.layer.cornerRadius = cornerRadius; screen.layer.cornerRadius = cornerRadius; shade.layer.cornerRadius = cornerRadius }
    }
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private var tracking = false

    init(use: SimulatorUse) {
        self.use = use
        super.init(frame: .zero)
        frameView.layer.cornerCurve = .continuous
        frameView.layer.shadowColor = UIColor.black.cgColor
        frameView.layer.shadowOpacity = 0.22
        frameView.layer.shadowRadius = 14
        frameView.layer.shadowOffset = CGSize(width: 0, height: 6)
        frameView.isUserInteractionEnabled = false
        screen.layer.cornerCurve = .continuous
        screen.clipsToBounds = true
        shade.backgroundColor = .black
        shade.alpha = 0
        shade.layer.cornerCurve = .continuous
        shade.isUserInteractionEnabled = false
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 3.5
        dot.isUserInteractionEnabled = false
        caption.textAlignment = .center
        caption.lineBreakMode = .byTruncatingTail
        [frameView, screen, shade, dot, caption].forEach(addSubview)
        addGestureRecognizer(tap)
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityTraits = [.button, .allowsDirectInteraction]
        accessibilityIdentifier = "simulator.pip"
        isMultipleTouchEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let picture = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: bounds.height))
        frameView.frame = picture
        frameView.layer.shadowPath = UIBezierPath(roundedRect: picture, cornerRadius: cornerRadius).cgPath
        screen.frame = picture
        shade.frame = picture
        dot.frame = CGRect(x: 8, y: 8, width: 7, height: 7)
        caption.frame = CGRect(x: 0, y: picture.maxY + 4, width: bounds.width, height: 16)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -4, dy: -4).contains(point)
    }

    @objc private func tapped() { onTap?() }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) { onPan?(gesture) }

    private func forward(_ touches: Set<UITouch>, _ phase: String) {
        guard interactive, let touch = touches.first else { return }
        let point = touch.location(in: screen)
        if phase == "begin" { tracking = onTouch?(phase, point) ?? false }
        else if tracking { _ = onTouch?(phase, point) }
        if phase == "end" { tracking = false }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "begin"); super.touchesBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "move"); super.touchesMoved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "end"); super.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "end"); super.touchesCancelled(touches, with: event) }
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
            if showing, window != nil { player?.play() } else { player?.pause() }
        }
    }
    private let frameView = UIView()
    private let playerLayer = AVPlayerLayer()
    /// The recording's last screen, until (or instead of) the movie.
    private let posterView = UIImageView()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playing: URL?
    private let dot = UIView()
    private let button = UIControl()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        frameView.layer.cornerRadius = 22
        frameView.layer.cornerCurve = .continuous
        frameView.clipsToBounds = true
        frameView.layer.borderWidth = 2.5
        frameView.backgroundColor = UIColor(white: 0.06, alpha: 1)
        frameView.isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        frameView.layer.addSublayer(playerLayer)
        posterView.contentMode = .scaleAspectFit
        frameView.addSubview(posterView)
        frameView.addSubview(screen)
        dot.backgroundColor = .systemRed
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
    func configure(_ use: SimulatorUse, feeds: SimulatorFeeds?, video: URL?, poster: UIImage? = nil, tappable: Bool) {
        self.use = use
        if self.feeds !== feeds { self.feeds?.attach(screen, to: nil) }
        self.feeds = feeds
        screen.isHidden = !use.live
        dot.isHidden = !use.live
        attachFeed()
        button.isEnabled = tappable
        button.accessibilityTraits = tappable ? .button : .image
        button.accessibilityLabel = (use.live ? "Live simulator, " : "Simulator recording, ") + use.deviceName
        if use.live || video == nil {
            player?.pause(); player = nil; looper = nil; playerLayer.player = nil; playing = nil
        } else if let video, playing != video, !Motion.reduced {
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: video))
            playerLayer.player = queue
            player = queue
            playing = video
            if window != nil, showing { queue.play() }
        }
        posterView.image = poster
        posterView.isHidden = use.live || player != nil
        setNeedsLayout()
    }

    /// Only a cell in a window holds a live stream: one scrolled away,
    /// waiting for reuse or in a hidden conversation lets it go.
    private func attachFeed() {
        feeds?.attach(screen, to: window != nil && showing && use?.live == true ? use?.target : nil)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        player?.pause()
        feeds?.attach(screen, to: nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil || !showing { player?.pause() } else { player?.play() }
        attachFeed()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = Self.height
        let width = (height / 2.17).rounded()
        button.frame = CGRect(x: 20, y: 6, width: width, height: height)
        frameView.frame = button.bounds
        screen.frame = frameView.bounds
        posterView.frame = frameView.bounds
        dot.frame = CGRect(x: 12, y: 12, width: 8, height: 8)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = frameView.bounds
        CATransaction.commit()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: Self.height + 16) }
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority h: UILayoutPriority,
                                          verticalFittingPriority v: UILayoutPriority) -> CGSize {
        CGSize(width: targetSize.width, height: Self.height + 16)
    }

    private func updateBorder() { frameView.layer.borderColor = UIColor.label.resolvedColor(with: traitCollection).withAlphaComponent(0.85).cgColor }
}

private extension CGRect {
    func lerp(to other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: .lerp(minX, other.minX, t), y: .lerp(minY, other.minY, t),
               width: .lerp(width, other.width, t), height: .lerp(height, other.height, t))
    }
}
