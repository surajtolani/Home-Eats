import Foundation

/// Produces a "what should we make this week" ranking from meal history.
/// Deliberately simple per the spec (frequency + recency, no ML): a recipe
/// made often, and made recently, floats to the top; something cooked once
/// months ago barely counts.
enum RecommendationEngine {

    /// Higher score = stronger recommendation.
    static func score(recipeID: UUID, history: [MealHistoryEntry], now: Date = .now) -> Double {
        let entries = history.filter { $0.recipeID == recipeID }
        guard !entries.isEmpty else { return 0 }

        return entries.reduce(0.0) { partial, entry in
            let daysAgo = max(0, now.timeIntervalSince(entry.date) / 86_400)
            // Half-life of ~45 days: something made a month and a half ago
            // still counts for about half as much as one made today.
            let recencyWeight = pow(0.5, daysAgo / 45.0)
            let ratingWeight: Double
            switch entry.rating {
            case .liked: ratingWeight = 1.5
            case .neutral, .none: ratingWeight = 1.0
            case .disliked: ratingWeight = 0.25
            }
            return partial + recencyWeight * ratingWeight
        }
    }

    /// Ranks a candidate set of recipes (e.g. the user's saved collection)
    /// from most to least recommended, given the household's meal history.
    static func rank(recipes: [Recipe], history: [MealHistoryEntry], now: Date = .now) -> [Recipe] {
        recipes
            .map { recipe in (recipe, score(recipeID: recipe.id, history: history, now: now)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title < rhs.0.title
            }
            .map(\.0)
    }

    /// Recipes never cooked before are surfaced separately so "try something
    /// new" stays easy even though the ranked list favors old favorites.
    static func neverMade(recipes: [Recipe], history: [MealHistoryEntry]) -> [Recipe] {
        let madeIDs = Set(history.compactMap(\.recipeID))
        return recipes.filter { !madeIDs.contains($0.id) }
    }
}
