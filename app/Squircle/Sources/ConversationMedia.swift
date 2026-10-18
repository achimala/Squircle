import AVFoundation
import UIKit

/// The open conversation's pictures, recordings and Mac files: downloaded
/// once into the image and video caches, through Squircle's media routes or
/// short-lived URLs T3 signs. `SquircleModel` says which thread is open.
@MainActor
final class ConversationMedia {
    private let client: SquircleClient?
    private let gateway: T3Gateway?
    private let base: URL?
    private let thread: () -> String?
    private let message: (String) -> ChatMessage?
    /// The open thread's published media (recordings and clips).
    private let published: () -> [JSONValue]

    init(client: SquircleClient?, gateway: T3Gateway?, base: URL?, thread: @escaping () -> String?,
         message: @escaping (String) -> ChatMessage?, published: @escaping () -> [JSONValue]) {
        self.client = client
        self.gateway = gateway
        self.base = base
        self.thread = thread
        self.message = message
        self.published = published
    }

    /// Cellular, a personal hotspot or Low Data Mode.
    var metered = false
    /// A turn's recording plays inline once downloaded. On a metered
    /// network it shows its poster and downloads when tapped (a long session
    /// is well over 100 MB); an older recording without a poster still
    /// downloads by itself if it's small.
    func autoLoadsRecording(_ id: String) -> Bool {
        guard metered else { return true }
        guard posterless.contains(id) else { return false }
        return (published().first { $0["id"].string == id }?["bytes"].double ?? .infinity) <= 10_000_000
    }
    /// The poster Squircle took when it stopped recording, if any.
    func recordingPoster(_ id: String) async -> Data? {
        let key = "poster:" + id
        if let data = StepImages.data(for: key, index: 0) { return data }
        guard !posterless.contains(id), let client, let thread = thread() else { return nil }
        do {
            let data = try await client.mediaPoster(threadID: thread, id: id)
            StepImages.set(data, for: key, index: 0)
            return data
        } catch ClientError.http(_, 404) { posterless.insert(id); return nil }
        catch { return nil }
    }
    /// Recordings made before Squircle took posters.
    private(set) var posterless = Set<String>()
    /// A recording or clip as a file to play, downloaded once into the
    /// media cache, streamed to disk off the main actor.
    func loadVideo(_ stepID: String) async -> URL? {
        if let url = StepVideos.url(for: stepID) { return url }
        if stepID.hasPrefix("file:") {
            let path = String(stepID.dropFirst("file:".count))
            guard let gateway, let url = await mediaFileURL(path)?.url else { return nil }
            return await StepVideos.file(for: stepID) { await gateway.http.authorizedDownload(url, to: $0) }
        }
        let id = String(stepID.dropFirst("media:".count))
        guard let client, let thread = thread() else { return nil }
        return await StepVideos.file(for: stepID) { destination in
            (try? await client.downloadMedia(threadID: thread, id: id, to: destination)) != nil
        }
    }
    func loadStepImage(_ stepID: String, index: Int, attachment: String? = nil) async -> Data? {
        if let data = StepImages.data(for: stepID, index: index) { return data }
        if let attachment {
            guard let data = await attachmentData(attachment) else { return nil }
            StepImages.set(data, for: stepID, index: index)
            return data
        }
        if stepID.hasPrefix("file:") {
            var data: Data?
            if MediaFiles.isVideo(stepID) {
                if let video = await loadVideo(stepID) { data = await Self.poster(of: video) }
            } else {
                data = await mediaFileData(String(stepID.dropFirst("file:".count)))
            }
            if let data, let image = UIImage(data: data) {
                MediaFiles.sizes[stepID] = image.size
                StepImages.set(data, for: stepID, index: index)
            }
            return data
        }
        if stepID.hasPrefix("media:") {
            let message = message(stepID)
            var data: Data?
            let id = String(stepID.dropFirst("media:".count))
            if message?.videoID != nil, let poster = await recordingPoster(id) {
                data = poster
            } else if message?.videoID != nil, autoLoadsRecording(id), let url = await loadVideo(stepID) {
                data = await Self.poster(of: url)
            } else if message?.videoID != nil {
                data = nil
            } else if let client, let thread = thread() {
                data = try? await client.mediaFile(threadID: thread, id: String(stepID.dropFirst("media:".count)))
            }
            if let data { StepImages.set(data, for: stepID, index: index) }
            return data
        }
        guard let client, let thread = thread(),
              let data = try? await client.stepImage(threadID: thread, callID: stepID, index: index) else { return nil }
        StepImages.set(data, for: stepID, index: index)
        return data
    }
    /// An image sent with a message, through a short-lived URL T3 signs.
    private func attachmentData(_ id: String) async -> Data? {
        guard let url = await signedURL(["_tag": "attachment", "attachmentId": .string(id)])?.url else { return nil }
        return await signedData(url)
    }
    /// The pixel size of a picture the agent's Markdown shows, from T3
    /// before its bytes arrive, so its place in the conversation is reserved.
    func mediaSize(_ stepID: String) async -> CGSize? {
        if let size = MediaFiles.sizes[stepID] { return size }
        guard !MediaFiles.isVideo(stepID), let size = await mediaFileURL(String(stepID.dropFirst("file:".count)))?.size else { return nil }
        MediaFiles.sizes[stepID] = size
        return size
    }
    /// A file on the Mac the agent's Markdown shows. T3 signs a short-lived
    /// URL for it as it does for its own web client, and only for pictures,
    /// video and documents it can preview.
    private func mediaFileURL(_ path: String) async -> (url: URL, size: CGSize?)? {
        if let signed = MediaFiles.urls[path], signed.expires > .now.addingTimeInterval(30) { return (signed.url, MediaFiles.sizes["file:" + path]) }
        guard let thread = thread(),
              let signed = await signedURL(["_tag": "media-file", "threadId": .string(thread), "path": .string(path)]) else { return nil }
        if let expires = signed.expires { MediaFiles.urls[path] = (signed.url, expires) }
        return (signed.url, signed.size)
    }
    private func mediaFileData(_ path: String) async -> Data? {
        guard let url = await mediaFileURL(path)?.url else { return nil }
        return await signedData(url)
    }
    private func signedURL(_ resource: JSONValue) async -> (url: URL, expires: Date?, size: CGSize?)? {
        guard let gateway, let base,
              let asset = try? await gateway.call("assets.createUrl", ["resource": resource]),
              let relative = asset["relativeUrl"].string, let url = T3HTTP.assetURL(relative, base: base) else { return nil }
        let size = asset["imageDimensions"]["width"].double.flatMap { width in
            asset["imageDimensions"]["height"].double.map { CGSize(width: width, height: $0) }
        }
        return (url, asset["expiresAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) }, size)
    }
    private func signedData(_ url: URL) async -> Data? {
        await gateway?.http.authorizedData(url)
    }
    nonisolated static func poster(of url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
    }
}
