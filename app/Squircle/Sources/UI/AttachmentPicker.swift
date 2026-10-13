import PhotosUI
import UIKit

/// The message field's add menu: photos from the library, or a new one from
/// the camera where the app may use it.
@MainActor
final class AttachmentPicker: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private weak var host: UIViewController?
    private let onImage: (UIImage) -> Void

    init(host: UIViewController, onImage: @escaping (UIImage) -> Void) {
        self.host = host
        self.onImage = onImage
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
        config.filter = .images
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
                if let image = await Self.image(from: result.itemProvider) { onImage(image) }
            }
        }
    }

    private nonisolated static func image(from provider: NSItemProvider) async -> UIImage? {
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in continuation.resume(returning: object as? UIImage) }
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage { onImage(image) }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
}
