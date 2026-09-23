import Foundation

/// One organic result from the backend's `/recipes/web-search` (Google's
/// Custom Search JSON API server-side — see that route's own doc comment
/// in backend/index.js). `title`/`sourceDomain` back `webResultCard`'s
/// `MediaTileRow` directly; `thumbnailURL` (when the search result actually
/// had one) goes through `RecipeImageProxy`, same as any other recipe photo.
struct RecipeWebSearchResult: Decodable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
    let thumbnailURL: String?
    let sourceDomain: String
}

enum RecipeWebSearchError: LocalizedError {
    case notConfigured
    case requestFailed
    case notSignedIn
    /// A `{ "error": "..." }` response the backend sent on purpose — same
    /// "surface it verbatim" reasoning as `ClaudeRecipeServiceError
    /// .serverMessage`'s own doc comment.
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This feature isn't available right now. Please try again later."
        case .requestFailed:
            return "Couldn't search the web right now. Check your connection and try again."
        case .notSignedIn:
            return "Sign in to search the web for recipes."
        case .serverMessage(let message):
            return message
        }
    }
}

/// Real web search for recipes — direct user request: the search bar under
/// Recipes should return local matches (My Recipes/Favorites/Library/
/// Shared) first, then actual results from the open web below them, not
/// AI-generated suggestions (`ClaudeRecipeService.recommendMeals` already
/// covers that, a different, ingredient-driven feature). This backend route
/// proxies Google's Custom Search JSON API — same "the app never holds a
/// paid API key itself" reasoning as `GooglePlacesService`/
/// `ClaudeRecipeService` — rather than the app calling a search API
/// directly. A result here is just a page title/thumbnail/link, not yet a
/// real recipe; `RecipesHomeView.webResultCard` opens it through the exact
/// same schema.org import pipeline as pasting a link
/// (`RecipeImportService`/`RecipeImportView.initialURL`), so it becomes a
/// full recipe the same way any imported URL does.
enum RecipeWebSearchService {
    /// Same backend/deployment as every other service in this app — kept as
    /// its own copy rather than a shared constant, same reasoning as
    /// `AccountsAPIClient.baseURLString`'s own doc comment.
    private static let baseURLString = "https://home-eats-uqbp.onrender.com"

    static var isConfigured: Bool { !baseURLString.isEmpty }

    static func search(query: String) async throws -> [RecipeWebSearchResult] {
        guard isConfigured, let base = URL(string: baseURLString) else {
            throw RecipeWebSearchError.notConfigured
        }
        guard let token = KeychainTokenStore.readToken() else {
            throw RecipeWebSearchError.notSignedIn
        }
        var components = URLComponents(
            url: base.appendingPathComponent("recipes/web-search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            throw RecipeWebSearchError.requestFailed
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Same free-tier-Render-cold-start reasoning as
        // `ClaudeRecipeService.post`'s own `timeoutInterval` — well beyond
        // `URLSession`'s 60s default, though this route itself is a single
        // fast Google API call once the server's actually awake (no
        // multi-recipe Claude generation in the critical path here).
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RecipeWebSearchError.requestFailed
        }

        guard let http = response as? HTTPURLResponse else { throw RecipeWebSearchError.requestFailed }
        guard (200..<300).contains(http.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverMessage = object["error"] as? String, !serverMessage.isEmpty {
                throw RecipeWebSearchError.serverMessage(serverMessage)
            }
            throw RecipeWebSearchError.requestFailed
        }

        struct Response: Decodable { let results: [RecipeWebSearchResult] }
        do {
            return try JSONDecoder().decode(Response.self, from: data).results
        } catch {
            throw RecipeWebSearchError.requestFailed
        }
    }
}
