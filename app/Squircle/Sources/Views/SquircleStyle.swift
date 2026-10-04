import SwiftUI

enum SquircleStyle {
    static let background = Color(red: 0.068, green: 0.073, blue: 0.089)
    static let surface = Color(red: 0.112, green: 0.120, blue: 0.140)
    static let raised = Color(red: 0.150, green: 0.158, blue: 0.184)
    static let foreground = Color(red: 0.947, green: 0.938, blue: 0.913)
    static let secondary = Color(red: 0.580, green: 0.600, blue: 0.655)
    static let accent = Color(red: 0.750, green: 0.711, blue: 0.953)
    static let line = Color.white.opacity(0.075)
    static let green = Color(red: 0.594, green: 0.782, blue: 0.672)
}

struct SquircleMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(SquircleStyle.accent)
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .strokeBorder(SquircleStyle.background, lineWidth: max(1.5, size * 0.065))
                .frame(width: size * 0.48, height: size * 0.48)
                .rotationEffect(.degrees(-12))
            Circle()
                .fill(SquircleStyle.background)
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(x: size * 0.23, y: -size * 0.23)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.7)
            .foregroundStyle(SquircleStyle.secondary)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(SquircleStyle.foreground)
            .padding(12)
            .background(SquircleStyle.surface.opacity(configuration.isPressed ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SquircleStyle.line))
    }
}

struct MacConnectionLabel: View {
    let host: String
    let busy: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(busy ? SquircleStyle.accent : SquircleStyle.green).frame(width: 5, height: 5)
            Text(host.isEmpty ? "YOUR MAC" : host.uppercased())
                .lineLimit(1)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.1)
        }
        .foregroundStyle(SquircleStyle.secondary)
    }
}

struct ConnectionUnavailableView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(SquircleStyle.accent)
                .padding(23)
                .background(SquircleStyle.surface, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            Text("Mac connection unavailable")
                .font(.system(size: 23, weight: .medium, design: .rounded))
            Text("This build needs its Mac connection included.\nOpen a configured build to continue.")
                .font(.system(size: 14))
                .foregroundStyle(SquircleStyle.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
