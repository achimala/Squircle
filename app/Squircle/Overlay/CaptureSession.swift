#if SQUIRCLE_OVERLAY || DEBUG
import UIKit

/// What a recorder hands over when it stops.
enum CaptureOutput {
    /// A video; its thumbnail is the app as it looked when it stopped.
    case screen(url: URL, duration: Double)
    case performance(url: URL, duration: Double, gaps: [FrameGap], hitches: Int)

    var url: URL {
        switch self {
        case .screen(let url, _), .performance(let url, _, _, _): url
        }
    }
}

/// A running screen or performance recorder.
@MainActor
protocol CaptureProducer: AnyObject {
    /// Stops recording, then finishes its file. Stopped on every path,
    /// whatever it returns; nil when it has no file (it removes its own).
    func finish() async -> CaptureOutput?
    /// Stops at once and removes whatever it wrote.
    func cancel()
}

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
    /// A recording owns its producer from start until it is finished or
    /// cancelled; nothing else holds one.
    private enum State {
        case idle
        case recording(Recording, CaptureProducer, timeout: Task<Void, Never>)
        case stopping(Recording, CaptureProducer)
    }

    static let limit: Duration = .seconds(60)
    private var state = State.idle
    private let make: @MainActor (Kind, UIWindow) -> CaptureProducer?
    /// Called when a recording reaches `limit` and should stop.
    var onLimit: (() -> Void)?
    /// Called when a stop begins: the bubble shows it finishing.
    var onStopping: (() -> Void)?

    init(make: @escaping @MainActor (Kind, UIWindow) -> CaptureProducer? = CaptureSession.recorder) {
        self.make = make
    }

    /// Recording or finishing: the bubble is its stop button until it is done.
    var recording: Recording? {
        switch state {
        case .idle: nil
        case .recording(let recording, _, _), .stopping(let recording, _): recording
        }
    }
    var isStopping: Bool { if case .stopping = state { true } else { false } }

    static func recorder(_ kind: Kind, below overlay: UIWindow) -> CaptureProducer? {
        switch kind {
        case .screen: ScreenRecorder(below: overlay)
        case .performance: PerfRecorder(below: overlay)
        }
    }

    func start(_ kind: Kind, below overlay: UIWindow) -> Bool {
        guard case .idle = state, let producer = make(kind, overlay) else { return false }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled else { return }
            self?.onLimit?()
        }
        state = .recording(Recording(kind: kind, started: .now), producer, timeout: timeout)
        return true
    }

    /// Stops the recording; returns it ready for the message field, or nil
    /// (nothing recorded, or cancelled meanwhile; its file is gone).
    /// `snapshot` is the app as it looks now: a screen recording's thumbnail.
    func stop(snapshot: UIImage?) async -> ImageAttachment? {
        guard case .recording(let recording, let producer, let timeout) = state else { return nil }
        timeout.cancel()
        state = .stopping(recording, producer)
        onStopping?()
        let output = await producer.finish()
        // Cancelled while it finished: the owner has gone.
        guard case .stopping(_, let current) = state, current === producer else {
            output.map { try? FileManager.default.removeItem(at: $0.url) }
            return nil
        }
        state = .idle
        switch output {
        case nil:
            return nil
        case .screen(let url, let duration):
            guard let poster = snapshot else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return ImageAttachment(video: url, poster: poster, duration: duration)
        case .performance(let url, let duration, let gaps, let hitches):
            let count = hitches == 1 ? "1 hitch" : "\(hitches) hitches"
            return ImageAttachment(capture: .init(kind: .performance, file: url, label: Elapsed.clock(duration.rounded()) + " · " + count),
                                   thumbnail: Self.chart(gaps, duration: duration, hitches: count))
        }
    }

    /// The overlay is going away: stops any recording at once and removes
    /// its file. A stop in progress returns nil.
    func cancel() {
        switch state {
        case .idle: return
        case .recording(_, let producer, let timeout):
            timeout.cancel()
            producer.cancel()
        case .stopping:
            // Already stopped; `stop` removes the file when it finishes.
            break
        }
        state = .idle
    }

    /// Each frame's time as a bar, late frames (as the recording counted
    /// them) in the failure colour, on paper.
    private static func chart(_ gaps: [FrameGap], duration: Double, hitches: String) -> UIImage {
        let size = CGSize(width: 220, height: 160)
        return UIGraphicsImageRenderer(size: size).image { context in
            Theme.paper.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let plot = CGRect(x: Theme.Space.rowPad, y: 40, width: size.width - 2 * Theme.Space.rowPad, height: size.height - 52)
            let periods = gaps.map(\.period).sorted()
            let period = periods.dropFirst(periods.count / 2).first ?? 1.0 / 60
            let ceiling = max(period * 6, 0.1)
            let columns = Int(plot.width / 2)
            var worst = [(gap: Double, late: Bool)](repeating: (0, false), count: max(1, columns))
            for gap in gaps {
                let column = min(columns - 1, Int(gap.end / max(duration, 0.001) * Double(columns)))
                guard column >= 0 else { continue }
                worst[column] = (max(worst[column].gap, gap.length), worst[column].late || gap.late)
            }
            for (column, (gap, late)) in worst.enumerated() where gap > 0 {
                let height = max(1.5, plot.height * min(1, gap / ceiling))
                (late ? Theme.failure : UIColor.tertiaryLabel).setFill()
                UIBezierPath(roundedRect: CGRect(x: plot.minX + CGFloat(column) * 2, y: plot.maxY - height, width: 1.5, height: height),
                             cornerRadius: 0.75).fill()
            }
            // Top left, clear of the field's remove button at the top right.
            let title = NSMutableAttributedString(string: hitches, attributes: [
                .font: Theme.Text.lineStrong, .foregroundColor: UIColor.label])
            title.append(NSAttributedString(string: "  " + Elapsed.clock(duration.rounded()), attributes: [
                .font: Theme.Text.mono, .foregroundColor: UIColor.secondaryLabel]))
            title.draw(at: CGPoint(x: Theme.Space.rowPad, y: Theme.Space.rowPad))
        }
    }
}
#endif
