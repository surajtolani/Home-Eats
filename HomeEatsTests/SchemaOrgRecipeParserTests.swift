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

    func testDecodesHTMLEntityEncodedQuotesInJSONLD() {
        // A handful of page builders HTML-entity-encode the quotes inside an
        // embedded JSON-LD block even though it's meant to be raw JSON —
        // left alone this silently fails to parse as JSON at all, which
        // looks identical to the page just not having a recipe.
        let html = """
        <script type="application/ld+json">
        {&quot;@type&quot;: &quot;Recipe&quot;, &quot;name&quot;: &quot;Entity Recipe&quot;, &quot;recipeIngredient&quot;: [&quot;1 cup rice&quot;]}
        </script>
        """
        let parsed = SchemaOrgRecipeParser.parse(html: html)
        XCTAssertEqual(parsed?.name, "Entity Recipe")
        XCTAssertEqual(parsed?.ingredientLines, ["1 cup rice"])
    }

    /// Regression test: WordPress (which most recipe blogs run on, Love and
    /// Lemons included) runs post content through its own typography pass
    /// before it's ever rendered, so curly quotes/apostrophes commonly come
    /// through as literal numeric HTML entities even inside an otherwise
    /// well-formed embedded JSON-LD block.
    func testDecodesNumericHTMLEntitiesInIngredientText() {
        let html = """
        <script type="application/ld+json">
        {"@type": "Recipe", "name": "Trader Joe&#8217;s Chia Pudding", "recipeIngredient": ["2 tbsp Trader Joe&#8217;s chia seeds", "1&#189; cups almond milk"], "recipeInstructions": "Stir &amp; chill."}
        </script>
        """
        let parsed = SchemaOrgRecipeParser.parse(html: html)
        XCTAssertEqual(parsed?.name, "Trader Joe\u{2019}s Chia Pudding")
        XCTAssertEqual(parsed?.ingredientLines, ["2 tbsp Trader Joe\u{2019}s chia seeds", "1\u{00BD} cups almond milk"])
        XCTAssertEqual(parsed?.instructions, ["Stir & chill."])
    }

    /// Regression test: Yoast/RankMath-style SEO plugins often nest the
    /// actual `Recipe` node under a `WebPage`'s `mainEntity` rather than as
    /// a sibling entry directly inside `@graph`.
    func testFindsRecipeNestedUnderMainEntity() {
        let html = """
        <script type="application/ld+json">
        {"@context": "https://schema.org", "@graph": [
          {"@type": "WebPage", "name": "Some Page", "mainEntity": {
            "@type": "Recipe", "name": "Main Entity Recipe", "recipeIngredient": ["1 cup oats"]
          }},
          {"@type": "Organization", "name": "Some Blog"}
        ]}
        </script>
        """
        let parsed = SchemaOrgRecipeParser.parse(html: html)
        XCTAssertEqual(parsed?.name, "Main Entity Recipe")
        XCTAssertEqual(parsed?.ingredientLines, ["1 cup oats"])
    }

    func testParsesISO8601Duration() {
        XCTAssertEqual(SchemaOrgRecipeParser.parseISO8601Duration("PT1H30M"), 90)
        XCTAssertEqual(SchemaOrgRecipeParser.parseISO8601Duration("PT45M"), 45)
        XCTAssertNil(SchemaOrgRecipeParser.parseISO8601Duration(nil))
    }
}
