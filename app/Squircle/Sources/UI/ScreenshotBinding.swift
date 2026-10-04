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
    /// Long edge in pixels; the gallery device never displays more than this.
    nonisolated static let maximumPixelHeight: CGFloat = 1500

    init(id: String, stage: DeviceStage) {
        self.id = id
        self.stage = stage
    }

    deinit { loading?.cancel() }

    func update(model: SquircleModel, project: AppProject) {
        let metadata = model.metadata(for: project)
        // A registered app owns its publication state. A missing publication
        // must not be silently replaced by a potentially older build image.
        let build = metadata == nil ? model.builds(for: project).first(where: { $0.previewAvailable }) : nil
        let key = metadata.flatMap { record in record.preview.map { "app:\(record.id):\($0.id)" } }
            ?? build.map { "build:\($0.id):\($0.previewCapturedAt?.timeIntervalSince1970 ?? 0)" }
            ?? "missing"
        guard key != sourceKey else { return }
        sourceKey = key
        loading?.cancel()
        guard key != "missing" else {
            stage?.setScreen(.missing, for: id)
            return
        }
        // Keep the previous capture visible until its replacement is ready.
        if stage?.screen(for: id).hasScreenshot != true { stage?.setScreen(.off, for: id) }
        loading = Task { [weak self, weak model] in
            guard let model else { return }
            do {
                let data: Data
                if let metadata, metadata.preview != nil { data = try await model.previewData(for: metadata) }
                else if let build { data = try await model.previewData(for: build) }
                else { return }
                let image = await Self.decode(data)
                guard let self, !Task.isCancelled, self.sourceKey == key else { return }
                guard let image else { throw CocoaError(.fileReadCorruptFile) }
                self.stage?.setScreen(.image(image), for: self.id)
            } catch {
                guard let self, !Task.isCancelled, self.sourceKey == key else { return }
                self.stage?.setScreen(.unavailable, for: self.id)
                self.sourceKey = "" // Retry on the next metadata refresh.
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
