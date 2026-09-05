import XCTest
@testable import HomeEats

final class SchemaOrgRecipeParserTests: XCTestCase {

    func testParsesBasicRecipeJSONLD() {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org/",
          "@type": "Recipe",
          "name": "Test Pancakes",
          "description": "Fluffy weekend pancakes.",
          "recipeIngredient": ["2 cups flour", "1 cup milk", "1 egg"],
          "recipeInstructions": [
            {"@type": "HowToStep", "text": "Mix dry ingredients."},
            {"@type": "HowToStep", "text": "Whisk in wet ingredients."}
          ],
          "recipeYield": "4 servings",
          "prepTime": "PT10M",
          "cookTime": "PT15M"
        }
        </script>
        </head><body></body></html>
        """

        let parsed = SchemaOrgRecipeParser.parse(html: html)
        XCTAssertEqual(parsed?.name, "Test Pancakes")
        XCTAssertEqual(parsed?.ingredientLines.count, 3)
        XCTAssertEqual(parsed?.instructions, ["Mix dry ingredients.", "Whisk in wet ingredients."])
        XCTAssertEqual(parsed?.servings, 4)
        XCTAssertEqual(parsed?.prepMinutes, 10)
        XCTAssertEqual(parsed?.cookMinutes, 15)
    }

    func testParsesRecipeNestedInGraph() {
        let html = """
        <script type="application/ld+json">
        {"@context": "https://schema.org", "@graph": [
          {"@type": "WebPage", "name": "Some Page"},
          {"@type": "Recipe", "name": "Graph Recipe", "recipeIngredient": ["1 tsp salt"], "recipeInstructions": "Step one.\\nStep two."}
        ]}
        </script>
        """
        let parsed = SchemaOrgRecipeParser.parse(html: html)
        XCTAssertEqual(parsed?.name, "Graph Recipe")
        XCTAssertEqual(parsed?.instructions, ["Step one.", "Step two."])
    }

    func testHandlesHowToSections() {
        let html = """
        <script type="application/ld+json">
        {"@type": "Recipe", "name": "Sectioned Recipe", "recipeInstructions": [
          {"@type": "HowToSection", "name": "Sauce", "itemListElement": [
            {"@type": "HowToStep", "text": "Simmer the sauce."}
          ]},
          {"@type": "HowToStep", "text": "Combine with pasta."}
        ]}
        </script>
        """
        let parsed = SchemaOrgRecipeParser.parse(html: html)
        XCTAssertEqual(parsed?.instructions, ["Simmer the sauce.", "Combine with pasta."])
    }

    func testReturnsNilWhenNoRecipeFound() {
        let html = "<html><body>No structured data here.</body></html>"
        XCTAssertNil(SchemaOrgRecipeParser.parse(html: html))
    }

    func testParsesISO8601Duration() {
        XCTAssertEqual(SchemaOrgRecipeParser.parseISO8601Duration("PT1H30M"), 90)
        XCTAssertEqual(SchemaOrgRecipeParser.parseISO8601Duration("PT45M"), 45)
        XCTAssertNil(SchemaOrgRecipeParser.parseISO8601Duration(nil))
    }
}
