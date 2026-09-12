import Foundation

/// Pure parsing logic for pulling schema.org `Recipe` structured data
/// (JSON-LD) out of a page's raw HTML. Kept separate from
/// `RecipeImportService` (which does the actual networking) so it's easy to
/// unit test without hitting the network.
enum SchemaOrgRecipeParser {

    struct ParsedRecipeData: Equatable {
        var name: String?
        var description: String?
        var ingredientLines: [String]
        var instructions: [String]
        var servings: Int?
        var prepMinutes: Int?
        var cookMinutes: Int?
        var imageURLString: String?
    }

    static func parse(html: String) -> ParsedRecipeData? {
        for block in jsonLDBlocks(in: html) {
            guard let data = block.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let recipeObjects = findRecipeObjects(in: json)
            if let first = recipeObjects.first {
                return parseRecipeObject(first)
            }
        }
        return nil
    }

    /// Extracts the raw contents of every `<script type="application/ld+json">` tag.
    static func jsonLDBlocks(in html: String) -> [String] {
        let pattern = #"<script[^>]+type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)
        return matches.compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: html) else { return nil }
            return decodeHTMLEntities(String(html[r]))
        }
    }

    /// A few page builders/CMSes HTML-entity-encode characters inside an
    /// embedded JSON-LD block (quotes especially) even though it's meant to
    /// be raw JSON — left alone, that silently breaks `JSONSerialization`
    /// parsing (a caught error, not a crash), which looks identical to the
    /// page just not having a recipe at all. `&amp;` has to run last since
    /// it's a prefix of how the others were originally escaped.
    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func findRecipeObjects(in json: Any) -> [[String: Any]] {
        var results: [[String: Any]] = []

        func typeMatches(_ obj: [String: Any]) -> Bool {
            if let t = obj["@type"] as? String { return t.lowercased() == "recipe" }
            if let arr = obj["@type"] as? [Any] {
                return arr.compactMap { $0 as? String }.contains { $0.lowercased() == "recipe" }
            }
            return false
        }

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if typeMatches(dict) { results.append(dict) }
                if let graph = dict["@graph"] { walk(graph) }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }

        walk(json)
        return results
    }

    static func parseRecipeObject(_ obj: [String: Any]) -> ParsedRecipeData {
        ParsedRecipeData(
            name: obj["name"] as? String,
            description: obj["description"] as? String,
            ingredientLines: (obj["recipeIngredient"] as? [Any])?.compactMap { $0 as? String }
                ?? (obj["ingredients"] as? [Any])?.compactMap { $0 as? String }
                ?? [],
            instructions: extractInstructions(obj["recipeInstructions"]),
            servings: extractServings(obj["recipeYield"]),
            prepMinutes: parseISO8601Duration(obj["prepTime"] as? String),
            cookMinutes: parseISO8601Duration(obj["cookTime"] as? String),
            imageURLString: extractImageURLString(obj["image"])
        )
    }

    static func extractInstructions(_ value: Any?) -> [String] {
        guard let value else { return [] }

        if let text = value as? String {
            return text
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        if let array = value as? [Any] {
            var steps: [String] = []
            for item in array {
                if let text = item as? String {
                    steps.append(text)
                } else if let obj = item as? [String: Any] {
                    let type = (obj["@type"] as? String)?.lowercased()
                    if type == "howtosection", let items = obj["itemListElement"] as? [Any] {
                        steps.append(contentsOf: extractInstructions(items))
                    } else if let text = obj["text"] as? String {
                        steps.append(text)
                    } else if let name = obj["name"] as? String {
                        steps.append(name)
                    }
                }
            }
            return steps
        }

        return []
    }

    static func extractServings(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return firstInt(in: text) }
        if let array = value as? [Any] {
            for item in array {
                if let servings = extractServings(item) { return servings }
            }
        }
        return nil
    }

    static func extractImageURLString(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let array = value as? [Any] {
            for item in array {
                if let url = extractImageURLString(item) { return url }
            }
        }
        if let obj = value as? [String: Any] {
            return obj["url"] as? String
        }
        return nil
    }

    static func firstInt(in text: String) -> Int? {
        guard let range = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    /// Parses ISO-8601 durations like "PT15M" or "PT1H30M" into whole minutes.
    static func parseISO8601Duration(_ value: String?) -> Int? {
        guard let value, value.hasPrefix("PT") else { return nil }
        var minutes = 0
        if let hourRange = value.range(of: #"(\d+)H"#, options: .regularExpression) {
            let digits = value[hourRange].dropLast()
            minutes += (Int(digits) ?? 0) * 60
        }
        if let minuteRange = value.range(of: #"(\d+)M"#, options: .regularExpression) {
            let digits = value[minuteRange].dropLast()
            minutes += Int(digits) ?? 0
        }
        return minutes == 0 ? nil : minutes
    }
}
