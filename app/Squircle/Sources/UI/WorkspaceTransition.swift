import UIKit

@MainActor
final class WorkspaceTransition: NSObject, UIViewControllerTransitioningDelegate {
    var source: ProjectHero?
    private weak var studio: StudioViewController?
    private var activeAnimator: WorkspaceAnimator?
    private var interactiveDismissal: UIPercentDrivenInteractiveTransition?

    init(source: ProjectHero?, studio: StudioViewController) {
        self.source = source
        self.studio = studio
    }

    func beginInteractiveDismissal() {
        guard interactiveDismissal == nil, activeAnimator == nil else { return }
        let interaction = UIPercentDrivenInteractiveTransition()
        interaction.completionCurve = .easeOut
        interaction.completionSpeed = 0.9
        interactiveDismissal = interaction
    }

    func updateInteractiveDismissal(_ progress: CGFloat) {
        interactiveDismissal?.update(progress.isFinite ? min(1, max(0, progress)) : 0)
    }

    func finishInteractiveDismissal() { interactiveDismissal?.finish() }
    func cancelInteractiveDismissal() { interactiveDismissal?.cancel() }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        makeAnimator(opening: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        makeAnimator(opening: false)
    }

    func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning)
        -> UIViewControllerInteractiveTransitioning? {
        interactiveDismissal
    }

    private func makeAnimator(opening: Bool) -> WorkspaceAnimator {
        let animator = WorkspaceAnimator(source: source, studio: studio, opening: opening) { [weak self] in
            self?.activeAnimator = nil
            self?.interactiveDismissal = nil
        }
        activeAnimator = animator
        return animator
    }
}

@MainActor
private final class WorkspaceAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let source: ProjectHero?
    private weak var studio: StudioViewController?
    private let opening: Bool
    private let didComplete: () -> Void
    private var cachedAnimator: UIViewPropertyAnimator?
    private var poseDriver: ScenePoseDriver?

    init(source: ProjectHero?, studio: StudioViewController?, opening: Bool,
         didComplete: @escaping () -> Void) {
        self.source = source
        self.studio = studio
        self.opening = opening
        self.didComplete = didComplete
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.20 : 0.66
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let animator = interruptibleAnimator(using: context)
        if animator.state == .inactive { animator.startAnimation() }
    }

    func interruptibleAnimator(using context: UIViewControllerContextTransitioning)
        -> UIViewImplicitlyAnimating {
        if let cachedAnimator { return cachedAnimator }
        let container = context.containerView
        // The presenting picker remains visible beneath this over-full-screen
        // container while its neighboring phones and controls move away.
        container.backgroundColor = .clear
        container.isOpaque = false
        guard let from = context.viewController(forKey: .from),
              let to = context.viewController(forKey: .to) else {
            let animator = UIViewPropertyAnimator(duration: 0, curve: .linear)
            animator.addCompletion { [weak self] _ in
                context.completeTransition(false)
                self?.finished()
            }
            cachedAnimator = animator
            return animator
        }

        if opening {
            to.view.frame = context.finalFrame(for: to)
            container.addSubview(to.view)
        } else if to.view.superview == nil {
            // overFullScreen leaves the picker in its original hierarchy.
            // Moving it into UIKit's disposable dismissal container would
            // remove the picker from the window after the animation completes.
            to.view.frame = context.finalFrame(for: to)
            container.insertSubview(to.view, belowSubview: from.view)
        }
        to.view.layoutIfNeeded()
        from.view.layoutIfNeeded()

        guard let source, let studio,
              let detail = (opening ? to : from) as? ProjectViewController,
              !UIAccessibility.isReduceMotionEnabled else {
            return makeSpatialFallback(using: context, from: from, to: to)
        }
        source.layoutIfNeeded()
        source.phone.layoutIfNeeded()
        detail.preview.layoutIfNeeded()
        let startPreview = opening ? source.phone : detail.preview
        let endPreview = opening ? detail.preview : source.phone
        let startTitle = opening ? source.titleLabel : detail.titleLabel
        let endTitle = opening ? detail.titleLabel : source.titleLabel
        let startFrame = startPreview.convert(startPreview.transitionContentFrame, to: container)
        let endFrame = endPreview.convert(endPreview.transitionContentFrame, to: container)
        guard startFrame.width > 0, startFrame.height > 0, endFrame.width > 0, endFrame.height > 0 else {
            return makeSpatialFallback(using: context, from: from, to: to)
        }

        let opening = self.opening
        let startPose = startPreview.poseProgress
        let startPickerOffset = startPreview.pickerOffset
        let endPose = endPreview.poseProgress
        let endPickerOffset = endPreview.pickerOffset
        let galleryOffset = opening ? startPickerOffset : endPickerOffset
        let originalEndScreenshot = endPreview.screenshot
        let sharedScreenshot = startPreview.screenshot
        endPreview.setScreenshot(sharedScreenshot)
        endPreview.setPose(opening ? 1 : 0)
        if !opening { endPreview.setPickerOffset(galleryOffset) }

        let startTitleFrame = startTitle.convert(startTitle.bounds, to: container)
        let endTitleFrame = endTitle.convert(endTitle.bounds, to: container)
        let endTitleHidden = endTitle.isHidden
        let endTitleText = endTitle.text
        let transportedText = startTitle.text
        endTitle.text = transportedText
        endTitle.isHidden = true

        let stage = UIView(frame: container.bounds)
        stage.backgroundColor = .clear
        stage.isOpaque = false
        stage.isUserInteractionEnabled = false
        stage.accessibilityElementsHidden = true
        container.addSubview(stage)

        let viewport = TransportedView(startPreview.viewportView)
        viewport.place(in: stage, frame: startFrame)
        let title = TransportedView(startTitle)
        title.place(in: stage, frame: startTitleFrame)

        // Render the endpoint at its own drawable size while it is out of sight.
        // At handoff this actual live view returns, already holding a frame.
        // Detaching it prevents owner layout from resetting its parking pose.
        let parkedEndpoint = TransportedView(endPreview.viewportView)
        parkedEndpoint.place(in: stage, frame: endFrame.offsetBy(dx: container.bounds.width * 2, dy: 0))
        endPreview.setAnimating(true)
        startPreview.setAnimating(true)

        let originalBackground = detail.view.backgroundColor
        let originalOpaque = detail.view.isOpaque
        detail.view.backgroundColor = .clear
        detail.view.isOpaque = false
        let headerTransform = detail.headerControls.transform
        let listTransform = detail.listContent.transform
        let composerTransform = detail.composerView.transform
        let headerOutside = headerTransform.concatenating(CGAffineTransform(translationX: 0, y: -120))
        let listOutside = listTransform.concatenating(CGAffineTransform(translationX: 0, y: container.bounds.height))
        let composerOutside = composerTransform.concatenating(CGAffineTransform(translationX: 0, y: 200))
        if opening {
            detail.headerControls.transform = headerOutside
            detail.listContent.transform = listOutside
            detail.composerView.transform = composerOutside
        }
        studio.setWorkspaceProgress(opening ? 0 : 1, selectedID: source.project.id)

        let scale = endFrame.width / startFrame.width
        let titleScale = endTitle.font.pointSize / max(1, startTitle.font.pointSize)
        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.90)
        animator.scrubsLinearly = true
        animator.addAnimations {
            viewport.view.center = CGPoint(x: endFrame.midX, y: endFrame.midY)
            viewport.view.transform = CGAffineTransform(scaleX: scale, y: scale)
            title.view.center = CGPoint(x: endTitleFrame.midX, y: endTitleFrame.midY)
            title.view.bounds.size = CGSize(width: endTitleFrame.width / titleScale,
                                           height: endTitleFrame.height / titleScale)
            title.view.transform = CGAffineTransform(scaleX: titleScale, y: titleScale)
            detail.headerControls.transform = opening ? headerTransform : headerOutside
            detail.listContent.transform = opening ? listTransform : listOutside
            detail.composerView.transform = opening ? composerTransform : composerOutside
            studio.setWorkspaceProgress(opening ? 1 : 0, selectedID: source.project.id)
        }

        let driver = ScenePoseDriver(viewport: viewport.view, preview: startPreview, animator: animator,
                                     startY: startFrame.midY, endY: endFrame.midY,
                                     opening: opening, galleryOffset: galleryOffset)
        poseDriver = driver
        driver.start(in: container.window)
        #if DEBUG
        MotionAudit.shared.begin(opening ? "workspace.open.spatial" : "workspace.close.spatial")
        #endif
        animator.addCompletion { [weak self] position in
            driver.stop()
            let completed = !context.transitionWasCancelled
            #if DEBUG
            MotionAudit.shared.note("workspace.completion", values: [
                "opening": opening,
                "position": String(describing: position),
                "cancelled": context.transitionWasCancelled,
                "interactive": context.isInteractive,
                "fraction": self?.cachedAnimator?.fractionComplete ?? -1,
                "completed": completed,
            ])
            #endif
            UIView.performWithoutAnimation {
                startPreview.setAnimating(false)
                endPreview.setAnimating(false)
                if completed {
                    if endPreview.screenshot === sharedScreenshot,
                       endPreview.screenshot !== startPreview.screenshot {
                        endPreview.setScreenshot(startPreview.screenshot)
                    }
                    endPreview.setPose(opening ? 1 : 0)
                    if !opening { endPreview.setPickerOffset(galleryOffset) }
                } else {
                    // Preserve a new model-driven image arriving mid-gesture;
                    // revert only the initial copy made by this transition.
                    if endPreview.screenshot === sharedScreenshot {
                        endPreview.setScreenshot(originalEndScreenshot)
                    }
                    endPreview.setPose(endPose)
                    endPreview.setPickerOffset(endPickerOffset)
                    if endTitle.text == transportedText { endTitle.text = endTitleText }
                }
                startPreview.setPose(startPose)
                startPreview.setPickerOffset(startPickerOffset)
                parkedEndpoint.restore()
                viewport.restore()
                title.restore()
                endTitle.isHidden = endTitleHidden
                detail.headerControls.transform = headerTransform
                detail.listContent.transform = listTransform
                detail.composerView.transform = composerTransform
                detail.view.backgroundColor = completed || !opening ? Studio.canvas : originalBackground
                detail.view.isOpaque = originalOpaque
                studio.setWorkspaceProgress(completed ? (opening ? 1 : 0) : (opening ? 0 : 1),
                                            selectedID: source.project.id)
                startPreview.setNeedsLayout()
                startPreview.layoutIfNeeded()
                endPreview.setNeedsLayout()
                endPreview.layoutIfNeeded()
                if completed && !opening { from.view.removeFromSuperview() }
                if !completed && opening { to.view.removeFromSuperview() }
                stage.removeFromSuperview()
            }
            context.completeTransition(completed)
            self?.finished()
        }
        cachedAnimator = animator
        return animator
    }

    /// Reduce Motion and missing-source navigation use a short spatial move.
    /// Both screens stay fully opaque; no rendered copies or opacity animation.
    private func makeSpatialFallback(using context: UIViewControllerContextTransitioning,
                                     from: UIViewController, to: UIViewController) -> UIViewPropertyAnimator {
        let opening = self.opening
        let moving = opening ? to.view! : from.view!
        let originalTransform = moving.transform
        let originalBackground = moving.backgroundColor
        let distance: CGFloat = UIAccessibility.isReduceMotionEnabled ? 18 : context.containerView.bounds.height
        let displaced = originalTransform.concatenating(CGAffineTransform(translationX: 0, y: distance))
        moving.backgroundColor = Studio.canvas
        if opening { moving.transform = displaced }
        let studio = self.studio
        let projectID = source?.project.id ?? ""
        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: .easeInOut)
        animator.addAnimations {
            moving.transform = opening ? originalTransform : displaced
            studio?.setWorkspaceProgress(opening ? 1 : 0, selectedID: projectID)
        }
        animator.addCompletion { [weak self] position in
            let completed = !context.transitionWasCancelled
            #if DEBUG
            MotionAudit.shared.note("workspace.fallback.completion", values: [
                "opening": opening,
                "position": String(describing: position),
                "cancelled": context.transitionWasCancelled,
                "interactive": context.isInteractive,
                "fraction": self?.cachedAnimator?.fractionComplete ?? -1,
                "completed": completed,
            ])
            #endif
            moving.transform = originalTransform
            moving.backgroundColor = originalBackground
            studio?.setWorkspaceProgress(completed ? (opening ? 1 : 0) : (opening ? 0 : 1), selectedID: projectID)
            if completed && !opening { from.view.removeFromSuperview() }
            if !completed && opening { to.view.removeFromSuperview() }
            context.completeTransition(completed)
            self?.finished()
        }
        cachedAnimator = animator
        return animator
    }

    private func finished() {
        poseDriver?.stop()
        poseDriver = nil
        cachedAnimator = nil
        didComplete()
    }
}

/// Retains the actual view and its original layout ownership for either outcome
/// of an interruptible transition. No duplicate text or Metal layer is created.
@MainActor
private final class TransportedView {
    let view: UIView
    private let parent: UIView?
    private let index: Int
    private let bounds: CGRect
    private let center: CGPoint
    private let transform: CGAffineTransform
    private let translatesConstraints: Bool
    private let constraints: [NSLayoutConstraint]

    init(_ view: UIView) {
        self.view = view
        parent = view.superview
        index = view.superview?.subviews.firstIndex(of: view) ?? 0
        bounds = view.bounds
        center = view.center
        transform = view.transform
        translatesConstraints = view.translatesAutoresizingMaskIntoConstraints
        var owned: [NSLayoutConstraint] = []
        var ancestor: UIView? = view
        while let current = ancestor {
            owned += current.constraints.filter {
                $0.isActive && (($0.firstItem as? UIView) === view || ($0.secondItem as? UIView) === view)
            }
            ancestor = current.superview
        }
        constraints = owned
        NSLayoutConstraint.deactivate(owned)
    }

    func place(in stage: UIView, frame: CGRect) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.transform = .identity
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
        stage.addSubview(view)
    }

    func restore() {
        view.removeFromSuperview()
        if let parent { parent.insertSubview(view, at: min(index, parent.subviews.count)) }
        view.transform = .identity
        view.bounds = bounds
        view.center = center
        view.transform = transform
        view.translatesAutoresizingMaskIntoConstraints = translatesConstraints
        NSLayoutConstraint.activate(constraints)
    }
}

/// UIKit controls timing, spring settling and interactive reversal. SceneKit
/// follows the live layer's presented position rather than a second clock.
@MainActor
private final class ScenePoseDriver: NSObject {
    private weak var viewport: UIView?
    private weak var preview: DevicePreview?
    private weak var animator: UIViewPropertyAnimator?
    private let startY: CGFloat
    private let endY: CGFloat
    private let opening: Bool
    private let galleryOffset: CGFloat
    private var link: CADisplayLink?

    init(viewport: UIView, preview: DevicePreview, animator: UIViewPropertyAnimator,
         startY: CGFloat, endY: CGFloat, opening: Bool, galleryOffset: CGFloat) {
        self.viewport = viewport
        self.preview = preview
        self.animator = animator
        self.startY = startY
        self.endY = endY
        self.opening = opening
        self.galleryOffset = galleryOffset
    }

    func start(in window: UIWindow?) {
        let target = WeakDisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(WeakDisplayLinkTarget.tick))
        let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func stop() { link?.invalidate(); link = nil }

    fileprivate func tick() {
        guard let viewport, let preview else { stop(); return }
        let y = viewport.layer.presentation()?.position.y ?? viewport.layer.position.y
        let distance = endY - startY
        let progress = abs(distance) > 0.1 ? (y - startY) / distance : (animator?.fractionComplete ?? 0)
        let clamped = min(1, max(0, progress))
        preview.setPose(opening ? clamped : 1 - clamped)
        preview.setPickerOffset(galleryOffset)
    }
}

@MainActor
private final class WeakDisplayLinkTarget: NSObject {
    weak var owner: ScenePoseDriver?
    init(owner: ScenePoseDriver) { self.owner = owner }
    @objc func tick() { owner?.tick() }
}
