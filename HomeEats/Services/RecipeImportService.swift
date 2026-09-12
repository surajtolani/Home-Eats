import Foundation

enum RecipeImportError: LocalizedError {
    case invalidURL
    case network(Error)
    case blocked
    case noRecipeFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn't look like a valid web address."
        case .network:
            return "Couldn't load that page. Check your connection and try again."
        case .blocked:
            return "That site blocked the request. You can still add the recipe manually."
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
        let statusCode: Int
        do {
            var request = URLRequest(url: url)
            // A real mobile Safari UA, not one that names this app —
            // recipe sites commonly sit behind a WAF (Cloudflare, Sucuri,
            // ...) that blocks anything that doesn't look like an actual
            // browser, which otherwise silently produces a page with no
            // embedded recipe data at all (indistinguishable, before this
            // fix, from the page genuinely not having one). Other headers a
            // real browser always sends along with a User-Agent, for the
            // same reason.
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            let (data, response) = try await URLSession.shared.data(for: request)
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            html = String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw RecipeImportError.network(error)
        }

        guard let parsed = SchemaOrgRecipeParser.parse(html: html) else {
            // A blocked request (bot-protection challenge page, a 403/503
            // from the site's WAF) reads very differently to the user than
            // a page that's genuinely just missing a recipe — worth telling
            // them apart rather than always saying "couldn't find a
            // recipe," which reads as our bug rather than the site's.
            if statusCode == 403 || statusCode == 503 {
                throw RecipeImportError.blocked
            }
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
