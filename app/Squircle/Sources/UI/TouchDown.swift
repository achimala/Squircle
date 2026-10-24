import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Reports a finger going down at once, alongside every other gesture and
/// without holding touches back: a scroll view delays its content's own
/// touch-down until it knows the touch isn't a scroll, which for a quick tap
/// is when the finger lifts. What a tap will open can start being made from
/// here (`StudioViewController.prepareThread`, `prepareApp`).
final class TouchDown: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let began: (CGPoint) -> Void

    init(began: @escaping (CGPoint) -> Void) {
        self.began = began
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = touches.first, let view else { return }
        began(touch.location(in: view))
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
