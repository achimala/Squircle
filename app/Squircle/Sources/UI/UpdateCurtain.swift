import UIKit

/// Shown once installation of the running app's new build is confirmed: a
/// short glass notice, then the app steps aside to the Home Screen, where its
/// icon shows the install. iOS can't reopen an app after replacing it.
@MainActor
final class UpdateCurtain: UIView {
    private let glass = Theme.glassSurface(cornerRadius: Theme.Radius.large)
    private let title = Theme.label("", Theme.Text.title, lines: 2)
    private let detail = Theme.label("", Theme.Text.line, color: .secondaryLabel, lines: 3)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var onDismiss: (() -> Void)?
    /// Steps aside to the Home Screen, then waits for the app to come back.
    /// Ends with the curtain, however it goes.
    private var stepAside: Task<Void, Never>?

    /// Shows the curtain for `build` (the Mac reported every byte of it
    /// sent), or with nil takes away one that is up.
    static func sync(in view: UIView, build: AppBuild?, onDismiss: @escaping () -> Void) {
        if let build { show(in: view, build: build, onDismiss: onDismiss) }
        else { view.subviews.compactMap { $0 as? UpdateCurtain }.forEach { $0.remove() } }
    }

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
        let pad = Theme.Space.section, spinnerGap = Theme.Space.group, gap = Theme.Space.row
        let width = min(bounds.width - 2 * pad, 340)
        let inner = width - 2 * pad
        let titleHeight = title.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        let detailHeight = detail.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        let height = pad + 24 + spinnerGap + titleHeight + gap + detailHeight + pad
        glass.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        glass.center = CGPoint(x: bounds.midX, y: bounds.midY)
        spinner.center = CGPoint(x: width / 2, y: pad + 12)
        title.frame = CGRect(x: pad, y: pad + 24 + spinnerGap, width: inner, height: titleHeight)
        detail.frame = CGRect(x: pad, y: title.frame.maxY + gap, width: inner, height: detailHeight)
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
        stepAside = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            let returned = NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification)
            UIApplication.shared.perform(NSSelectorFromString("suspend"))
            for await _ in returned { break }
            guard !Task.isCancelled, let self else { return }
            remove()
            onDismiss?()
        }
    }

    /// Gone, and with it the step aside, whether or not it happened yet.
    private func remove() {
        stepAside?.cancel()
        stepAside = nil
        removeFromSuperview()
    }
}
