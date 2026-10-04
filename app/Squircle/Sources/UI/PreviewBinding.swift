import UIKit

/// Binds the Mac's published screenshot artifact to a live 3D display. The
/// artifact ID changes on publication, so background metadata refresh replaces
/// the texture without rebuilding the scene or inventing preview content.
@MainActor
final class PreviewBinding {
    private weak var preview: DevicePreview?
    private var sourceKey = ""
    private var loading: Task<Void, Never>?

    init(_ preview: DevicePreview) { self.preview = preview }
    deinit { loading?.cancel() }

    func update(model: SquircleModel, project: AppProject) {
        let metadata = model.metadata(for: project)
        // A registered app owns its publication state. A missing publication
        // must not be silently replaced by a potentially older build image.
        let build = metadata == nil ? model.builds(for: project).first(where: { $0.previewAvailable }) : nil
        let key = metadata?.preview.map { "app:\(metadata!.id):\($0.id)" }
            ?? build.map { "build:\($0.id):\($0.previewCapturedAt?.timeIntervalSince1970 ?? 0)" }
            ?? "missing"
        guard key != sourceKey else { return }
        sourceKey = key; loading?.cancel()
        guard key != "missing" else {
            preview?.setScreenshot(nil)
            preview?.setPreviewStatus("No screenshot published")
            return
        }
        if preview?.hasScreenshot != true { preview?.setPreviewStatus("Loading preview…") }
        loading = Task { [weak self, weak model] in
            guard let self, let model else { return }
            do {
                let data: Data
                if let metadata, metadata.preview != nil { data = try await model.previewData(for: metadata) }
                else if let build { data = try await model.previewData(for: build) }
                else { return }
                guard !Task.isCancelled, self.sourceKey == key else { return }
                guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                self.preview?.setScreenshot(image)
                self.preview?.accessibilityLabel = metadata?.preview?.caption.isEmpty == false
                    ? metadata!.preview!.caption : "Captured app screenshot"
            } catch {
                guard !Task.isCancelled, self.sourceKey == key else { return }
                self.preview?.setScreenshot(nil)
                self.preview?.setPreviewStatus("Preview unavailable")
                self.sourceKey = "" // Retry on the next metadata refresh.
            }
        }
    }
}
