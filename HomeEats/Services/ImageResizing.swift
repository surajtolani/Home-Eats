import UIKit

/// Keeps product photos small before they land in SwiftData: this is a
/// local-first app, so every photo adds to the on-device store size (and,
/// later, sync payload), and a shopping-list thumbnail never needs to be
/// full resolution.
enum ImageResizing {
    static func downsized(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // Always redraws through a graphics context — even when `scale`
        // rounds to 1 and the size doesn't actually change. This used to
        // short-circuit straight to `image.jpegData(...)` in that case,
        // which only *tags* the image's orientation as EXIF metadata
        // rather than physically rotating its pixels; a camera capture
        // whose `imageOrientation` wasn't already `.up` could come out
        // sideways wherever that tag isn't carefully honored. Drawing
        // through `UIGraphicsImageRenderer` bakes the correct orientation
        // into the actual pixel data instead, regardless of size.
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

extension UIImage {
    /// Bakes this image's orientation into its actual pixel data, returning
    /// an image whose `imageOrientation` is always `.up` — redraws through
    /// a graphics context rather than relying on every downstream consumer
    /// (a resize, a thumbnail, an intermediate JPEG encode/decode) to
    /// correctly respect the original orientation metadata. Cheap no-op
    /// when it's already `.up`.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
