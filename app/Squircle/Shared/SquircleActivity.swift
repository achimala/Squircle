import ActivityKit
import Foundation

/// An app's agent at work, on the Lock Screen and in the Dynamic Island.
/// The Mac starts, updates and ends it by push; the field names are the
/// service's `LiveState` and push-to-start `attributes` (`src/push.rs`).
struct SquircleActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The agent's current step, or "Waiting on workers", "Needs you", "Done".
        var status: String
        /// Workers still running.
        var workers: Int
        var needsYou: Bool
        var working: Bool
    }

    var appName: String
    /// The T3 project, so a tap opens that app.
    var projectID: String
}
