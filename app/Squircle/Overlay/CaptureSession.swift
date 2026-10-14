#if SQUIRCLE_OVERLAY || DEBUG
import UIKit

/// One screen or performance recording at a time, started from the message
/// field's + menu while the overlay docks out of the way. `recording` is the
/// whole state the bubble renders.
@MainActor
final class CaptureSession {
    enum Kind: Equatable { case screen, performance }
    struct Recording: Equatable {
        let kind: Kind
        let started: Date
    }

    static let limit: Duration = .seconds(60)
    private(set) var recording: Recording?
    private var screen: ScreenRecorder?
    private var perf: PerfRecorder?
    private var timeout: Task<Void, Never>?
    /// Called when a recording reaches `limit` and stops itself.
    var onLimit: (() -> Void)?

    func start(_ kind: Kind, below overlay: UIWindow) -> Bool {
        guard recording == nil else { return false }
        switch kind {
        case .screen:
            guard let recorder = ScreenRecorder(below: overlay) else { return false }
            screen = recorder
        case .performance:
            perf = PerfRecorder(below: overlay)
        }
        recording = Recording(kind: kind, started: .now)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled else { return }
            self?.onLimit?()
        }
        return true
    }

    /// Stops the recording; returns it ready for the message field.
    /// `snapshot` is the app as it looks now: a screen recording's thumbnail.
    func stop(snapshot: UIImage?) async -> ImageAttachment? {
        guard let recording else { return nil }
        timeout?.cancel()
        timeout = nil
        defer { self.recording = nil; screen = nil; perf = nil }
        switch recording.kind {
        case .screen:
            guard let recorder = self.screen, let poster = snapshot ?? recorder.poster, let done = await recorder.finish() else { return nil }
            let label = Self.clock(done.duration)
            return ImageAttachment(capture: .init(kind: .video, file: done.url, label: label),
                                   thumbnail: Self.badge(poster, text: label, symbol: "play.fill"))
        case .performance:
            guard let perf, let done = await perf.finish() else { return nil }
            let hitches = done.hitches == 1 ? "1 hitch" : "\(done.hitches) hitches"
            return ImageAttachment(capture: .init(kind: .performance, file: done.url, label: Self.clock(done.duration) + " · " + hitches),
                                   thumbnail: Self.chart(done.frames, duration: done.duration, hitches: hitches))
        }
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The screen's top, wide enough for the field's tray to show, with a
    /// play badge and the recording's length.
    private static func badge(_ poster: UIImage, text: String, symbol: String) -> UIImage {
        let size = CGSize(width: 200, height: 160)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let height = size.width * poster.size.height / max(1, poster.size.width)
            poster.draw(in: CGRect(x: 0, y: -height * 0.06, width: size.width, height: height))
            let font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.white])
            let icon = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            let width = label.size().width + 32
            let pill = CGRect(x: 8, y: size.height - 34, width: width, height: 26)
            UIColor.black.withAlphaComponent(0.6).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: 13).fill()
            icon?.draw(in: CGRect(x: pill.minX + 8, y: pill.midY - 6, width: 12, height: 12))
            label.draw(at: CGPoint(x: pill.minX + 24, y: pill.midY - label.size().height / 2))
        }
    }

    /// Each frame's time as a bar, late frames in crimson, on paper.
    private static func chart(_ frames: [Double], duration: Double, hitches: String) -> UIImage {
        let size = CGSize(width: 220, height: 160)
        return UIGraphicsImageRenderer(size: size).image { context in
            Theme.paper.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let plot = CGRect(x: 10, y: 40, width: size.width - 20, height: size.height - 52)
            let gaps = zip(frames.dropFirst(), frames).map { $0 - $1 }
            let period = gaps.sorted().dropFirst(gaps.count / 2).first ?? 1.0 / 60
            let ceiling = max(period * 6, 0.1)
            let columns = Int(plot.width / 2)
            var worst = [Double](repeating: 0, count: max(1, columns))
            for (index, gap) in gaps.enumerated() {
                let column = min(columns - 1, Int(frames[index + 1] / max(duration, 0.001) * Double(columns)))
                if column >= 0 { worst[column] = max(worst[column], gap) }
            }
            for (column, gap) in worst.enumerated() where gap > 0 {
                let height = max(1.5, plot.height * min(1, gap / ceiling))
                (gap > period * 1.5 ? Theme.failure : UIColor.tertiaryLabel).setFill()
                UIBezierPath(roundedRect: CGRect(x: plot.minX + CGFloat(column) * 2, y: plot.maxY - height, width: 1.5, height: height),
                             cornerRadius: 0.75).fill()
            }
            // Top left, clear of the field's remove button at the top right.
            let title = NSMutableAttributedString(string: hitches, attributes: [
                .font: Theme.font(.subheadline, 15, .semibold), .foregroundColor: UIColor.label])
            title.append(NSAttributedString(string: "  " + clock(duration), attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: UIColor.secondaryLabel]))
            title.draw(at: CGPoint(x: 10, y: 10))
        }
    }
}
#endif
