import UIKit

/// Shown once installation of the running app's new build is confirmed: a
/// short glass notice, then the app steps aside to the Home Screen, where its
/// icon shows the install. iOS can't reopen an app after replacing it.
@MainActor
final class UpdateCurtain: UIView {
    private let glass = Theme.glassSurface(cornerRadius: 30)
    private let title = Theme.label("", Theme.font(.headline, 17, .semibold), lines: 2)
    private let detail = Theme.label("", Theme.font(.subheadline, 15), color: .secondaryLabel, lines: 3)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var onDismiss: (() -> Void)?
    private var returned: NSObjectProtocol?

    static func show(in view: UIView, build: AppBuild, onDismiss: @escaping () -> Void) {
        guard !view.subviews.contains(where: { $0 is UpdateCurtain }) else { return }
        let curtain = UpdateCurtain(build: build)
        curtain.onDismiss = onDismiss
        curtain.frame = view.bounds
        curtain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(curtain)
        curtain.present()
    }

    private init(build: AppBuild) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0)
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This app"
        title.text = "Installing \(name) \(build.version)"
        detail.text = "\(name) closes now so iOS can update it. Open it again from the Home Screen when the icon finishes."
        title.textAlignment = .center
        detail.textAlignment = .center
        spinner.startAnimating()
        addSubview(glass)
        [spinner, title, detail].forEach(glass.contentView.addSubview)
        accessibilityViewIsModal = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 48, 340)
        let inner = width - 48
        let titleHeight = title.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        let detailHeight = detail.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        let height = 28 + 24 + 14 + titleHeight + 8 + detailHeight + 28
        glass.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        glass.center = CGPoint(x: bounds.midX, y: bounds.midY)
        spinner.center = CGPoint(x: width / 2, y: 28 + 12)
        title.frame = CGRect(x: 24, y: 28 + 24 + 14, width: inner, height: titleHeight)
        detail.frame = CGRect(x: 24, y: title.frame.maxY + 8, width: inner, height: detailHeight)
    }

    private func present() {
        glass.alpha = 0
        glass.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(springDuration: 0.5, bounce: 0.15) {
            self.backgroundColor = UIColor.black.withAlphaComponent(0.25)
            self.glass.alpha = 1
            self.glass.transform = .identity
        }
        // Step aside to the Home Screen so the icon's progress is visible.
        // If the update fails the app returns to the foreground; the curtain
        // then goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self else { return }
            returned = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
            UIApplication.shared.perform(NSSelectorFromString("suspend"))
        }
    }

    private func close() {
        if let returned { NotificationCenter.default.removeObserver(returned) }
        returned = nil
        removeFromSuperview()
        onDismiss?()
    }
}
