import UIKit

/// Keeps product photos small before they land in SwiftData: this is a
/// local-first app, so every photo adds to the on-device store size (and,
/// later, sync payload), and a shopping-list thumbnail never needs to be
/// full resolution.
enum ImageResizing {
    static func downsized(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        guard scale < 1 else {
            return image.jpegData(compressionQuality: 0.85)
        }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
