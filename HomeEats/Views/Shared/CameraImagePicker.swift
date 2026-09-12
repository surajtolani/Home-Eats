import SwiftUI
import UIKit

/// Camera capture with Apple's own built-in crop/rotate step
/// (`allowsEditing`), wrapped for SwiftUI. There's no SwiftUI-native camera
/// API, so this goes through `UIImagePickerController` same as it always
/// has — `PhotosPicker` (used for the library) has no camera source at all.
///
/// `allowsEditing` matters for more than letting someone trim a photo down
/// to just the part they want (e.g. cropping a whole-page cookbook photo
/// down to just the dish's own picture): the edit step's crop is applied to
/// an already-upright preview, so the result comes back correctly oriented
/// regardless of how the phone was held for the shot — a landscape photo of
/// a two-page spread doesn't come back "sideways."
struct CameraImagePicker: UIViewControllerRepresentable {
    var onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void

        init(onCapture: @escaping (Data?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // The edited (cropped) image when the user adjusted it, else the
            // original capture as-is.
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            onCapture(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
