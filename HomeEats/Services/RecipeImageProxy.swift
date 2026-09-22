import Foundation

/// Builds URLs that load an imported recipe's source-page photo through
/// this backend's proxy (`GET /recipes/image-proxy`) instead of straight
/// from wherever that page happens to host it — same "the app never talks
/// to a third party directly" reasoning `GooglePlacesService.photoURL(for:)`
/// already documents, just for an arbitrary imported URL instead of a
/// Google Places one. See that route's own doc comment in backend/index.js
/// for why this exists (a real, confirmed IP-logging/tracking-beacon
/// finding in a plain AsyncImage load).
enum RecipeImageProxy {
    private static let baseURLString = "https://home-eats-uqbp.onrender.com"

    /// Returns `nil` if the backend isn't configured or `originalURLString`
    /// isn't actually an http(s) URL — mirrors `SafeWebLink.url(from:)`'s
    /// own scheme check, so a non-web string never gets treated as if it
    /// might resolve to something.
    static func url(for originalURLString: String) -> URL? {
        guard !baseURLString.isEmpty, let base = URL(string: baseURLString) else { return nil }
        guard let original = URL(string: originalURLString),
              let scheme = original.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }

        var components = URLComponents(
            url: base.appendingPathComponent("recipes/image-proxy"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "url", value: originalURLString)]
        return components?.url
    }
}
