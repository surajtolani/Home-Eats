import Foundation

enum RecipeImportError: LocalizedError {
    case invalidURL
    case network(Error)
    case noRecipeFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn't look like a valid web address."
        case .network:
            return "Couldn't load that page. Check your connection and try again."
        case .noRecipeFound:
            return "Couldn't find a recipe on that page. You can still add it manually."
        }
    }
}

/// Imports a recipe by fetching a URL and reading the page's embedded
/// schema.org `Recipe` structured data (JSON-LD, see `SchemaOrgRecipeParser`),
/// which the vast majority of recipe blogs and sites publish for SEO/rich
/// snippet purposes. This avoids needing a full HTML parser or per-site
/// scraping rules.
enum RecipeImportService {

    static func importRecipe(from urlString: String) async throws -> Recipe {
        guard let url = normalizedURL(from: urlString) else {
            throw RecipeImportError.invalidURL
        }

        let html: String
        do {
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) HomeEatsApp/1.0",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, _) = try await URLSession.shared.data(for: request)
            html = String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw RecipeImportError.network(error)
        }

        guard let parsed = SchemaOrgRecipeParser.parse(html: html) else {
            throw RecipeImportError.noRecipeFound
        }

        return Recipe(
            title: parsed.name ?? "Imported Recipe",
            source: .imported,
            sourceURL: url.absoluteString,
            summary: parsed.description,
            instructions: parsed.instructions,
            ingredients: parsed.ingredientLines.map(IngredientLineParser.parse),
            servings: parsed.servings ?? 4,
            prepMinutes: parsed.prepMinutes ?? 0,
            cookMinutes: parsed.cookMinutes ?? 0,
            imageName: parsed.imageURLString
        )
    }

    private static func normalizedURL(from string: String) -> URL? {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        return URL(string: trimmed)
    }
}
