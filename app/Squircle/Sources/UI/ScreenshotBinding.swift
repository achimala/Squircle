import UIKit

/// Binds the Mac's published screenshot artifact to one device on the stage.
/// The artifact ID changes on publication, so metadata refreshes swap the
/// texture without rebuilding anything. Decoding and downsampling happen off
/// the main thread; only the finished bitmap reaches SceneKit.
@MainActor
final class ScreenshotBinding {
    private let id: String
    private weak var stage: DeviceStage?
    private var sourceKey = ""
    private var loading: Task<Void, Never>?
    /// Called after the device's screen or ambient color changes.
    var onChange: (() -> Void)?
    /// Long edge in pixels; the gallery device never displays more than this.
    nonisolated static let maximumPixelHeight: CGFloat = 1500

    init(id: String, stage: DeviceStage) {
        self.id = id
        self.stage = stage
    }

    deinit { loading?.cancel() }

    /// The Mac catalog's published preview wins; then the newest build
    /// capture; then the newest real screenshot an agent took in the app's
    /// threads. Only an app with none of these shows "No screenshot yet".
    func update(model: SquircleModel, project: AppProject) {
        let metadata = model.metadata(for: project).flatMap { $0.preview == nil ? nil : $0 }
        let build = metadata == nil ? model.builds(for: project).first(where: { $0.previewAvailable }) : nil
        // Threads move on often; look for a newer capture at most every few minutes.
        let latest = model.sessions(for: project).map(\.updatedAt).max()
        let version = latest.map { String(Int($0.timeIntervalSince1970 / 300)) } ?? "none"
        let key = metadata.flatMap { record in record.preview.map { "app:\(record.id):\($0.id)" } }
            ?? build.map { "build:\($0.id):\($0.previewCapturedAt?.timeIntervalSince1970 ?? 0)" }
            ?? (latest == nil ? "missing" : "t3:\(project.id):\(version)")
        guard key != sourceKey else { return }
        sourceKey = key
        loading?.cancel()
        guard key != "missing" else {
            stage?.setScreen(.missing, for: id)
            stage?.setAmbientColor(nil, for: id)
            onChange?()
            return
        }
        // Keep the previous capture visible until its replacement is ready.
        if stage?.screen(for: id).hasScreenshot != true { stage?.setScreen(.off, for: id) }
        loading = Task { [weak self, weak model] in
            guard let model else { return }
            do {
                let data: Data
                if let metadata { data = try await model.previewData(for: metadata) }
                else if let build { data = try await model.previewData(for: build) }
                else { data = try await model.threadScreenshot(for: project, version: version) }
                let image = await Self.decode(data)
                guard let self, !Task.isCancelled, self.sourceKey == key else { return }
                guard let image else { throw CocoaError(.fileReadCorruptFile) }
                let color = await Task.detached { Theme.characteristicColor(of: image) }.value
                guard !Task.isCancelled, self.sourceKey == key else { return }
                self.stage?.setScreen(.image(image), for: self.id)
                self.stage?.setAmbientColor(color, for: self.id)
                self.onChange?()
            } catch {
                guard let self, !Task.isCancelled, self.sourceKey == key else { return }
                // No capture in the threads yet is the honest "missing" state.
                if self.stage?.screen(for: self.id).hasScreenshot != true {
                    self.stage?.setScreen(key.hasPrefix("t3:") ? .missing : .unavailable, for: self.id)
                }
                self.onChange?()
                if !key.hasPrefix("t3:") { self.sourceKey = "" } // Retry on the next metadata refresh.
            }
        }
    }

    nonisolated static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data), image.size.height > 0 else { return nil }
            let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            let factor = min(1, maximumPixelHeight / pixels.height)
            let target = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
            return image.preparingThumbnail(of: target) ?? image.preparingForDisplay() ?? image
        }.value
    }
}
