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

    func test_givenCategoryModeAny_whenRendering_thenRendersInSubquery() {
        let filter = SampleFilter(category: CategoryFilter(propGUIDs: ["A1", "B2"], mode: .any))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "idCatalogItem.GUID IN (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d WHERE d.GUID IN ('A1', 'B2') AND d.CatalogItemGUID IS NOT NULL)"
        )
    }

    func test_givenCategoryModeNone_whenRendering_thenRendersNullSafeNotInSubquery() {
        let filter = SampleFilter(category: CategoryFilter(propGUIDs: ["A1"], mode: .none))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "idCatalogItem.GUID NOT IN (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d WHERE d.GUID IN ('A1') AND d.CatalogItemGUID IS NOT NULL)"
        )
    }

    func test_givenCategoryModeAll_whenRendering_thenRendersOneMembershipTestPerBranch() {
        let filter = SampleFilter(category: CategoryFilter(propGUIDs: ["A1", "B2"], mode: .all))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "(idCatalogItem.GUID IN (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d WHERE d.GUID IN ('A1') AND d.CatalogItemGUID IS NOT NULL)"
                + " AND idCatalogItem.GUID IN (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d WHERE d.GUID IN ('B2') AND d.CatalogItemGUID IS NOT NULL))"
        )
    }

    func test_givenCategoryModeAnyOverBranches_whenRendering_thenListsEveryKeywordInEveryBranchOnce() {
        let filter = SampleFilter(
            category: CategoryFilter(
                branches: [
                    CategoryBranch(rootGUID: "P", propGUIDs: ["C1", "P"]),
                    CategoryBranch(rootGUID: "C1", propGUIDs: ["C1"]),
                ],
                mode: .any
            ))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "idCatalogItem.GUID IN (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d WHERE d.GUID IN ('C1', 'P') AND d.CatalogItemGUID IS NOT NULL)"
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

    // MARK: - Rule groups

    // A top-level "all of" group renders bare (`a AND b`), exactly as
    // before groups existed. Every other group is self-delimiting, so it
    // can be appended after `rowid IN (...) AND` in the sampling query
    // without an OR leaking out.

    func test_givenAnAnyOfRootGroup_whenRendering_thenJoinsWithORInParentheses() {
        let filter = SampleFilter(root: RuleGroup(match: .any, rules: [.rating(.exactly(5)), .rating(.exactly(1))]))
        XCTAssertEqual(SQLPredicateText.render(filter), "(Rating = 5 OR Rating = 1)")
    }

    func test_givenANoneOfGroup_whenRendering_thenNegatesTreatingUnknownAsNotMatched() {
        let filter = SampleFilter(root: RuleGroup(match: .none, rules: [.rating(.atLeast(4)), .rating(.exactly(1))]))
        XCTAssertEqual(SQLPredicateText.render(filter), "NOT COALESCE((Rating >= 4 OR Rating = 1), 0)")
    }

    func test_givenANestedAllOfGroup_whenRendering_thenItIsParenthesized() {
        let filter = SampleFilter(
            root: RuleGroup(
                match: .any,
                rules: [
                    .rating(.exactly(5)),
                    .group(RuleGroup(match: .all, rules: [.rating(.atLeast(2)), .rating(.atMost(3))])),
                ]))
        XCTAssertEqual(SQLPredicateText.render(filter), "(Rating = 5 OR (Rating >= 2 AND Rating <= 3))")
    }

    func test_givenEmptyNestedGroups_whenRendering_thenRendersVacuousTruthValues() {
        let filter = SampleFilter(
            root: RuleGroup(
                match: .all,
                rules: [
                    .group(RuleGroup(match: .any, rules: [])),
                    .group(RuleGroup(match: .all, rules: [])),
                    .group(RuleGroup(match: .none, rules: [])),
                ]))
        XCTAssertEqual(SQLPredicateText.render(filter), "0 = 1 AND 1 = 1 AND 1 = 1")
    }

    func test_givenAnEmptyAnyOfRootGroup_whenRendering_thenStillRendersAClause() {
        XCTAssertEqual(SQLPredicateText.render(SampleFilter(root: RuleGroup(match: .any, rules: []))), "0 = 1")
    }

    // MARK: - File path

    func test_givenAPathContainsRule_whenRendering_thenMatchesTheJoinedFolderAndFileName() {
        let filter = SampleFilter(root: RuleGroup(match: .all, rules: [.path(PathFilter(kind: .contains, text: "/2019/"))]))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "EXISTS (SELECT 1 FROM idCache_FilePath fp WHERE fp.FilePathGUID = idCatalogItem.PathGUID"
                + " AND (fp.FilePath || idCatalogItem.FileName) LIKE '%/2019/%' ESCAPE '\\')"
        )
    }

    func test_givenPathTextWithWildcardCharacters_whenRendering_thenTheyAreEscaped() {
        let filter = SampleFilter(root: RuleGroup(match: .all, rules: [.path(PathFilter(kind: .startsWith, text: "a_b%c\\d"))]))
        XCTAssertTrue(SQLPredicateText.render(filter)!.contains("LIKE 'a\\_b\\%c\\\\d%' ESCAPE '\\'"))
    }

    func test_givenNonASCIIPathText_whenRendering_thenTheSQLIsPureASCII() {
        let filter = SampleFilter(root: RuleGroup(match: .all, rules: [.path(PathFilter(kind: .endsWith, text: "Lil’"))]))
        let sql = SQLPredicateText.render(filter)!
        XCTAssertTrue(sql.allSatisfy(\.isASCII))
        XCTAssertTrue(sql.contains("LIKE '%Lil' || char(8217) ESCAPE"))
    }

    // MARK: - Keyword path

    private func keywordPathFilter(_ kind: KeywordPathMatchKind, _ text: String, negated: Bool = false) -> SampleFilter {
        SampleFilter(
            root: RuleGroup(match: .all, rules: [.keywordPath(KeywordPathFilter(kind: kind, text: text, negated: negated))]))
    }

    func test_givenEmptyKeywordPathText_whenRendering_thenTheRuleIsAlwaysTrue() {
        XCTAssertEqual(SQLPredicateText.render(keywordPathFilter(.contains, "")), "1 = 1")
        XCTAssertEqual(SQLPredicateText.render(keywordPathFilter(.hasPart, "", negated: true)), "1 = 1")
    }

    /// `{` opens a comment in Pascal; the script's SQL avoids it even
    /// inside a string literal, given Script Studio's flaky comment
    /// handling (AGENTS.md).
    func test_givenAKeywordPathRule_whenRendering_thenTheSQLHasNoCurlyBrace() throws {
        let sql = try XCTUnwrap(SQLPredicateText.render(keywordPathFilter(.hasPart, "Trees")))

        XCTAssertFalse(sql.contains("{"), sql)
        XCTAssertTrue(sql.hasPrefix("idCatalogItem.GUID IN (SELECT d.CatalogItemGUID"), sql)
    }

    func test_givenANegatedKeywordPathRule_whenRendering_thenItUsesTheNullSafeNotIn() throws {
        let sql = try XCTUnwrap(SQLPredicateText.render(keywordPathFilter(.contains, "x", negated: true)))

        XCTAssertTrue(sql.hasPrefix("idCatalogItem.GUID NOT IN ("), sql)
        XCTAssertTrue(sql.contains("d.CatalogItemGUID IS NOT NULL"), sql)
    }

    // MARK: - Color label

    func test_givenAnyOfLabels_whenRendering_thenNonASCIILabelsAreBuiltFromCodePoints() {
        let filter = SampleFilter(root: RuleGroup(match: .all, rules: [.label(LabelFilter(labels: ["Select", "選択"], mode: .any))]))
        XCTAssertEqual(SQLPredicateText.render(filter), "COALESCE(idLabel, '') IN ('Select', char(36984, 25246))")
    }

    func test_givenNoneOfLabels_whenRendering_thenUnlabeledPhotosStayIncluded() {
        let filter = SampleFilter(root: RuleGroup(match: .all, rules: [.label(LabelFilter(labels: ["Red"], mode: .none))]))
        XCTAssertEqual(SQLPredicateText.render(filter), "COALESCE(idLabel, '') NOT IN ('Red')")
    }

    // MARK: - File type

    func test_givenAnyOfFileTypes_whenRendering_thenEachIsAnEndsWithMatch() {
        let filter = SampleFilter(
            root: RuleGroup(match: .all, rules: [.fileType(FileTypeFilter(extensions: ["jpg", "png"], mode: .any))]))
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "(COALESCE(FileName, '') LIKE '%.jpg' ESCAPE '\\' OR COALESCE(FileName, '') LIKE '%.png' ESCAPE '\\')")
    }

    func test_givenNoneOfFileTypes_whenRendering_thenTheMatchIsNegated() {
        let filter = SampleFilter(root: RuleGroup(match: .all, rules: [.fileType(FileTypeFilter(extensions: ["mkv"], mode: .none))]))
        XCTAssertEqual(SQLPredicateText.render(filter), "NOT (COALESCE(FileName, '') LIKE '%.mkv' ESCAPE '\\')")
    }

    // MARK: - Bookmark

    func test_givenBookmarks_whenRendering_thenNullCountsAsNoBookmark() {
        let anyOf = SampleFilter(root: RuleGroup(match: .all, rules: [.bookmark(BookmarkFilter(values: [2, 3], mode: .any))]))
        let noneOf = SampleFilter(root: RuleGroup(match: .all, rules: [.bookmark(BookmarkFilter(values: [5], mode: .none))]))
        XCTAssertEqual(SQLPredicateText.render(anyOf), "CAST(COALESCE(idBookmark, 0) AS INTEGER) IN (2, 3)")
        XCTAssertEqual(SQLPredicateText.render(noneOf), "CAST(COALESCE(idBookmark, 0) AS INTEGER) NOT IN (5)")
    }

    // MARK: - Pending deletion

    func test_givenPendingDeletion_whenRendering_thenItIsANegativeRating() {
        let pending = SampleFilter(root: RuleGroup(match: .all, rules: [.pendingDeletion(true)]))
        let notPending = SampleFilter(root: RuleGroup(match: .all, rules: [.pendingDeletion(false)]))
        XCTAssertEqual(SQLPredicateText.render(pending), "COALESCE(Rating, 0) < 0")
        XCTAssertEqual(SQLPredicateText.render(notPending), "COALESCE(Rating, 0) >= 0")
    }

    // MARK: - Negations

    func test_givenRatingIsNot_whenRendering_thenItIsTheNullSafeInequality() {
        XCTAssertEqual(SQLPredicateText.render(SampleFilter(rating: .isNot(5))), "Rating IS NOT 5")
    }

    func test_givenANegatedPathRule_whenRendering_thenItIsNotExists() {
        let filter = SampleFilter(
            root: RuleGroup(match: .all, rules: [.path(PathFilter(kind: .contains, text: "x", negated: true))]))
        XCTAssertTrue(SQLPredicateText.render(filter)!.hasPrefix("NOT EXISTS (SELECT 1 FROM idCache_FilePath fp"))
    }

    // MARK: - Combined, and SQL-string-literal escaping of GUID values

    func test_givenRatingAndCategory_whenRendering_thenJoinsWithAND() {
        let filter = SampleFilter(
            rating: .atLeast(3),
            category: CategoryFilter(propGUIDs: ["A1"], mode: .any)
        )
        XCTAssertEqual(
            SQLPredicateText.render(filter),
            "Rating >= 3 AND idCatalogItem.GUID IN (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d WHERE d.GUID IN ('A1') AND d.CatalogItemGUID IS NOT NULL)"
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
            "idCatalogItem.GUID IN (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d WHERE d.GUID IN ('O''Brien') AND d.CatalogItemGUID IS NOT NULL)"
        )
    }
}
