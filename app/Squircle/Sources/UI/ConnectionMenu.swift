import UIKit

/// The Mac connection's state and actions, as a menu section: Home's Mac
/// button and the overlay's ⋯ menu show the same one.
@MainActor
enum ConnectionMenu {
    static func section(_ model: SquircleModel) -> UIMenu {
        let summary = model.connectionSummary
        let state = UIAction(title: summary.title, subtitle: summary.detail,
                             image: UIImage(systemName: "macbook")?.withTintColor(summary.tint, renderingMode: .alwaysOriginal),
                             attributes: .disabled) { _ in }
        let reconnect = UIAction(title: "Reconnect", image: UIImage(systemName: "arrow.clockwise")) { [weak model] _ in
            Task { await model?.reconnect() }
        }
        return UIMenu(options: .displayInline, children: [state, reconnect])
    }
}
