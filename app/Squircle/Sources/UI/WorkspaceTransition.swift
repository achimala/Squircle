import UIKit

/// The same device moves from the shelf into the workspace. A spring controls
/// the geometry while UIKit composites the surfaces; no timer-driven layout.
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
        UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.72
    }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        #if DEBUG
        MotionAudit.shared.begin(opening ? "workspace.open" : "workspace.close")
        #endif
        guard let from = context.viewController(forKey: .from), let to = context.viewController(forKey: .to) else { context.completeTransition(false); return }
        let container = context.containerView
        let detail = (opening ? to : from) as? ProjectViewController
        to.view.frame = context.finalFrame(for: to)
        if opening { container.addSubview(to.view) } else { container.insertSubview(to.view, belowSubview: from.view) }
        to.view.layoutIfNeeded(); from.view.layoutIfNeeded()
        guard let source, let detail, !UIAccessibility.isReduceMotionEnabled else {
            to.view.alpha = opening ? 0 : 1
            UIView.animate(withDuration: transitionDuration(using: context), animations: {
                to.view.alpha = 1
                if !self.opening { from.view.alpha = 0 }
            }, completion: { _ in from.view.alpha = 1; context.completeTransition(!context.transitionWasCancelled) })
            return
        }
        let startPreview = opening ? source.phone : detail.preview
        let endPreview = opening ? detail.preview : source.phone
        let start = startPreview.convert(startPreview.transitionContentFrame, to: container)
        let end = endPreview.convert(endPreview.transitionContentFrame, to: container)
        let phone = UIImageView(image: startPreview.transitionSnapshot())
        phone.contentMode = .scaleAspectFit
        _ = endPreview.transitionSnapshot() // Warm the destination Metal surface before handoff.
        phone.frame = start; container.addSubview(phone)
        source.phone.alpha = 0; detail.preview.alpha = 0
        if opening {
            to.view.alpha = 0
            var t = CATransform3DIdentity; t.m34 = -1/1400; t = CATransform3DTranslate(t, 0, 34, -40); t = CATransform3DRotate(t, 0.025, 1, 0, 0)
            to.view.layer.transform = t
        }
        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.9) {
            phone.frame = end
            if self.opening { to.view.alpha = 1; to.view.layer.transform = CATransform3DIdentity }
            else { from.view.alpha = 0; from.view.transform = CGAffineTransform(translationX: 0, y: 25).scaledBy(x: 0.975, y: 0.975) }
        }
        animator.addCompletion { _ in
            source.phone.alpha = 1; detail.preview.alpha = 1
            from.view.alpha = 1; from.view.transform = .identity; to.view.layer.transform = CATransform3DIdentity
            context.completeTransition(!context.transitionWasCancelled)
            DispatchQueue.main.async { phone.removeFromSuperview() }
        }
        animator.startAnimation()
    }
}
