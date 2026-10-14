import CryptoKit
import UIKit

/// Binds the Mac's published screenshot artifact to one device on the stage.
/// The artifact ID changes on publication, so metadata refreshes swap the
/// texture without rebuilding anything. Decoding and downsampling happen off
/// the main thread; only the finished bitmap reaches SceneKit. The last
/// capture shown is kept on disk, so a launch shows it at once while the
/// newest is fetched, and skips the fetch when nothing has changed.
@MainActor
final class ScreenshotBinding {
    private let id: String
    private weak var stage: DeviceStage?
    private var sourceKey = ""
    private var loading: Task<Void, Never>?
    /// The source key of the capture on disk, once it has been read.
    private var cachedKey: String?
    private var restoring: Task<Void, Never>?
    /// Called after the device's screen changes.
    var onChange: (() -> Void)?
    /// Long edge in pixels; the gallery device never displays more than this.
    nonisolated static let maximumPixelHeight: CGFloat = 1500

    init(id: String, stage: DeviceStage) {
        self.id = id
        self.stage = stage
    }

    deinit { loading?.cancel(); restoring?.cancel() }

    /// The Mac catalog's published preview wins; then the newest build
    /// capture; then the newest simulator screenshot T3 took in the app's
    /// threads (the Mac picks only those, never an image an agent read).
    /// Only an app with none of these shows "No screenshot yet".
    func update(model: SquircleModel, project: AppProject) {
        let metadata = model.metadata(for: project).flatMap { $0.preview == nil ? nil : $0 }
        let build = metadata == nil ? model.builds(for: project).first(where: { $0.previewAvailable }) : nil
        // Threads move on often; look for a newer capture at most every few minutes.
        let latest = model.sessions(for: project).map(\.updatedAt).max()
        let version = latest.map { String(Int($0.timeIntervalSince1970 / 300)) } ?? "none"
        let published: String? = metadata.flatMap { record in record.preview.map { "app:\(record.id):\($0.id)" } }
        let captured: String? = build.map { "build:\($0.id):\($0.previewCapturedAt?.timeIntervalSince1970 ?? 0)" }
        let threads: String = latest == nil ? "missing" : Self.capturePrefix + "\(project.id):\(version)"
        let key = published ?? captured ?? threads
        guard key != sourceKey else { return }
        sourceKey = key
        loading?.cancel()
        // The capture on disk shows first; with the same key it is already the latest.
        guard let cachedKey else {
            restore { [weak self, weak model] in
                guard let self, let model else { return }
                sourceKey = ""
                update(model: model, project: project)
            }
            return
        }
        if cachedKey == key, stage?.screen(for: id).hasScreenshot == true { return }
        guard key != "missing" else {
            if stage?.screen(for: id).hasScreenshot != true { stage?.setScreen(.missing, for: id) }
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
                self.stage?.setScreen(.image(image), for: self.id)
                self.cachedKey = key
                Self.store(data, key: key, for: self.id)
                self.onChange?()
            } catch {
                guard let self, !Task.isCancelled, self.sourceKey == key else { return }
                // No capture in the threads yet is the honest "missing" state.
                if self.stage?.screen(for: self.id).hasScreenshot != true {
                    self.stage?.setScreen(key.hasPrefix(Self.capturePrefix) ? .missing : .unavailable, for: self.id)
                }
                self.onChange?()
                if !key.hasPrefix(Self.capturePrefix) { self.sourceKey = "" } // Retry on the next metadata refresh.
            }
        }
    }

    /// Shows the capture on disk, if any, then continues.
    private func restore(then next: @escaping () -> Void) {
        guard restoring == nil else { return }
        let id = self.id
        restoring = Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { Self.load(for: id) }.value
            var image: UIImage?
            if let saved { image = await Self.decode(saved.data) }
            guard let self, !Task.isCancelled else { return }
            restoring = nil
            cachedKey = saved?.key ?? ""
            // Saved before the Mac checked where thread images came from:
            // possibly a mockup an agent read, so never shown.
            if saved?.key.hasPrefix("t3:") == true { image = nil }
            if let image, stage?.screen(for: id).hasScreenshot != true {
                stage?.setScreen(.image(image), for: id)
                onChange?()
            }
            next()
        }
    }

    /// Keys of simulator captures from the app's threads.
    private static let capturePrefix = "capture:"

    nonisolated private static let directory: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Screenshots", isDirectory: true)

    nonisolated private static func file(for id: String) -> URL? {
        let name = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(name)
    }

    /// The key's length, the key, then the image bytes: one file, one write.
    nonisolated private static func load(for id: String) -> (key: String, data: Data)? {
        guard let url = file(for: id), let blob = try? Data(contentsOf: url), blob.count > 4 else { return nil }
        let length = Int(blob.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard blob.count > 4 + length, let key = String(data: blob.subdata(in: 4..<(4 + length)), encoding: .utf8) else { return nil }
        return (key, blob.subdata(in: (4 + length)..<blob.count))
    }

    /// The last write started for each app; the next waits for it, so the
    /// newest capture is always the one left on disk.
    private static var writes: [String: Task<Void, Never>] = [:]

    private static func store(_ data: Data, key: String, for id: String) {
        let previous = writes[id]
        writes[id] = Task.detached(priority: .utility) {
            await previous?.value
            guard let directory, let url = file(for: id) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let keyData = Data(key.utf8)
            var blob = withUnsafeBytes(of: UInt32(keyData.count).bigEndian) { Data($0) }
            blob.append(keyData)
            blob.append(data)
            try? blob.write(to: url, options: .atomic)
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
