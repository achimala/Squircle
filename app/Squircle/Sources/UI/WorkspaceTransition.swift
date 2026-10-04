import UIKit

final class WorkspaceTransition: NSObject, UIViewControllerTransitioningDelegate {
    var source: ProjectHero?
    init(source: ProjectHero?) { self.source = source }
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        WorkspaceAnimator(source: self.source, opening: true)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        WorkspaceAnimator(source: source, opening: false)
    }
}

private final class WorkspaceAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    weak var source: ProjectHero?
    let opening: Bool
    init(source: ProjectHero?, opening: Bool) { self.source = source; self.opening = opening }
    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.78
    }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let from = context.viewController(forKey: .from), let to = context.viewController(forKey: .to) else { context.completeTransition(false); return }
        let container = context.containerView
        container.backgroundColor = Studio.canvas
        let detail = (opening ? to : from) as? ProjectViewController
        to.view.frame = context.finalFrame(for: to)
        if opening { container.addSubview(to.view) }
        else if to.view.superview == nil { container.insertSubview(to.view, belowSubview: from.view) }
        to.view.layoutIfNeeded(); from.view.layoutIfNeeded()
        let stage = UIView(frame: container.bounds); stage.backgroundColor = Studio.canvas

        guard let source, let detail, source.phone.hasScreenshot, !UIAccessibility.isReduceMotionEnabled else {
            let incoming = screenImage(to.view), outgoing = screenImage(from.view)
            [incoming, outgoing].forEach { $0.frame = stage.bounds; stage.addSubview($0) }
            container.addSubview(stage)
            UIView.animate(withDuration: transitionDuration(using: context), animations: { outgoing.alpha = 0 }, completion: { _ in
                context.completeTransition(!context.transitionWasCancelled); stage.removeFromSuperview()
            })
            return
        }
        source.phone.layer.removeAllAnimations(); source.phone.transform = .identity
        source.layoutIfNeeded()
        let startPreview = opening ? source.phone : detail.preview
        let endPreview = opening ? detail.preview : source.phone
        // Both endpoints must show the same artifact at handoff, including a
        // newer screenshot published while the workspace was open.
        endPreview.setScreenshot(startPreview.screenshot)
        let start = startPreview.convert(startPreview.transitionContentFrame, to: container)
        let end = endPreview.convert(endPreview.transitionContentFrame, to: container)

        // Only the surrounding typography is captured. The phone stays a live
        // Metal-backed SceneKit view with changing mesh orientation and camera.
        source.phone.isHidden = true; detail.preview.isHidden = true
        let outgoing = screenImage(from.view), incoming = screenImage(to.view)
        source.phone.isHidden = false; detail.preview.isHidden = false
        [outgoing, incoming].forEach { $0.frame = stage.bounds; stage.addSubview($0) }
        incoming.alpha = 0
        container.addSubview(stage)
        let viewport = startPreview.viewportView
        stage.addSubview(viewport); viewport.transform = .identity; viewport.frame = start
        startPreview.setAnimating(true)
        let originalPose = startPreview.poseProgress
        #if DEBUG
        MotionAudit.shared.begin(opening ? "workspace.open.3d" : "workspace.close.3d")
        #endif
        let duration = transitionDuration(using: context)
        LiveSceneMotion(duration: duration) { phase, spring in
            // Keep the drawable resolution fixed while the compositor scales its
            // viewport. Every display tick still renders a new 3D perspective.
            let scale = 1 + (end.width/start.width - 1) * spring
            viewport.transform = CGAffineTransform(scaleX: scale, y: scale)
            viewport.center = CGPoint(x: start.midX + (end.midX-start.midX)*spring,
                                      y: start.midY + (end.midY-start.midY)*spring)
            startPreview.setPose(self.opening ? spring : 1-spring)
            outgoing.alpha = 1-min(1, phase/0.24)
            incoming.alpha = max(0, min(1, (phase-0.27)/0.66))
        } completion: {
            endPreview.setPose(self.opening ? 1 : 0)
            startPreview.setAnimating(false)
            startPreview.addSubview(viewport); viewport.transform = .identity
            startPreview.setPose(originalPose); startPreview.setNeedsLayout(); startPreview.layoutIfNeeded()
            context.completeTransition(!context.transitionWasCancelled)
            stage.removeFromSuperview()
        }.start(in: container.window)
    }

    private func screenImage(_ view: UIView) -> UIImageView {
        let format = UIGraphicsImageRendererFormat(); format.scale = view.window?.screen.scale ?? 3
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return UIImageView(image: image)
    }
}

/// One clock drives real mesh/camera motion and surrounding UIKit content. Its
/// display link retains it only for the duration of the transition.
@MainActor
private final class LiveSceneMotion: NSObject {
    let duration: Double
    let update: (CGFloat, CGFloat) -> Void
    let completion: () -> Void
    private var link: CADisplayLink?
    private var started: CFTimeInterval?
    init(duration: Double, update: @escaping (CGFloat, CGFloat) -> Void, completion: @escaping () -> Void) {
        self.duration = duration; self.update = update; self.completion = completion
    }
    func start(in window: UIWindow?) {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: Float(window?.screen.maximumFramesPerSecond ?? 60), preferred: Float(window?.screen.maximumFramesPerSecond ?? 60))
        self.link = link; update(0, 0); link.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ link: CADisplayLink) {
        if started == nil { started = link.timestamp }
        let phase = min(1, (link.timestamp-started!)/duration)
        let spring = (1-(1+8*phase)*exp(-8*phase))/(1-9*exp(-8))
        UIView.performWithoutAnimation { update(CGFloat(phase), CGFloat(spring)) }
        if phase >= 1 { link.invalidate(); self.link = nil; completion() }
    }
}
