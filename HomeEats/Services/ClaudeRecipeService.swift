import Foundation

/// One recipe as returned by the backend's Claude-powered endpoints,
/// whether extracted from a photo/notes or suggested from a list of
/// ingredients — same shape either way, matching `RecipeDraft` in
/// `backend/index.js`.
struct RecipeDraft: Decodable, Identifiable {
    var id: String { title }
    var title: String
    var summary: String?
    var ingredientLines: [String]
    var instructions: [String]
    var servings: Int?
    var prepMinutes: Int?
    var cookMinutes: Int?
}

enum ClaudeRecipeServiceError: LocalizedError {
    case notConfigured
    case requestFailed
    case noRecipeFound

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI recipe features aren't set up yet — see backend/README.md."
        case .requestFailed:
            return "Couldn't reach the recipe assistant. Check your connection and try again."
        case .noRecipeFound:
            return "Couldn't find a recipe there. Try a clearer photo or a bit more detail in your notes."
        }
    }
}

/// Talks to the Home Eats backend's Claude-powered recipe endpoints (see
/// backend/README.md) rather than the Anthropic API directly — the backend
/// holds the real API key, same reasoning as `GooglePlacesService`.
enum ClaudeRecipeService {
    /// Same backend/deployment as `GooglePlacesService` — this only starts
    /// actually working once `ANTHROPIC_API_KEY` is also set on that
    /// deployment (see backend/README.md); until then `isConfigured` is
    /// true but requests will just fail with `.requestFailed`.
    private static let baseURLString = "https://home-eats-uqbp.onrender.com"

    static var isConfigured: Bool { !baseURLString.isEmpty }

    /// "Add a recipe from a photo or notes" instead of typing it all in by
    /// hand — a photo of a recipe card, a screenshot, a handwritten note,
    /// typed notes, or both together.
    static func extractRecipe(imageData: Data?, notesText: String?) async throws -> RecipeDraft {
        var body: [String: Any] = [:]
        if let imageData {
            body["imageBase64"] = imageData.base64EncodedString()
            body["mediaType"] = "image/jpeg"
        }
        let trimmedNotes = notesText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedNotes, !trimmedNotes.isEmpty {
            body["notesText"] = trimmedNotes
        }
        return try await post(path: "recipes/extract", body: body)
    }

    /// "What can I make with X, Y, Z" (or "recommend a meal" with an empty
    /// ingredient list — the backend suggests generally approachable
    /// weeknight dinners in that case). `excludeTitles` is `RecommendMealView`'s
    /// "Show More Ideas" — the titles already on screen, so this asks for a
    /// genuinely new batch rather than risking the same (or a barely-reworded)
    /// suggestion twice.
    static func recommendMeals(ingredients: [String], excludeTitles: [String] = []) async throws -> [RecipeDraft] {
        struct Response: Decodable { let recipes: [RecipeDraft] }
        var body: [String: Any] = ["ingredients": ingredients]
        if !excludeTitles.isEmpty { body["excludeTitles"] = excludeTitles }
        let response: Response = try await post(path: "recipes/recommend", body: body)
        return response.recipes
    }

    private static func post<T: Decodable>(path: String, body: [String: Any]) async throws -> T {
        guard isConfigured, let base = URL(string: baseURLString) else {
            throw ClaudeRecipeServiceError.notConfigured
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Well beyond `URLSession`'s 60s default. This backend is a
        // free-tier Render deployment that spins down after inactivity and
        // takes real time to wake back up (see backend/README.md) — on top
        // of that, a genuine Claude generation for several full recipes
        // (ingredients, instructions, and all) isn't instant either. Both
        // together can plausibly exceed 60s on a cold first request, which
        // would otherwise time out and surface as a plain "couldn't reach
        // the server" error indistinguishable from an actual outage —
        // likely what was behind reports of "Recommend a Meal" seeming to
        // just not work.
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeRecipeServiceError.requestFailed
        }

        guard let http = response as? HTTPURLResponse else { throw ClaudeRecipeServiceError.requestFailed }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 422 { throw ClaudeRecipeServiceError.noRecipeFound }
            throw ClaudeRecipeServiceError.requestFailed
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClaudeRecipeServiceError.requestFailed
        }
    }
}

extension RecipeDraft {
    /// Builds a `Recipe` the same way `RecipeImportService` does from a
    /// parsed page — raw ingredient lines go through the same
    /// `IngredientLineParser`, so a Claude-sourced recipe behaves
    /// identically to a URL-imported one everywhere else in the app.
    /// Tagged "AI" so it's visibly distinguishable in `RecipeDetailView`.
    func makeRecipe(createdByMemberID: UUID?) -> Recipe {
        Recipe(
            title: title,
            source: .manual,
            summary: summary,
            instructions: instructions,
            ingredients: ingredientLines.map(IngredientLineParser.parse),
            servings: servings ?? 4,
            prepMinutes: prepMinutes ?? 0,
            cookMinutes: cookMinutes ?? 0,
            tags: ["AI"],
            createdByMemberID: createdByMemberID
        )
    }
}
