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
    /// page just not having a recipe at all. Beyond that structural case,
    /// WordPress (which most recipe blogs, including Love and Lemons, run
    /// on) also runs post content through its own "smart" typography pass
    /// before it ever reaches the page — curly quotes, en/em dashes, and
    /// spelled-out fraction glyphs come out the other side as literal
    /// `&#8217;`-style numeric entities even inside an otherwise
    /// well-formed JSON-LD block, so an ingredient can come through as
    /// "Trader Joe&#8217;s Butter" instead of "Trader Joe's Butter" unless
    /// something on this side decodes it back. `&amp;`/`&#38;` have to run
    /// last since they're a prefix of how a double-escaped entity
    /// (`&amp;quot;`) was originally produced.
    static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in namedHTMLEntityReplacements {
            result = result.replacingOccurrences(of: "&\(entity);", with: replacement)
        }
        // Catches everything the named table above doesn't — any
        // `&#8217;` (decimal) or `&#x2019;` (hex) numeric reference,
        // decoded to its actual Unicode character.
        result = decodeNumericHTMLEntities(in: result)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }

    /// Common named entities recipe pages actually emit. Order matters:
    /// multi-character entities that share a prefix with a later one
    /// (`&apos;` vs. the bare ampersand `&amp;`) are listed before `&amp;`,
    /// which is applied separately, last, in `decodeHTMLEntities` above.
    private static let namedHTMLEntityReplacements: [(String, String)] = [
        ("quot", "\""), ("apos", "'"), ("lt", "<"), ("gt", ">"),
        ("nbsp", "\u{00A0}"),
        ("lsquo", "\u{2018}"), ("rsquo", "\u{2019}"),
        ("ldquo", "\u{201C}"), ("rdquo", "\u{201D}"),
        ("ndash", "\u{2013}"), ("mdash", "\u{2014}"), ("hellip", "\u{2026}"),
        ("deg", "\u{00B0}"),
        ("frac12", "\u{00BD}"), ("frac14", "\u{00BC}"), ("frac34", "\u{00BE}"),
        ("frac13", "\u{2153}"), ("frac23", "\u{2154}")
    ]

    /// Decodes every `&#NNN;` (decimal) and `&#xHHHH;` (hex) numeric
    /// character reference to its actual Unicode character. A malformed or
    /// out-of-range reference is left exactly as it was rather than dropped,
    /// so a parsing mistake here never silently eats real text.
    private static func decodeNumericHTMLEntities(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|\d+);"#, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let codeText = ns.substring(with: match.range(at: 1))
            let scalarValue = codeText.lowercased().hasPrefix("x")
                ? UInt32(codeText.dropFirst(), radix: 16)
                : UInt32(codeText)
            if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                result.append(Character(scalar))
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
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

        // Walks *every* nested value, not just `@graph` — Yoast/RankMath-
        // style SEO plugins commonly nest the actual `Recipe` node under a
        // `WebPage`'s `mainEntity`, or other structures entirely, rather
        // than as a sibling entry in `@graph`. Recursing into every value
        // (not just a specific known key) means wherever a site's plugin
        // happens to bury the `Recipe` node, this still finds it.
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if typeMatches(dict) { results.append(dict) }
                for value in dict.values { walk(value) }
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
