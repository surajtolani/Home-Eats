import Foundation
import SwiftData

/// A specific brand/product choice for a generic grocery item (e.g. the
/// generic item "milk" might have a preferred ProductOption of
/// "Organic Valley Whole Milk, half gallon"). Keeping a photo alongside the
/// choice means whoever ends up shopping — even if they didn't plan the
/// list — can visually confirm they're grabbing the right thing.
@Model
final class ProductOption {
    @Attribute(.unique) var id: UUID
    /// Normalized generic item name this option belongs to, e.g. "milk".
    var genericItemName: String
    var brandName: String
    var details: String?
    /// A bundled asset name (preferred) for sample/library items.
    var photoAssetName: String?
    /// A user-captured photo, stored inline. Small enough (thumbnail-sized,
    /// resized on capture) that keeping it in the SwiftData store is fine
    /// for a local-first app.
    @Attribute(.externalStorage) var photoData: Data?
    var isPreferred: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        genericItemName: String,
        brandName: String,
        details: String? = nil,
        photoAssetName: String? = nil,
        photoData: Data? = nil,
        isPreferred: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.genericItemName = genericItemName.lowercased()
        self.brandName = brandName
        self.details = details
        self.photoAssetName = photoAssetName
        self.photoData = photoData
        self.isPreferred = isPreferred
        self.createdAt = createdAt
    }

    var hasPhoto: Bool { photoAssetName != nil || photoData != nil }
}
