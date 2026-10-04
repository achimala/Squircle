import CrashReporter
import Darwin
import Foundation

@MainActor
protocol CrashReporting {
    func recover(into queue: PersistentEventQueue) throws -> Bool
    func enable(buildID: String) throws
}

@MainActor
final class CrashCapture: CrashReporting {
    struct Context: Codable {
        let buildID: String
        let eventID: String
    }

    private let reporter: PLCrashReporter?
    private(set) var enabled = false

    init() {
        let config = PLCrashReporterConfig(signalHandlerType: .mach, symbolicationStrategy: [])
        reporter = PLCrashReporter(configuration: config)
    }

    func recover(into queue: PersistentEventQueue) throws -> Bool {
        guard let reporter else { throw ProbeError("Could not initialize PLCrashReporter.") }
        guard reporter.hasPendingCrashReport() else { return false }
        let data = try reporter.loadPendingCrashReportDataAndReturnError()
        let report = try PLCrashReport(data: data)
        guard let metadata = report.customData,
              let context = try? JSONDecoder().decode(Context.self, from: metadata),
              let text = PLCrashReportTextFormatter.stringValue(for: report, with: PLCrashReportTextFormatiOS) else {
            throw ProbeError("Pending crash lacks build metadata or cannot be decoded; retained on device.")
        }
        let event = DiagnosticEvent(buildID: context.buildID, kind: .crash, message: text,
                                    eventID: context.eventID,
                                    timestamp: Int(report.systemInfo.timestamp.timeIntervalSince1970),
                                    attributes: ["reporter": "PLCrashReporter 1.12.2", "format": "apple-text"])
        try queue.append(event)
        // Purge only after an atomic queue write. Stable event ID makes a retry idempotent.
        guard reporter.purgePendingCrashReport() else { throw ProbeError("Crash is queued, but original report could not be purged.") }
        return true
    }

    func enable(buildID: String) throws {
        guard !buildID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProbeError("A build ID is required before crash capture can start.")
        }
        guard let reporter else { throw ProbeError("Crash reporter unavailable.") }
        guard !reporter.hasPendingCrashReport() else { throw ProbeError("Recover the previous crash before enabling another capture.") }
        guard !Self.debuggerAttached else { throw ProbeError("Debugger attached. Stop Xcode and open the app manually to test crash capture.") }
        reporter.customData = try JSONEncoder().encode(Context(buildID: buildID, eventID: UUID().uuidString.lowercased()))
        if !enabled {
            try reporter.enableAndReturnError()
            enabled = true
        }
    }

    private static var debuggerAttached: Bool {
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&request, UInt32(request.count), &process, &length, nil, 0)
        return result == 0 && (process.kp_proc.p_flag & P_TRACED) != 0
    }
}
