import AVFoundation
import UIKit

/// Where a medium shows inline: the view whose bounds it fills, and the
/// layer that carries its corners and border.
struct MediaSpot {
    let view: UIView
    let style: CALayer
    init(_ view: UIView, style: CALayer? = nil) {
        self.view = view
        self.style = style ?? view.layer
    }
}

/// Finds a medium's inline spot whenever asked: cells are reused and lists
/// scroll, so the viewer never holds on to one view.
struct MediaOrigin {
    var locate: @MainActor () -> MediaSpot?
    /// Also told when the viewer starts (true) and stops standing in for
    /// the inline picture, for an owner that draws it itself. The located
    /// view is hidden either way.
    var conceal: (@MainActor (Bool) -> Void)?
    init(locate: @escaping @MainActor () -> MediaSpot?, conceal: (@MainActor (Bool) -> Void)? = nil) {
        self.locate = locate
        self.conceal = conceal
    }
}

/// What the viewer shows.
enum ViewerMedia {
    /// The inline picture, and a sharper decode at up to a pixel size.
    case image(UIImage, full: (@MainActor (CGFloat) async -> UIImage?)?)
    /// A clip: its poster, its size when known, the inline player to carry
    /// on with (nil: a new one from `url`).
    case video(poster: UIImage?, size: CGSize?, player: AVPlayer?, url: @MainActor () async -> URL?)
    /// A live simulator, touchable while large.
    case simulator(SimulatorUse, feeds: SimulatorFeeds, openThread: (() -> Void)?)
}

/// Every picture, clip and simulator brought large: it flies up from its
/// inline frame over a darkening backdrop, follows the finger 1:1 when
/// dragged (shrinking a little, the backdrop fading with distance), and a
/// flick or a long enough drag throws it back into wherever its inline frame
/// is now, keeping the finger's velocity. Pictures pinch and double-tap zoom.
///
/// The picture's frame is one spring (centre and size, with velocity). The
/// route (open or closed) and the zoom pick its target every frame; a finger
/// holds it, and letting go hands it back with the finger's velocity. Every
/// other thing drawn (backdrop, corners, controls, who takes touches) is
/// derived from that frame and the route, so a tap or drag at any moment
/// takes over from wherever it is.
///
/// A live simulator takes taps on its picture; it is dismissed by dragging
/// from the grabber under it or anywhere outside it, a tap outside it, or
/// the shrink button.
@MainActor
final class MediaViewer: UIView, UIGestureRecognizerDelegate {
    enum Route { case open, closed }
    private(set) var route = Route.open
    let media: ViewerMedia
    private let origin: MediaOrigin
    var onClosed: (() -> Void)?

    /// Opens `media` from its inline spot over everything in `window`.
    @discardableResult
    static func open(_ media: ViewerMedia, from origin: MediaOrigin, in window: UIWindow) -> MediaViewer {
        let viewer = MediaViewer(media: media, origin: origin)
        viewer.frame = window.bounds
        viewer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(viewer)
        viewer.start()
        return viewer
    }

    // MARK: State

    /// A finger holding the picture, and how it took hold.
    private enum Hold {
        case none
        /// Dragging to dismiss: where the finger touched the picture (0…1),
        /// the size it had then, and its shrink at that distance.
        case drag(anchor: CGPoint, size: CGSize, shrink: CGFloat, center: CGPoint)
        /// Panning a zoomed picture from this origin.
        case pan(origin: CGPoint)
        /// Pinching from this frame, around this point of it (0…1).
        case pinch(frame: CGRect, anchor: CGPoint)
    }
    private var hold = Hold.none
    private var held: Bool { if case .none = hold { false } else { true } }
    /// Where a zoomed picture rests; nil: fitted to the screen.
    private var zoom: CGRect?
    /// Where it heads when its inline spot can't be seen: on off the
    /// screen in the direction it was thrown. Set once, when it is needed.
    private var away: CGRect?
    private var spring = RectSpring()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    /// Controls shown (1) or tapped away (0).
    private let chrome = SpringDriver(value: 1)
    /// The inline view hidden while the viewer stands in for it.
    private weak var concealed: UIView?
    /// Its corner radius and border the last time it was seen.
    private var spotStyle = (radius: CGFloat(0), border: CGFloat(0), color: UIColor.clear.cgColor)
    private var lastSpot: CGRect?
    private var finished = false

    // MARK: Views

    private let backdrop = UIView()
    /// Frame driven by the spring; draws nothing itself.
    private let picture = UIView()
    /// The picture, or a clip's poster: contents only, so its rounded
    /// corners cost nothing extra to draw.
    private let content = CALayer()
    private var playerLayer: AVPlayerLayer?
    private var screen: SimulatorScreen?
    private var input: SimulatorInput?
    private var aspect: CGFloat
    private let close = Theme.glassButton(symbol: "xmark", identifier: "viewer.close", accessibilityLabel: "Close")
    private var video: VideoControls?
    private var sim: SimulatorChrome?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))

    private var zooms: Bool { if case .image = media { true } else { false } }
    private var isSimulator: Bool { if case .simulator = media { true } else { false } }

    private init(media: ViewerMedia, origin: MediaOrigin) {
        self.media = media
        self.origin = origin
        switch media {
        case .image(let image, _): aspect = image.size.height / max(1, image.size.width)
        case .video(let poster, let size, _, _):
            let size = size ?? poster?.size ?? CGSize(width: 16, height: 9)
            aspect = size.height / max(1, size.width)
        case .simulator: aspect = 2.17
        }
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .dark
        backdrop.backgroundColor = .black
        backdrop.isUserInteractionEnabled = false
        addSubview(backdrop)
        picture.isUserInteractionEnabled = false
        picture.accessibilityIgnoresInvertColors = true
        content.contentsGravity = .resizeAspectFill
        content.masksToBounds = true
        content.cornerCurve = .continuous
        picture.layer.addSublayer(content)
        addSubview(picture)
        switch media {
        case .image(let image, _):
            content.contents = image.cgImage
            picture.isAccessibilityElement = true
            picture.accessibilityLabel = "Picture"
            picture.accessibilityTraits = .image
        case .video(let poster, _, let player, _):
            content.contents = poster?.cgImage
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspectFill
            layer.masksToBounds = true
            layer.cornerCurve = .continuous
            picture.layer.addSublayer(layer)
            playerLayer = layer
            let controls = VideoControls()
            controls.onPresentationSize = { [weak self] size in
                guard let self, size.width > 0 else { return }
                aspect = size.height / size.width
                retarget()
            }
            addSubview(controls)
            video = controls
            if let player { use(player, shared: true) }
        case .simulator(let use, let feeds, let openThread):
            let screen = SimulatorScreen()
            screen.layer.masksToBounds = true
            screen.layer.cornerCurve = .continuous
            screen.onPictureSize = { [weak self, weak screen] in
                guard let self, let screen else { return }
                aspect = screen.aspect
                retarget()
            }
            picture.addSubview(screen)
            self.screen = screen
            feeds.attach(screen, to: use.target)
            aspect = screen.aspect
            let input = SimulatorInput()
            input.onTouch = { [weak feeds, weak screen] phase, point in
                guard let feeds, let screen else { return false }
                return feeds.touch(phase, at: point, on: screen)
            }
            input.screen = screen
            picture.addSubview(input)
            self.input = input
            let chrome = SimulatorChrome(showsThread: openThread != nil)
            chrome.home.addAction(UIAction { [weak feeds] _ in
                guard let target = use.target else { return }
                Theme.selectionHaptic()
                feeds?.home(target)
            }, for: .touchUpInside)
            chrome.thread.addAction(UIAction { [weak self] _ in
                Theme.selectionHaptic()
                self?.dismiss()
                openThread?()
            }, for: .touchUpInside)
            chrome.shrink.addAction(UIAction { [weak self] _ in self?.dismiss() }, for: .touchUpInside)
            addSubview(chrome)
            sim = chrome
            let refresh: () -> Void = { [weak self, weak feeds] in
                guard let self, let feeds, let target = use.target else { return }
                sim?.home.isEnabled = feeds.isInteractive(target)
            }
            interactiveObserver = feeds.observeInteractive(refresh)
            refresh()
        }
        if !isSimulator { addSubview(close) }
        close.addAction(UIAction { [weak self] _ in self?.dismiss() }, for: .touchUpInside)
        pan.maximumNumberOfTouches = 1
        doubleTap.numberOfTapsRequired = 2
        if zooms { tap.require(toFail: doubleTap) }
        for gesture in [pan, pinch, doubleTap, tap] as [UIGestureRecognizer] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        chrome.parameters = SpringDriver.Parameters(response: 0.3, damping: 1)
        chrome.onChange = { [weak self] _ in self?.apply() }
        accessibilityViewIsModal = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var interactiveObserver: SimulatorFeeds.Observer?

    private func start() {
        layoutIfNeeded()
        Theme.openHaptic()
        // From exactly where it shows, including a press still springing back.
        let spot = locate()
        if let spot, let rect = lastSpot {
            let scale = spot.view.layer.presentation()?.affineTransform().a ?? 1
            spring.set(CGRect(x: rect.midX - rect.width * scale / 2, y: rect.midY - rect.height * scale / 2,
                              width: rect.width * scale, height: rect.height * scale))
        } else {
            let fit = fitFrame
            spring.set(CGRect(x: fit.midX - fit.width * 0.4, y: fit.midY - fit.height * 0.4, width: fit.width * 0.8, height: fit.height * 0.8))
        }
        origin.conceal?(true)
        apply(spot)
        run()
        loadSharper()
        loadVideo()
        UIAccessibility.post(notification: .screenChanged, argument: picture.isAccessibilityElement ? picture : nil)
    }

    /// Sends it back to its inline spot.
    func dismiss(velocity: CGPoint? = nil) {
        guard route == .open else { return }
        if !held { Theme.selectionHaptic() }
        route = .closed
        zoom = nil
        if let velocity { spring.velocity = [velocity.x, velocity.y, 0, 0] }
        video?.closing()
        input?.interactive = false
        run()
        apply()
    }

    /// Back open from wherever it is, dropping momentum that heads away.
    private func reopen() {
        guard route == .closed else { return }
        Theme.openHaptic()
        route = .open
        away = nil
        let goal = target(locate())
        let toward = CGPoint(x: goal.midX - spring.value.midX, y: goal.midY - spring.value.midY)
        if toward.x * spring.velocity[0] + toward.y * spring.velocity[1] < 0 { spring.velocity = [0, 0, 0, 0] }
        video?.reopened()
        run()
    }

    // MARK: Geometry

    /// Fitted to the screen at its own proportions; a simulator leaves room
    /// for its grabber and buttons.
    private var fitFrame: CGRect {
        var area = bounds
        if isSimulator {
            let top = safeAreaInsets.top + 12
            area = CGRect(x: 16, y: top, width: bounds.width - 32, height: bounds.height - top - safeAreaInsets.bottom - 96)
        }
        let height = min(area.height, area.width * aspect)
        let width = height / max(0.01, aspect)
        return CGRect(x: area.midX - width / 2, y: isSimulator ? area.minY : area.midY - height / 2, width: width, height: height)
    }

    private static let maxZoom: CGFloat = 4

    /// Its inline spot, if that can be seen, recording its frame and style.
    private func locate() -> MediaSpot? {
        guard let spot = origin.locate(), spot.view.window === window else { lastSpot = nil; return nil }
        let rect = spot.view.convert(spot.view.bounds, to: self)
        guard rect.intersects(bounds), rect.width > 1 else { lastSpot = nil; return nil }
        lastSpot = rect
        spotStyle = (spot.style.cornerRadius, spot.style.borderWidth, spot.style.borderColor ?? UIColor.clear.cgColor)
        return spot
    }

    /// Where the spring heads now: the inline spot (or away) when closed,
    /// the zoom or the fitted frame when open.
    private func target(_ spot: MediaSpot?) -> CGRect {
        if route == .open { return zoom ?? fitFrame }
        if spot != nil, let rect = lastSpot { return rect }
        if let away { return away }
        var v = CGPoint(x: spring.velocity[0], y: spring.velocity[1])
        if hypot(v.x, v.y) < 300 { v = CGPoint(x: 0, y: 1) }
        let length = hypot(v.x, v.y)
        let distance = bounds.height + spring.value.height
        let rect = spring.value.offsetBy(dx: v.x / length * distance, dy: v.y / length * distance)
        away = rect
        return rect
    }

    /// 1 fitted (or zoomed), 0 at its inline spot; lower as it is dragged away.
    private func openness(_ frame: CGRect) -> CGFloat {
        let fit = fitFrame
        if frame.width >= fit.width - 0.5 { return 1 }
        let size: CGFloat
        if let spot = lastSpot, abs(fit.width - spot.width) > 1 {
            size = ((frame.width - spot.width) / (fit.width - spot.width)).clamped()
        } else {
            size = 1
        }
        let distance = hypot(frame.midX - fit.midX, frame.midY - fit.midY)
        return size * (1 - (distance / max(1, bounds.height * 0.55)).clamped())
    }

    /// A zoomed frame nudged so the picture covers the screen, or sits
    /// centred along a side it doesn't fill.
    private func contained(_ frame: CGRect) -> CGRect {
        var frame = frame
        let fit = fitFrame
        if frame.width > fit.width * Self.maxZoom {
            let scale = fit.width * Self.maxZoom / frame.width
            frame = CGRect(x: frame.midX - frame.width * scale / 2, y: frame.midY - frame.height * scale / 2,
                           width: frame.width * scale, height: frame.height * scale)
        }
        frame.origin.x = frame.width <= bounds.width ? bounds.midX - frame.width / 2 : min(0, max(bounds.width - frame.width, frame.minX))
        frame.origin.y = frame.height <= bounds.height ? bounds.midY - frame.height / 2 : min(0, max(bounds.height - frame.height, frame.minY))
        return frame
    }

    /// Past an edge, a zoomed picture follows the finger less and less.
    private func rubberBanded(_ frame: CGRect) -> CGRect {
        let rest = contained(frame)
        func band(_ offset: CGFloat, _ dimension: CGFloat) -> CGFloat {
            let sign: CGFloat = offset < 0 ? -1 : 1
            return sign * (1 - 1 / (abs(offset) * 0.55 / dimension + 1)) * dimension
        }
        return CGRect(x: rest.minX + band(frame.minX - rest.minX, bounds.width),
                      y: rest.minY + band(frame.minY - rest.minY, bounds.height), width: frame.width, height: frame.height)
    }

    // MARK: Frames

    private func run() {
        guard link == nil, !held else { return }
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] link in self?.tick(link) }, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = nil
        #if DEBUG
        flight = []
        #endif
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        #if DEBUG
        reportFlight()
        #endif
    }

    /// The target changed shape (a picture's size arrived, the screen turned).
    private func retarget() {
        if held { return }
        if link == nil, route == .open, zoom == nil { run() } else { apply() }
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var dt = min(1.0 / 30.0, max(0, now - (lastTimestamp ?? (now - link.duration))))
        #if DEBUG
        dt /= SpringDriver.debugSlowMotion
        flight.append((link.timestamp, link.duration))
        let started = CACurrentMediaTime()
        defer { MotionAudit.shared.work((CACurrentMediaTime() - started) * 1000) }
        #endif
        lastTimestamp = now
        let spot = locate()
        let goal = target(spot)
        spring.parameters = Motion.reduced ? .init(response: 0.3, damping: 1)
            : zoom != nil && route == .open ? .init(response: 0.42, damping: 1) : .init(response: 0.42, damping: 0.86)
        let resting = spring.step(toward: goal, dt: CGFloat(dt))
        if route == .closed, spot == nil, !spring.value.intersects(bounds) { finish(); return }
        if resting {
            spring.set(goal)
            stopLink()
            if route == .closed { finish(); return }
            showSharper()
            loadSharper()
        }
        apply(spot)
    }

    private func apply() { apply(locate()) }

    /// Everything drawn, from the spring's frame and the route.
    private func apply(_ spot: MediaSpot?) {
        guard !finished, bounds.width > 0 else { return }
        if concealed !== spot?.view {
            concealed?.alpha = 1
            spot?.view.alpha = 0
            concealed = spot?.view
        }
        let frame = spring.value
        let open = openness(frame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = frame
        let local = picture.bounds
        let radius = CGFloat.lerp(spotStyle.radius, isSimulator ? 30 : 0, open)
        for layer in [content, playerLayer, screen?.layer].compactMap({ $0 }) {
            layer.frame = local
            layer.cornerRadius = radius
        }
        content.borderWidth = .lerp(spotStyle.border, 0, open)
        content.borderColor = spotStyle.color
        input?.frame = local
        CATransaction.commit()
        backdrop.frame = bounds
        backdrop.alpha = open
        let shown = route == .open ? open * open * chrome.value : 0
        close.frame = CGRect(x: bounds.width - safeAreaInsets.right - 64, y: safeAreaInsets.top + 6, width: 48, height: 48)
        close.alpha = shown
        close.isUserInteractionEnabled = route == .open && chrome.target > 0.5
        if let video {
            let width = min(bounds.width - 32, 520)
            video.frame = CGRect(x: bounds.midX - width / 2, y: bounds.height - safeAreaInsets.bottom - 64, width: width, height: 52)
            video.alpha = shown
            video.isUserInteractionEnabled = close.isUserInteractionEnabled
        }
        if let sim {
            let fit = fitFrame
            sim.place(grabberAt: CGPoint(x: frame.midX, y: frame.maxY + 14), buttonsAt: fit.maxY + 34, width: bounds.width)
            sim.alpha = route == .open ? open * open : 0
            sim.isUserInteractionEnabled = route == .open
        }
        // A live simulator takes its touches from the first frame it is sent large.
        input?.interactive = route == .open && !held
        picture.isUserInteractionEnabled = input?.interactive == true
    }

    private func finish() {
        guard !finished else { return }
        stopLink()
        finished = true
        concealed?.alpha = 1
        concealed = nil
        origin.conceal?(false)
        video?.finished()
        if case .simulator(_, let feeds, _) = media, let screen { feeds.attach(screen, to: nil) }
        removeFromSuperview()
        onClosed?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !held, link == nil, route == .open { spring.set(zoom.map(contained) ?? fitFrame) }
        apply()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    // MARK: Pictures and clips

    /// A screen-sharp decode as soon as it flies, a zoomable one once it rests.
    private var sharpness: CGFloat = 0
    private var sharpening: Task<Void, Never>?
    private func loadSharper() {
        guard case .image(_, let full?) = media, sharpening == nil, route == .open else { return }
        let screenPixels = max(bounds.width, bounds.height) * (window?.screen.scale ?? 3)
        let wanted = sharpness == 0 ? screenPixels : min(4096, screenPixels * 2.5)
        guard wanted > sharpness, sharpness == 0 || (link == nil && !held) else { return }
        sharpening = Task { [weak self] in
            let image = await full(wanted)
            guard let self, !finished else { return }
            sharpening = nil
            sharpness = wanted
            sharper = image
            showSharper()
            if link == nil, !held { loadSharper() }
        }
    }

    /// A sharper decode waiting to be shown: swapped in only while the
    /// picture rests, so its upload never lands on a moving frame.
    private var sharper: UIImage?
    private func showSharper() {
        guard let image = sharper, link == nil, !held, image.size.width > 0 else { return }
        sharper = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.contents = image.cgImage
        CATransaction.commit()
    }

    private func loadVideo() {
        guard case .video(_, _, nil, let url) = media else { return }
        Task { [weak self] in
            guard let url = await url(), let self, !finished else { return }
            let player = AVQueuePlayer()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            use(player, shared: false)
        }
    }
    private var looper: AVPlayerLooper?

    private func use(_ player: AVPlayer, shared: Bool) {
        playerLayer?.player = player
        video?.attach(player, shared: shared)
    }

    // MARK: Gestures

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view is UIControl { return false }
        let point = touch.location(in: self)
        if route == .closed {
            return picture.frame.insetBy(dx: -12, dy: -12).contains(point) && gesture !== doubleTap && (gesture !== pinch || zooms)
        }
        if isSimulator {
            // The simulator's own picture is the simulator's; everything else dismisses.
            return gesture !== pinch && gesture !== doubleTap && !picture.frame.contains(point)
        }
        if gesture === pinch || gesture === doubleTap { return zooms }
        return true
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gesture === pan && other === pinch) || (gesture === pinch && other === pan)
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pan, case .pinch = hold else { return super.gestureRecognizerShouldBegin(gesture) }
        return false
    }

    /// Takes the spring where it is, keeping its velocity for later.
    private func takeHold(_ next: Hold) {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        #if DEBUG
        reportFlight()
        #endif
        hold = next
    }

    private func letGo() {
        hold = .none
        run()
        apply()
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            gesture.setTranslation(.zero, in: self)
            grab(at: gesture.location(in: self))
        case .changed: drag(to: gesture.location(in: self), moved: gesture.translation(in: self))
        case .ended, .cancelled, .failed: release(velocity: gesture.velocity(in: self), completed: gesture.state == .ended)
        default: break
        }
    }

    /// A finger takes the picture where it is: a zoomed one pans, any other
    /// is dragged toward dismissal.
    private func grab(at finger: CGPoint) {
        let frame = spring.value
        if zooms, route == .open, frame.width > fitFrame.width + 0.5 {
            takeHold(.pan(origin: frame.origin))
        } else {
            let fit = fitFrame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            takeHold(.drag(anchor: CGPoint(x: ((finger.x - frame.minX) / max(1, frame.width)).clamped(),
                                           y: ((finger.y - frame.minY) / max(1, frame.height)).clamped()),
                           size: frame.size, shrink: Self.shrink(hypot(center.x - fit.midX, center.y - fit.midY)), center: center))
        }
    }

    /// 1:1 with the finger: the point it took stays under it.
    private func drag(to finger: CGPoint, moved t: CGPoint) {
        switch hold {
        case .pan(let start):
            spring.set(rubberBanded(CGRect(origin: CGPoint(x: start.x + t.x, y: start.y + t.y), size: spring.value.size)))
        case .drag(let anchor, let size, let shrink, let center):
            let fit = fitFrame
            let moved = CGPoint(x: center.x + t.x, y: center.y + t.y)
            let scale = Self.shrink(hypot(moved.x - fit.midX, moved.y - fit.midY)) / shrink
            let next = CGSize(width: size.width * scale, height: size.height * scale)
            spring.set(CGRect(x: finger.x - anchor.x * next.width, y: finger.y - anchor.y * next.height, width: next.width, height: next.height))
        default: return
        }
        apply()
    }

    /// Let go: thrown or dragged far enough it goes home with the finger's
    /// velocity, otherwise back open; a zoomed picture coasts and settles.
    private func release(velocity v: CGPoint, completed: Bool) {
        switch hold {
        case .pan:
            // Coasts on as a scroll view would, then settles inside.
            zoom = contained(spring.value.offsetBy(dx: v.x * 0.3, dy: v.y * 0.3))
            spring.velocity = [v.x, v.y, 0, 0]
            letGo()
        case .drag:
            let fit = fitFrame
            let frame = spring.value
            let offset = CGPoint(x: frame.midX - fit.midX, y: frame.midY - fit.midY)
            let projected = hypot(offset.x + v.x * 0.18, offset.y + v.y * 0.18)
            spring.velocity = [v.x, v.y, 0, 0]
            hold = .none
            if completed && projected > 130 {
                if route == .open { dismiss() } else { run() }
            } else {
                if route == .closed { reopen() } else { zoom = nil }
                letGo()
            }
        default: break
        }
    }

    #if DEBUG
    /// Verification only: `SQUIRCLE_MEDIA_DRAG=dx,dy,seconds[;…]` drags the
    /// open viewer from its middle (a simulator's from its grabber), each two
    /// seconds after the last.
    static func debugDrags(in window: UIWindow?) async {
        for step in (ProcessInfo.processInfo.environment["SQUIRCLE_MEDIA_DRAG"] ?? "").split(separator: ";") {
            // `tap@SECONDS`: sent home by the close button, then tapped that long into its flight.
            if step.hasPrefix("tap@"), let delay = Double(step.dropFirst(4)) {
                try? await Task.sleep(for: .seconds(2))
                guard let viewer = window?.subviews.last as? MediaViewer else { return }
                viewer.dismiss()
                try? await Task.sleep(for: .seconds(delay))
                viewer.reopen()
                continue
            }
            let n = step.split(separator: ",").compactMap { Double($0) }
            guard n.count == 3 else { continue }
            try? await Task.sleep(for: .seconds(2))
            guard let viewer = window?.subviews.last as? MediaViewer else { return }
            let frame = viewer.spring.value
            let start = viewer.isSimulator ? CGPoint(x: frame.midX, y: frame.maxY + 14) : CGPoint(x: frame.midX, y: frame.midY)
            await viewer.debugDrag(from: start, by: CGPoint(x: n[0], y: n[1]), duration: n[2])
        }
    }

    /// Verification only: a finger at `start` moving by `by` over `duration`
    /// at the display's rate, then lifting, through the pan's own path.
    func debugDrag(from start: CGPoint, by: CGPoint, duration: Double) async {
        grab(at: start)
        let began = CACurrentMediaTime()
        var last = (t: began, p: CGPoint.zero), velocity = CGPoint.zero
        while true {
            await DisplayFrame.next()
            let now = CACurrentMediaTime()
            let f = min(1, (now - began) / duration)
            let p = CGPoint(x: by.x * f, y: by.y * f)
            if now > last.t { velocity = CGPoint(x: (p.x - last.p.x) / (now - last.t), y: (p.y - last.p.y) / (now - last.t)) }
            last = (now, p)
            drag(to: CGPoint(x: start.x + p.x, y: start.y + p.y), moved: p)
            if f >= 1 { break }
        }
        release(velocity: velocity, completed: true)
    }
    #endif

    /// How much a picture dragged this far from its place has shrunk.
    private static func shrink(_ distance: CGFloat) -> CGFloat { 1 - 0.28 * (distance / 520).clamped() }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let finger = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let frame = spring.value
            takeHold(.pinch(frame: frame, anchor: CGPoint(x: (finger.x - frame.minX) / max(1, frame.width),
                                                          y: (finger.y - frame.minY) / max(1, frame.height))))
        case .changed:
            guard case .pinch(let start, let anchor) = hold else { return }
            var scale = gesture.scale
            let limit = fitFrame.width * Self.maxZoom / max(1, start.width)
            if scale > limit { scale = limit * pow(scale / limit, 0.3) }
            let size = CGSize(width: start.width * scale, height: start.height * scale)
            spring.set(CGRect(x: finger.x - anchor.x * size.width, y: finger.y - anchor.y * size.height, width: size.width, height: size.height))
            apply()
        case .ended, .cancelled, .failed:
            guard case .pinch = hold else { return }
            hold = .none
            let fit = fitFrame
            let frame = spring.value
            spring.velocity = [0, 0, 0, 0]
            if gesture.state == .ended, frame.width < fit.width * 0.72 {
                if route == .open { dismiss() } else { run() }
                return
            }
            if route == .closed { reopen() }
            zoom = frame.width > fit.width + 0.5 ? contained(frame) : nil
            letGo()
        default: break
        }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard route == .open, zooms else { return }
        let fit = fitFrame
        if spring.value.width > fit.width + 0.5 {
            zoom = nil
        } else {
            let point = gesture.location(in: self)
            let scale: CGFloat = 2.5
            let anchor = CGPoint(x: ((point.x - fit.minX) / fit.width).clamped(), y: ((point.y - fit.minY) / fit.height).clamped())
            let size = CGSize(width: fit.width * scale, height: fit.height * scale)
            zoom = contained(CGRect(x: point.x - anchor.x * size.width, y: point.y - anchor.y * size.height, width: size.width, height: size.height))
        }
        Theme.selectionHaptic()
        run()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if route == .closed { reopen(); return }
        if isSimulator { dismiss(); return }
        chrome.animate(to: chrome.target > 0.5 ? 0 : 1)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !finished else { return nil }
        // Flying home, only the picture itself can be caught; the rest of
        // the screen is already the conversation's.
        if route == .closed { return picture.frame.insetBy(dx: -12, dy: -12).contains(point) ? self : nil }
        return super.hitTest(point, with: event) ?? self
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }

    // MARK: Profiling

    #if DEBUG
    /// Verification only: presses a clip's control ("unmute", "mute", "pause", "play").
    func debugControl(_ step: String) { video?.debugControl(step) }
    #endif

    #if DEBUG
    /// Display link frames of the current flight: hitches are logged when it rests.
    private var flight: [(CFTimeInterval, CFTimeInterval)] = []
    private func reportFlight() {
        guard flight.count > 2 else { flight = []; return }
        let gaps = zip(flight.dropFirst(), flight).map { ($0.0 - $1.0, $1.1) }
        let hitches = gaps.filter { $0.0 > 1.5 * $0.1 }
        NSLog("SQUIRCLE-VIEWER %@ frames=%d hitches=%d worst_ms=%.1f", route == .open ? "open" : "close",
              flight.count, hitches.count, (gaps.map(\.0).max() ?? 0) * 1000)
        flight = []
    }
    #endif
}

/// A rectangle as one spring: centre and size, each with its velocity.
private struct RectSpring {
    private(set) var value = CGRect.zero
    /// Points per second: centre x, centre y, width, height.
    var velocity: [CGFloat] = [0, 0, 0, 0]
    var parameters = SpringDriver.Parameters(response: 0.42, damping: 0.86)

    mutating func set(_ rect: CGRect) {
        value = rect
    }

    /// One frame toward `goal`; true once it rests there.
    mutating func step(toward goal: CGRect, dt: CGFloat) -> Bool {
        var current = [value.midX, value.midY, value.width, value.height]
        let target = [goal.midX, goal.midY, goal.width, goal.height]
        var resting = true
        for i in 0..<4 {
            (current[i], velocity[i]) = SpringDriver.step(value: current[i], velocity: velocity[i], target: target[i], dt: dt, parameters: parameters)
            if abs(current[i] - target[i]) > 0.25 || abs(velocity[i]) > 4 { resting = false }
        }
        let size = CGSize(width: max(1, current[2]), height: max(1, current[3]))
        value = CGRect(x: current[0] - size.width / 2, y: current[1] - size.height / 2, width: size.width, height: size.height)
        if resting { velocity = [0, 0, 0, 0] }
        return resting
    }
}

/// Raw touches on a large simulator, sent to it. Losing interactivity
/// mid-touch ends that touch on the simulator.
@MainActor
private final class SimulatorInput: UIView {
    var onTouch: ((_ phase: String, _ point: CGPoint) -> Bool)?
    weak var screen: SimulatorScreen?
    private var tracking: CGPoint?
    var interactive = false {
        didSet {
            guard interactive != oldValue else { return }
            isUserInteractionEnabled = interactive
            if !interactive, let last = tracking { _ = onTouch?("end", last); tracking = nil }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityLabel = "Simulator"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func forward(_ touches: Set<UITouch>, _ phase: String) {
        guard interactive, let touch = touches.first, let screen else { return }
        let point = touch.location(in: screen)
        if phase == "begin" { tracking = onTouch?(phase, point) == true ? point : nil }
        else if tracking != nil { _ = onTouch?(phase, point); tracking = phase == "end" ? nil : point }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "begin") }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "move") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "end") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "end") }
}

/// A large simulator's grabber (drag it to send the simulator back) and its
/// Home, thread and shrink buttons.
@MainActor
private final class SimulatorChrome: UIView {
    let grabber = UIView()
    let home = Theme.glassButton(symbol: "house", identifier: "simulator.home", accessibilityLabel: "Simulator Home")
    let thread = Theme.glassButton(symbol: "bubble.left.and.text.bubble.right", identifier: "simulator.thread", accessibilityLabel: "Open thread")
    let shrink = Theme.glassButton(symbol: "chevron.down", identifier: "simulator.shrink", accessibilityLabel: "Shrink simulator")
    private let showsThread: Bool

    init(showsThread: Bool) {
        self.showsThread = showsThread
        super.init(frame: .zero)
        grabber.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        grabber.layer.cornerRadius = 2.5
        grabber.isUserInteractionEnabled = false
        addSubview(grabber)
        thread.isHidden = !showsThread
        for button in [home, thread, shrink] { addSubview(button) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func place(grabberAt point: CGPoint, buttonsAt y: CGFloat, width: CGFloat) {
        frame = CGRect(x: 0, y: 0, width: width, height: y + 48)
        grabber.frame = CGRect(x: point.x - 18, y: point.y - 2.5, width: 36, height: 5)
        let buttons = [home] + (showsThread ? [thread] : []) + [shrink]
        let total = CGFloat(buttons.count) * 48 + CGFloat(buttons.count - 1) * 16
        for (slot, button) in buttons.enumerated() {
            button.frame = CGRect(x: width / 2 - total / 2 + CGFloat(slot) * 64, y: y, width: 48, height: 48)
        }
    }

    /// Only its buttons take touches; the rest is the viewer's backdrop.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Play, a scrubber, the time and mute for a clip. It opens muted unless the
/// person unmuted one earlier this launch, and holds the audio only while
/// unmuted and playing. An inline player it carried on with goes back muted
/// and looping.
@MainActor
private final class VideoControls: UIView {
    var onPresentationSize: ((CGSize) -> Void)?
    private let surface = Theme.glassSurface(cornerRadius: 26)
    private let play = UIButton(type: .system)
    private let mute = UIButton(type: .system)
    private let slider = UISlider()
    private let time = UILabel()
    private var player: AVPlayer?
    private var shared = false
    private var observations: [NSKeyValueObservation] = []
    private var ticker: Task<Void, Never>?
    /// Scrubbing, and whether it was playing before.
    private var scrubbing: Bool?
    private var closed = false
    private var presentationSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(surface)
        for button in [play, mute] {
            button.tintColor = .label
            button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold), forImageIn: .normal)
            surface.contentView.addSubview(button)
        }
        play.accessibilityIdentifier = "viewer.play"
        mute.accessibilityIdentifier = "viewer.mute"
        play.addAction(UIAction { [weak self] _ in
            guard let player = self?.player else { return }
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        }, for: .touchUpInside)
        mute.addAction(UIAction { [weak self] _ in
            guard let player = self?.player else { return }
            player.isMuted.toggle()
            MediaAudio.unmuted = !player.isMuted
        }, for: .touchUpInside)
        slider.minimumTrackTintColor = .label
        slider.maximumTrackTintColor = UIColor.label.withAlphaComponent(0.25)
        slider.setThumbImage(Self.thumb, for: .normal)
        slider.addAction(UIAction { [weak self] _ in self?.scrub() }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in self?.endScrub() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.accessibilityLabel = "Position"
        surface.contentView.addSubview(slider)
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        time.textColor = .secondaryLabel
        time.textAlignment = .right
        surface.contentView.addSubview(time)
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let thumb: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { _ in
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 14, height: 14)).fill()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        play.frame = CGRect(x: 6, y: 2, width: 48, height: 48)
        mute.frame = CGRect(x: bounds.width - 54, y: 2, width: 48, height: 48)
        time.frame = CGRect(x: mute.frame.minX - 50, y: 0, width: 46, height: bounds.height)
        slider.frame = CGRect(x: play.frame.maxX + 4, y: 0, width: time.frame.minX - play.frame.maxX - 12, height: bounds.height)
    }

    func attach(_ player: AVPlayer, shared: Bool) {
        self.player = player
        self.shared = shared
        player.isMuted = !MediaAudio.unmuted
        let changed: @Sendable (AVPlayer) -> Void = { [weak self] _ in Task { @MainActor in self?.sync() } }
        observations = [player.observe(\.isMuted) { player, _ in changed(player) },
                        player.observe(\.timeControlStatus) { player, _ in changed(player) },
                        player.observe(\.currentItem?.presentationSize) { player, _ in changed(player) }]
        if !closed { player.play() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        sync()
    }

    private func sync() {
        guard let player else {
            play.setImage(UIImage(systemName: "play.fill"), for: .normal)
            mute.setImage(UIImage(systemName: "speaker.slash.fill"), for: .normal)
            return
        }
        let paused = player.timeControlStatus == .paused
        play.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill"), for: .normal)
        play.accessibilityLabel = paused ? "Play" : "Pause"
        mute.setImage(UIImage(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"), for: .normal)
        mute.accessibilityLabel = player.isMuted ? "Unmute" : "Mute"
        if let size = player.currentItem?.presentationSize, size.width > 0, size != presentationSize {
            presentationSize = size
            onPresentationSize?(size)
        }
        MediaAudio.play(audible: !closed && !player.isMuted && !paused)
    }

    private func tick() {
        guard let player, let item = player.currentItem, scrubbing == nil else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { time.text = nil; return }
        let now = player.currentTime().seconds
        slider.value = Float(now / duration)
        time.text = Elapsed.clock(duration - now)
    }

    private func scrub() {
        guard let player, let item = player.currentItem else { return }
        if scrubbing == nil {
            scrubbing = player.timeControlStatus != .paused
            player.pause()
        }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let seconds = Double(slider.value) * duration
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time.text = Elapsed.clock(duration - seconds)
    }

    private func endScrub() {
        guard let resume = scrubbing else { return }
        scrubbing = nil
        if resume { player?.play() }
    }

    /// Flying home: the audio goes; an inline player goes back to looping muted.
    func closing() {
        closed = true
        guard let player else { return }
        if shared { player.isMuted = true; player.play() }
        MediaAudio.play(audible: false)
    }

    func reopened() {
        closed = false
        guard let player else { return }
        player.isMuted = !MediaAudio.unmuted
        player.play()
        sync()
    }

    #if DEBUG
    func debugControl(_ step: String) {
        switch step {
        case "unmute", "mute": if player?.isMuted == (step == "unmute") { mute.sendActions(for: .touchUpInside) }
        default: if (player?.timeControlStatus == .paused) == (step == "play") { play.sendActions(for: .touchUpInside) }
        }
    }
    #endif

    func finished() {
        closed = true
        ticker?.cancel()
        observations = []
        if let player, !shared { player.pause() }
        MediaAudio.play(audible: false)
    }
}
