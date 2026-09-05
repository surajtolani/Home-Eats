import XCTest
@testable import HomeEats

final class RecommendationEngineTests: XCTestCase {

    func testRecentlyMadeRecipeOutranksOldOne() {
        let recentRecipe = Recipe(title: "Recent Favorite")
        let oldRecipe = Recipe(title: "Old Favorite")
        let now = Date()

        let history = [
            MealHistoryEntry(date: now.addingTimeInterval(-2 * 86_400), recipeID: recentRecipe.id, rating: .liked),
            MealHistoryEntry(date: now.addingTimeInterval(-200 * 86_400), recipeID: oldRecipe.id, rating: .liked)
        ]

        let ranked = RecommendationEngine.rank(recipes: [oldRecipe, recentRecipe], history: history, now: now)
        XCTAssertEqual(ranked.first?.id, recentRecipe.id)
    }

    func testDislikedMealScoresLowerThanLiked() {
        let now = Date()
        let liked = Recipe(title: "Liked")
        let disliked = Recipe(title: "Disliked")
        let history = [
            MealHistoryEntry(date: now, recipeID: liked.id, rating: .liked),
            MealHistoryEntry(date: now, recipeID: disliked.id, rating: .disliked)
        ]

        let likedScore = RecommendationEngine.score(recipeID: liked.id, history: history, now: now)
        let dislikedScore = RecommendationEngine.score(recipeID: disliked.id, history: history, now: now)
        XCTAssertGreaterThan(likedScore, dislikedScore)
    }

    func testNeverMadeRecipesAreSurfacedSeparately() {
        let made = Recipe(title: "Made Before")
        let neverMade = Recipe(title: "Never Made")
        let history = [MealHistoryEntry(recipeID: made.id)]

        let result = RecommendationEngine.neverMade(recipes: [made, neverMade], history: history)
        XCTAssertEqual(result.map(\.id), [neverMade.id])
    }

    func testRecipeWithNoHistoryScoresZero() {
        let recipe = Recipe(title: "Untested")
        XCTAssertEqual(RecommendationEngine.score(recipeID: recipe.id, history: []), 0)
    }
}
