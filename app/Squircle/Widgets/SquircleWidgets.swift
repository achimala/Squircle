import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// The Live Activity is drawn by the system from SwiftUI; this is the one
// place Squircle uses it. Colors are the app's Clay palette.

@main
struct SquircleWidgets: WidgetBundle {
    var body: some Widget { AgentActivity() }
}

private enum Clay {
    static let accent = dynamic(rgb(0.71, 0.33, 0.20), rgb(0.94, 0.56, 0.41))
    static let paper = dynamic(rgb(0.972, 0.957, 0.933), rgb(0.078, 0.070, 0.064))
    static let success = dynamic(rgb(0.36, 0.53, 0.24), rgb(0.60, 0.78, 0.44))
    static let warning = dynamic(rgb(0.72, 0.55, 0.06), rgb(0.95, 0.78, 0.34))
    /// The Dynamic Island is always black: the dark variants.
    static let islandAccent = Color(rgb(0.94, 0.56, 0.41))
    static let islandWarning = Color(rgb(0.95, 0.78, 0.34))
    static let islandSuccess = Color(rgb(0.60, 0.78, 0.44))

    private static func dynamic(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: 1)
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
        case .working: island ? Clay.islandAccent : Clay.accent
        case .needsYou: island ? Clay.islandWarning : Clay.warning
        case .done: island ? Clay.islandSuccess : Clay.success
        }
    }
}

/// A small jelly cube: a squircle of tinted gel with a soft highlight.
private struct JellyCube: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .topLeading, endPoint: .bottomTrailing))
            // Light caught inside the gel.
            Ellipse()
                .fill(.white.opacity(0.45))
                .frame(width: size * 0.42, height: size * 0.24)
                .rotationEffect(.degrees(-20))
                .offset(x: -size * 0.14, y: -size * 0.2)
                .blur(radius: size * 0.05)
            shape.strokeBorder(.white.opacity(0.35), lineWidth: max(0.5, size * 0.04))
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

struct AgentActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SquircleActivityAttributes.self) { context in
            LockScreenView(app: context.attributes.appName, state: context.state, stale: context.isStale)
                .widgetURL(link(context.attributes))
                .activityBackgroundTint(Clay.paper)
                .activitySystemActionForegroundColor(Clay.accent)
        } dynamicIsland: { context in
            let state = context.state
            let tone = state.tone.color(island: true)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        JellyCube(color: tone, size: 22)
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
                JellyCube(color: tone, size: 16)
            } compactTrailing: {
                if state.needsYou {
                    Image(systemName: "hand.raised.fill").foregroundStyle(tone)
                } else if state.workers > 0 {
                    Text("\(state.workers)").font(.caption.weight(.bold)).foregroundStyle(tone)
                } else if !state.working {
                    Image(systemName: "checkmark").foregroundStyle(tone)
                }
            } minimal: {
                JellyCube(color: tone, size: 16)
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
            JellyCube(color: state.tone.color(island: false), size: 34)
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
