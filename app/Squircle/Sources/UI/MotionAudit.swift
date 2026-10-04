#if DEBUG
import UIKit

/// Opt-in development instrumentation, absent from signed Release builds.
/// Records main-run-loop display cadence and the main-thread time spent
/// driving each transition frame; not a claim about physical-device FPS.
@MainActor
final class MotionAudit: NSObject {
    static let shared = MotionAudit()
    private let enabled = ProcessInfo.processInfo.arguments.contains("--motion-audit")
    private var link: CADisplayLink?
    private var times: [Double] = []
    private var workMilliseconds: [Double] = []
    private var name = ""
    private var generation = UUID()

    func note(_ event: String, values: [String: Any]) {
        guard enabled else { return }
        append(["event": event, "timestamp": Date().timeIntervalSince1970, "values": values], to: "gesture-audit.json")
    }

    func begin(_ name: String, duration: Double = 1.1) {
        guard enabled else { return }
        finish()
        self.name = name
        times = []
        workMilliseconds = []
        generation = UUID()
        let this = generation
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] link in self?.times.append(link.timestamp) },
                                 selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard self?.generation == this else { return }
            self?.finish()
        }
    }

    /// Main-thread milliseconds spent applying one animation frame.
    func work(_ milliseconds: Double) {
        guard enabled, link != nil else { return }
        workMilliseconds.append(milliseconds)
    }

    private func finish() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
        guard !intervals.isEmpty else { return }
        append(["transition": name, "timestamp": Date().timeIntervalSince1970, "interval_ms": intervals,
                "work_ms": workMilliseconds], to: "motion-audit.json")
    }

    private func append(_ record: [String: Any], to file: String) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = directory.appendingPathComponent(file)
        var records = (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        records.append(record)
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path, options: .atomic)
        }
    }
}
#endif
