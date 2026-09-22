import XCTest

@testable import SupremeSampler

final class SQLPredicateTextTests: XCTestCase {
    func test_givenUnconstrainedFilter_whenRendering_thenReturnsNil() {
        XCTAssertNil(SQLPredicateText.render(SampleFilter()))
    }

    // MARK: - Rating

    func test_givenExactRating_whenRendering_thenRendersEqualityComparison() {
        XCTAssertEqual(SQLPredicateText.render(SampleFilter(rating: .exactly(3))), "Rating = 3")
    }

    func test_givenAtLeastRating_whenRendering_thenRendersGreaterOrEqualComparison() {
        XCTAssertEqual(SQLPredicateText.render(SampleFilter(rating: .atLeast(3))), "Rating >= 3")
    }

    func test_givenAtMostRating_whenRendering_thenRendersLessOrEqualComparison() {
        XCTAssertEqual(SQLPredicateText.render(SampleFilter(rating: .atMost(3))), "Rating <= 3")
    }

    // MARK: - Category

    func test_givenCategoryModeAny_whenRendering_thenRendersExistsClause() {
        let filter = SampleFilter(category: CategoryFilter(propGUIDs: ["A1", "B2"], mode: .any))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "EXISTS (SELECT 1 FROM idCatalogItemDefinition d WHERE d.CatalogItemGUID = idCatalogItem.GUID AND d.GUID IN ('A1', 'B2'))"
        )
    }

    func test_givenCategoryModeNone_whenRendering_thenRendersNotExistsClause() {
        let filter = SampleFilter(category: CategoryFilter(propGUIDs: ["A1"], mode: .none))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "NOT EXISTS (SELECT 1 FROM idCatalogItemDefinition d WHERE d.CatalogItemGUID = idCatalogItem.GUID AND d.GUID IN ('A1'))"
        )
    }

    func test_givenCategoryModeAll_whenRendering_thenRendersCountDistinctClause() {
        let filter = SampleFilter(category: CategoryFilter(propGUIDs: ["A1", "B2"], mode: .all))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "(SELECT COUNT(DISTINCT d.GUID) FROM idCatalogItemDefinition d WHERE d.CatalogItemGUID = idCatalogItem.GUID AND d.GUID IN ('A1', 'B2')) = 2"
        )
    }

    func test_givenEmptyPropGUIDsModeAny_whenRendering_thenRendersVacuouslyFalse() {
        let filter = SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .any))
        XCTAssertEqual(SQLPredicateText.render(filter), "0 = 1")
    }

    func test_givenEmptyPropGUIDsModeAllOrNone_whenRendering_thenRendersVacuouslyTrue() {
        XCTAssertEqual(
            SQLPredicateText.render(SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .all))), "1 = 1")
        XCTAssertEqual(
            SQLPredicateText.render(SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .none))), "1 = 1")
    }

    // MARK: - Combined, and SQL-string-literal escaping of GUID values

    func test_givenRatingAndCategory_whenRendering_thenJoinsWithAND() {
        let filter = SampleFilter(
            rating: .atLeast(3),
            category: CategoryFilter(propGUIDs: ["A1"], mode: .any)
        )
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "Rating >= 3 AND EXISTS (SELECT 1 FROM idCatalogItemDefinition d WHERE d.CatalogItemGUID = idCatalogItem.GUID AND d.GUID IN ('A1'))"
        )
    }

    func test_givenPropGUIDContainingSingleQuote_whenRendering_thenEscapesItAtTheSQLLevel() {
        // Real Photo Supreme prop GUIDs are 32-char hex (see docs/schema.md)
        // and would never contain a quote, but the renderer shouldn't
        // silently produce broken (or worse, semantically wrong) SQL if
        // that assumption is ever violated -- defense in depth, not a
        // live bug today.
        let filter = SampleFilter(category: CategoryFilter(propGUIDs: ["O'Brien"], mode: .any))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "EXISTS (SELECT 1 FROM idCatalogItemDefinition d WHERE d.CatalogItemGUID = idCatalogItem.GUID AND d.GUID IN ('O''Brien'))"
        )
    }
}
