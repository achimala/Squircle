#if DEBUG
import UIKit

/// Opt-in development instrumentation, absent from signed Release builds.
/// Records main-run-loop display cadence, not a claim about physical-device FPS.
@MainActor
final class MotionAudit: NSObject {
    static let shared = MotionAudit()
    private var link: CADisplayLink?
    private var times: [Double] = []
    private var name = ""
    private var generation = UUID()

    func note(_ event: String, values: [String: Any]) {
        guard ProcessInfo.processInfo.arguments.contains("--motion-audit"),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = directory.appendingPathComponent("gesture-audit.json")
        var records = (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        records.append(["event": event, "timestamp": Date().timeIntervalSince1970, "values": values])
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: path, options: .atomic) }
    }

    func begin(_ name: String, duration: Double = 1.1) {
        guard ProcessInfo.processInfo.arguments.contains("--motion-audit") else { return }
        finish()
        self.name = name; times = []; generation = UUID()
        let this = generation
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common); self.link = link
        DispatchQueue.main.asyncAfter(deadline: .now()+duration) { [weak self] in
            guard self?.generation == this else { return }; self?.finish()
        }
    }
    @objc private func frame(_ link: CADisplayLink) { times.append(link.timestamp) }
    private func finish() {
        guard link != nil else { return }
        link?.invalidate(); link = nil
        let intervals = zip(times.dropFirst(), times).map { ($0-$1)*1000 }
        guard !intervals.isEmpty, let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = directory.appendingPathComponent("motion-audit.json")
        var records = (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        records.append(["transition":name,"timestamp":Date().timeIntervalSince1970,"interval_ms":intervals])
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: path, options: .atomic) }
    }
}
#endif
