import XCTest

@testable import SupremeSampler

/// Specifies the keyword count rule: how many keywords a photo has --
/// distinct nodes of the custom keyword trees assigned to it, the same
/// keywords the Keyword field's tree and path tests see. "Keyword is
/// empty" is a count of zero.
final class KeywordCountFilterTests: XCTestCase {
    func test_givenEachComparison_whenMatchingCounts_thenItComparesTheCount() {
        XCTAssertTrue(KeywordCountFilter.exactly(2).matches(count: 2))
        XCTAssertFalse(KeywordCountFilter.exactly(2).matches(count: 3))
        XCTAssertTrue(KeywordCountFilter.atLeast(2).matches(count: 3))
        XCTAssertFalse(KeywordCountFilter.atLeast(2).matches(count: 1))
        XCTAssertTrue(KeywordCountFilter.atMost(2).matches(count: 2))
        XCTAssertFalse(KeywordCountFilter.atMost(2).matches(count: 3))
        XCTAssertTrue(KeywordCountFilter.isNot(2).matches(count: 0))
        XCTAssertFalse(KeywordCountFilter.isNot(2).matches(count: 2))
    }

    func test_givenNoKeywords_whenMatchingEmptyAndNotEmpty_thenOnlyEmptyMatches() {
        XCTAssertTrue(KeywordCountFilter.isEmpty.matches(count: 0))
        XCTAssertFalse(KeywordCountFilter.isEmpty.matches(count: 1))
        XCTAssertTrue(KeywordCountFilter.isNotEmpty.matches(count: 1))
        XCTAssertFalse(KeywordCountFilter.isNotEmpty.matches(count: 0))
    }

    /// Photos with no keywords have no assignment rows to count, so the
    /// SQL has to reach them by exclusion; which way it goes depends on
    /// whether zero keywords satisfies the rule.
    func test_givenEachComparison_whenAskingAboutZero_thenItSaysWhetherPhotosWithoutKeywordsMatch() {
        XCTAssertTrue(KeywordCountFilter.exactly(0).matchesZero)
        XCTAssertFalse(KeywordCountFilter.exactly(1).matchesZero)
        XCTAssertFalse(KeywordCountFilter.atLeast(1).matchesZero)
        XCTAssertTrue(KeywordCountFilter.atLeast(0).matchesZero)
        XCTAssertTrue(KeywordCountFilter.atMost(2).matchesZero)
        XCTAssertTrue(KeywordCountFilter.isNot(3).matchesZero)
        XCTAssertFalse(KeywordCountFilter.isNot(0).matchesZero)
    }

    /// The SQL both renderers share: photos are selected by membership in
    /// the set of photos *with* keywords, grouped by photo, testing the
    /// rule (or, when zero matches, excluding photos that fail it).
    func test_givenACountThatZeroFails_whenRenderingSQL_thenItSelectsPhotosPassingTheTest() {
        let sql = KeywordCountFilter.atLeast(2).photoGUIDTest
        XCTAssertTrue(sql.hasPrefix("idCatalogItem.GUID IN ("), sql)
        XCTAssertTrue(sql.hasSuffix("HAVING COUNT(DISTINCT d.GUID) >= 2)"), sql)
    }

    func test_givenACountThatZeroPasses_whenRenderingSQL_thenItExcludesPhotosFailingTheTest() {
        let sql = KeywordCountFilter.atMost(2).photoGUIDTest
        XCTAssertTrue(sql.hasPrefix("idCatalogItem.GUID NOT IN ("), sql)
        XCTAssertTrue(sql.hasSuffix("HAVING NOT (COUNT(DISTINCT d.GUID) <= 2))"), sql)
    }

    /// Only the custom keyword trees count, like the keyword path rule;
    /// the NULL guard keeps `NOT IN` from matching nothing.
    func test_givenAnyCount_whenRenderingSQL_thenItCountsCustomKeywordsAndSkipsNullPhotos() {
        let sql = KeywordCountFilter.isEmpty.photoGUIDTest
        XCTAssertTrue(sql.contains(KeywordPathFilter.keywordPathsQuery), sql)
        XCTAssertTrue(sql.contains("d.CatalogItemGUID IS NOT NULL"), sql)
        XCTAssertTrue(sql.contains("GROUP BY d.CatalogItemGUID"), sql)
    }
}
