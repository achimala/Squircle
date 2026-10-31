import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// The Live Activity is drawn by the system from SwiftUI; this is the one
// place Squircle uses it. Colors are the app's Pearl palette (Theme).

@main
struct SquircleWidgets: WidgetBundle {
    var body: some Widget { AgentActivity() }
}

private enum Pearl {
    static let accent = hex(0x1C1D22, 0xF2F2F5)
    static let paper = hex(0xF5F5F2, 0x0E0F12)
    static let working = hex(0x6E56F0, 0x9C8CFF)
    static let success = hex(0x2F9461, 0x5FD38E)
    static let warning = hex(0xD08A00, 0xFFC24D)
    /// The Dynamic Island is always black: the dark variants.
    static let islandWorking = Color(rgb(0x9C8CFF))
    static let islandWarning = Color(rgb(0xFFC24D))
    static let islandSuccess = Color(rgb(0x5FD38E))

    private static func hex(_ light: UInt32, _ dark: UInt32) -> Color {
        let l = rgb(light), d = rgb(dark)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }
    private static func rgb(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

private extension SquircleActivityAttributes.ContentState {
    var tone: Tone { needsYou ? .needsYou : working ? .working : .done }
    var detail: String? {
        if needsYou { return "Needs you" }
        if workers > 0 { return workers == 1 ? "1 worker" : "\(workers) workers" }
        return nil
    }
}

private enum Tone {
    case working, needsYou, done
    func color(island: Bool) -> Color {
        switch self {
        case .working: island ? Pearl.islandWorking : Pearl.working
        case .needsYou: island ? Pearl.islandWarning : Pearl.warning
        case .done: island ? Pearl.islandSuccess : Pearl.success
        }
    }
    var glyph: String {
        switch self {
        case .working: "JellyWorking"
        case .needsYou: "JellyNeedsYou"
        case .done: "JellyDone"
        }
    }
}

/// The app's agent: the real jelly, drawn by the app's shader into this
/// extension's asset catalog (a widget can't run Metal; regenerate with
/// `SQUIRCLE_JELLY_GLYPHS`). Still: ActivityKit doesn't animate, the state
/// changing is the motion. The island is always dark.
private struct JellyCube: View {
    var tone: Tone
    var size: CGFloat
    var island = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(tone.glyph)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size * 1.2, height: size * 1.26)
            .environment(\.colorScheme, island ? .dark : scheme)
    }
}

struct AgentActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SquircleActivityAttributes.self) { context in
            LockScreenView(app: context.attributes.appName, state: context.state, stale: context.isStale)
                .widgetURL(link(context.attributes))
                .activityBackgroundTint(Pearl.paper)
                .activitySystemActionForegroundColor(Pearl.accent)
        } dynamicIsland: { context in
            let state = context.state
            let tone = state.tone.color(island: true)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        JellyCube(tone: state.tone, size: 22, island: true)
                        Text(context.attributes.appName).font(.headline).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let detail = state.detail {
                        Text(detail).font(.subheadline.weight(.semibold)).foregroundStyle(tone).lineLimit(1)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                JellyCube(tone: state.tone, size: 16, island: true)
            } compactTrailing: {
                if state.needsYou {
                    Image(systemName: "hand.raised.fill").foregroundStyle(tone)
                } else if state.workers > 0 {
                    Text("\(state.workers)").font(.caption.weight(.bold)).foregroundStyle(tone)
                } else if !state.working {
                    Image(systemName: "checkmark").foregroundStyle(tone)
                }
            } minimal: {
                JellyCube(tone: state.tone, size: 16, island: true)
            }
            .widgetURL(link(context.attributes))
            .keylineTint(tone)
        }
    }

    private func link(_ attributes: SquircleActivityAttributes) -> URL? {
        var parts = URLComponents()
        parts.scheme = "squircle"
        parts.host = "app"
        parts.queryItems = [URLQueryItem(name: "project", value: attributes.projectID)]
        return parts.url
    }
}

private struct LockScreenView: View {
    let app: String
    let state: SquircleActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(spacing: 12) {
            JellyCube(tone: state.tone, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    if let detail = state.detail {
                        Text(detail).font(.subheadline.weight(.semibold))
                            .foregroundStyle(state.tone.color(island: false)).lineLimit(1)
                    }
                }
                Text(stale ? "Mac not reachable" : state.status)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(16)
    }
}
