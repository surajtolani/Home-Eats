import SwiftUI
import UIKit

/// An image loaded from this app's own backend with the signed-in user's
/// token attached. Used instead of `AsyncImage` for the two image routes
/// (`/restaurants/photo` and `/recipes/image-proxy`), which require a
/// signed-in user because each load can cost money or bandwidth, and
/// `AsyncImage` has no way to send an `Authorization` header.
///
/// Shows `placeholder` while loading, when `url` is nil, and when the load
/// fails for any reason (including a 401: signing out is
/// `AccountsAPIClient`'s job, not an image's). Loads are cancelled when the
/// view disappears or `url` changes.
struct RemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        // Start with an already-cached image so scrolling back to a row
        // doesn't flash the placeholder.
        _uiImage = State(initialValue: url.flatMap(RemoteImageLoader.cachedImage(for:)))
    }

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                uiImage = nil
                return
            }
            if let cached = RemoteImageLoader.cachedImage(for: url) {
                uiImage = cached
                return
            }
            uiImage = nil
            let loaded = await RemoteImageLoader.load(url)
            if Task.isCancelled { return }
            uiImage = loaded
        }
    }
}

/// Fetching and caching for `RemoteImage`. Decoded images are kept in
/// memory; responses are also cached on disk by `URLSession.shared`'s
/// `URLCache`, following the server's `Cache-Control` header.
enum RemoteImageLoader {
    private static let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    static func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    /// The image at `url`, or nil if there's no signed-in user, the request
    /// fails, the response isn't a 2xx, or the bytes aren't an image.
    static func load(_ url: URL) async -> UIImage? {
        guard let token = KeychainTokenStore.readToken() else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data)
            else { return nil }
            memoryCache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            return nil
        }
    }
}
