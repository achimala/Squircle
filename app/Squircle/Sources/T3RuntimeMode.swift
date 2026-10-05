import Foundation

/// Wire values from the stock T3 0.0.45 orchestration contract.
enum T3RuntimeMode: String, CaseIterable {
    case approvalRequired = "approval-required"
    case autoAcceptEdits = "auto-accept-edits"
    case auto = "auto"
    case fullAccess = "full-access"

    var title: String {
        switch self {
        case .approvalRequired: return "Ask"
        case .autoAcceptEdits: return "Auto edits"
        case .auto: return "Auto"
        case .fullAccess: return "Full access"
        }
    }
}
