import AVFoundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The message field's add menu: photos and videos from the library, or a new
/// photo from the camera where the app may use it.
@MainActor
final class AttachmentPicker: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private weak var host: UIViewController?
    private let onAttachment: (ImageAttachment) -> Void

    init(host: UIViewController, onAttachment: @escaping (ImageAttachment) -> Void) {
        self.host = host
        self.onAttachment = onAttachment
    }

    var menu: UIMenu {
        var actions = [UIAction(title: "Photo Library", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.pickPhotos() }]
        // An app hosting the overlay may not declare camera use; asking anyway would end it.
        if UIImagePickerController.isSourceTypeAvailable(.camera),
           Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil {
            actions.append(UIAction(title: "Camera", image: UIImage(systemName: "camera")) { [weak self] _ in self?.takePhoto() })
        }
        return UIMenu(children: actions)
    }

    private func pickPhotos() {
        guard let host, host.presentedViewController == nil else { return }
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 10
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        host.present(picker, animated: true)
    }

    private func takePhoto() {
        guard let host, host.presentedViewController == nil else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        host.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        Task {
            for result in results {
                if let attachment = await Self.attachment(from: result.itemProvider) { onAttachment(attachment) }
            }
        }
    }

    /// A picture or video from the library, the pasteboard or a drop, ready
    /// for the field; nil when it is neither.
    nonisolated static func attachment(from provider: NSItemProvider) async -> ImageAttachment? {
        if let movie = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .movie) == true }) {
            return await video(from: provider, type: movie)
        }
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        let image = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in continuation.resume(returning: object as? UIImage) }
        }
        return image.flatMap { ImageAttachment($0) }
    }

    /// Whether these types include something `attachment(from:)` takes.
    nonisolated static func holdsMedia(_ types: [String]) -> Bool {
        types.contains { UTType($0).map { $0.conforms(to: .movie) || $0.conforms(to: .image) } ?? false }
    }

    /// The video copied out of the provider (its file only lives for the
    /// callback), with its first frame as the poster.
    private nonisolated static func video(from provider: NSItemProvider, type: String) async -> ImageAttachment? {
        let file: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("video-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: copy)) == nil ? nil : copy)
            }
        }
        guard let file else { return nil }
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        guard let duration = try? await asset.load(.duration), let poster = try? await generator.image(at: .zero).image else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return ImageAttachment(video: file, poster: UIImage(cgImage: poster), duration: duration.seconds, name: "Video")
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage, let attachment = ImageAttachment(image) { onAttachment(attachment) }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
}
