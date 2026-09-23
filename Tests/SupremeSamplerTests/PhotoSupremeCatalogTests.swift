import GRDB
import XCTest

@testable import SupremeSampler

// BDD-style: each test name reads as Given/When/Then. XCTest has no
// describe/it blocks like Jest or Python's pytest-bdd -- discovery is by
// subclassing XCTestCase and a `test` name prefix, so the Given/When/Then
// goes in the method name itself.
final class PhotoSupremeCatalogTests: XCTestCase {
    // Each test gets its own throwaway SQLite file, the same idea as
    // Python's `tempfile.NamedTemporaryFile` or Rust's
    // `tempfile::NamedTempFile`: GRDB's readonly mode needs a real file
    // on disk (not the special ":memory:" path), since two separate
    // connections -- the fixture writer below, and PhotoSupremeCatalog's
    // own reader -- need to see the same file.
    private var fixturePath: String!

    override func setUpWithError() throws {
        fixturePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: fixturePath)
    }

    /// One row of fixture data: a photo, its rating, and the prop GUIDs
    /// (categories/keywords) assigned to it. A plain data-holder struct
    /// local to this test file -- Swift lets you nest/scope types like
    /// this the same way you'd define a small helper class at module
    /// scope in a Python or TS test file, just without needing it to be
    /// importable from anywhere else.
    private struct FixtureItem {
        let guid: String
        /// `nil` writes SQL NULL -- the real schema allows it (`Rating
        /// float(22)`, no NOT NULL), though no real rows are NULL today.
        let rating: Int?
        let propGUIDs: [String]
        /// Full file path: folder (with trailing slash) plus file name,
        /// stored the way the real catalog splits them.
        let path: String

        init(guid: String = UUID().uuidString, rating: Int? = 0, propGUIDs: [String] = [], path: String? = nil) {
            self.guid = guid
            self.rating = rating
            self.propGUIDs = propGUIDs
            self.path = path ?? "/Volumes/Test/photos/\(guid).jpg"
        }
    }

    /// Writes `idCatalogItem` and `idCatalogItemDefinition` (the two
    /// tables rating/category filtering reads from -- see
    /// `docs/schema.md` and `docs/relationships.md`) to `fixturePath`,
    /// in WAL journal mode, matching the real catalog. `PhotoSupremeCatalog`
    /// opens readonly via a `DatabasePool`, which requires the database
    /// to already be in WAL mode.
    private func makeFixture(_ items: [FixtureItem]) throws {
        let dbQueue = try DatabaseQueue(path: fixturePath)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(
                sql: """
                    CREATE TABLE idCatalogItem (
                        GUID TEXT PRIMARY KEY,
                        Rating INTEGER,
                        PathGUID TEXT,
                        FileName TEXT
                    )
                    """)
            // The real catalog's absolute folder paths (trailing slash,
            // volume mount included), keyed by the photo's PathGUID.
            try db.execute(sql: "CREATE TABLE idCache_FilePath (FilePathGUID TEXT, FilePath TEXT)")
            try db.execute(
                sql: """
                    CREATE TABLE idCatalogItemDefinition (
                        GUID TEXT,
                        CatalogItemGUID TEXT,
                        PRIMARY KEY (GUID, CatalogItemGUID)
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE idProp (
                        GUID TEXT PRIMARY KEY,
                        ParentGUID TEXT,
                        PropName TEXT NOT NULL
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE idPropCategory (
                        GUID TEXT PRIMARY KEY,
                        CategoryName TEXT NOT NULL
                    )
                    """)
            for item in items {
                let fullPath = item.path
                let slash = fullPath.lastIndex(of: "/")!
                let folder = String(fullPath[...slash])
                let fileName = String(fullPath[fullPath.index(after: slash)...])
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idCache_FilePath WHERE FilePathGUID = ?", arguments: [folder]) == 0 {
                    try db.execute(
                        sql: "INSERT INTO idCache_FilePath (FilePathGUID, FilePath) VALUES (?, ?)",
                        arguments: [folder, folder])
                }
                try db.execute(
                    sql: "INSERT INTO idCatalogItem (GUID, Rating, PathGUID, FileName) VALUES (?, ?, ?, ?)",
                    arguments: [item.guid, item.rating, folder, fileName]
                )
                for propGUID in item.propGUIDs {
                    try db.execute(
                        sql: "INSERT INTO idCatalogItemDefinition (GUID, CatalogItemGUID) VALUES (?, ?)",
                        arguments: [propGUID, item.guid]
                    )
                }
            }
        }
    }

    private func insertProps(_ props: [(guid: String, name: String)]) throws {
        try insertProps(props.map { (guid: $0.guid, parentGUID: nil, name: $0.name) })
    }

    private func insertProps(_ props: [(guid: String, parentGUID: String?, name: String)]) throws {
        let dbQueue = try DatabaseQueue(path: fixturePath)
        try dbQueue.write { db in
            for prop in props {
                try db.execute(
                    sql: "INSERT INTO idProp (GUID, ParentGUID, PropName) VALUES (?, ?, ?)",
                    arguments: [prop.guid, prop.parentGUID, prop.name]
                )
            }
        }
    }

    private func insertPropCategories(_ categories: [(guid: String, name: String)]) throws {
        let dbQueue = try DatabaseQueue(path: fixturePath)
        try dbQueue.write { db in
            for category in categories {
                try db.execute(
                    sql: "INSERT INTO idPropCategory (GUID, CategoryName) VALUES (?, ?)",
                    arguments: [category.guid, category.name]
                )
            }
        }
    }

    // MARK: - Extent (row count / max rowid)

    func test_givenMissingFile_whenOpening_thenThrowsFileNotFound() {
        let missingPath = "/nonexistent/\(UUID().uuidString).sqlite"

        XCTAssertThrowsError(try PhotoSupremeCatalog(path: missingPath)) { error in
            XCTAssertEqual(error as? CatalogError, .fileNotFound(path: missingPath))
        }
    }

    func test_givenCatalogWithFiveRows_whenFetchingExtent_thenReturnsCountAndMaxRowID() async throws {
        try makeFixture((1...5).map { FixtureItem(guid: "item-\($0)") })
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let extent = try await catalog.catalogItemExtent()

        XCTAssertEqual(extent, CatalogExtent(rowCount: 5, maxRowID: 5))
    }

    func test_givenEmptyCatalog_whenFetchingExtent_thenMaxRowIDIsZeroNotNil() async throws {
        // MAX(rowid) over zero rows is SQL NULL, not 0 -- worth its own
        // test since a naive `row["maxRowID"]` read into a non-optional
        // Int would crash on that NULL instead of producing a sane value.
        try makeFixture([])
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let extent = try await catalog.catalogItemExtent()

        XCTAssertEqual(extent, CatalogExtent(rowCount: 0, maxRowID: 0))
    }

    // MARK: - matchingItemCount: no filter

    func test_givenNoFilter_whenCountingMatches_thenReturnsTotalRowCount() async throws {
        try makeFixture((1...4).map { FixtureItem(guid: "item-\($0)") })
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(for: SampleFilter())

        XCTAssertEqual(count, 4)
    }

    // MARK: - matchingItemCount: rating

    func test_givenRatingFilters_whenCountingMatches_thenComparesCorrectly() async throws {
        // One item per rating value 0...5.
        try makeFixture((0...5).map { (n: Int) in FixtureItem(guid: "item-\(n)", rating: n) })
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let exactlyThree = try await catalog.matchingItemCount(for: SampleFilter(rating: .exactly(3)))
        XCTAssertEqual(exactlyThree, 1, "exactly(3) should match only the rating-3 item")

        let atLeastThree = try await catalog.matchingItemCount(for: SampleFilter(rating: .atLeast(3)))
        XCTAssertEqual(atLeastThree, 3, "atLeast(3) should match ratings 3, 4, 5")

        let atMostTwo = try await catalog.matchingItemCount(for: SampleFilter(rating: .atMost(2)))
        XCTAssertEqual(atMostTwo, 3, "atMost(2) should match ratings 0, 1, 2")
    }

    // MARK: - matchingItemCount: category

    private func makeCategoryFixture() throws {
        // catA, catB, catC are arbitrary idProp.GUID stand-ins -- their
        // real form is a 32-char hex GUID (see docs/schema.md), but
        // nothing in the query cares about GUID *format*, only equality,
        // so short readable strings keep these tests legible.
        try makeFixture([
            FixtureItem(guid: "none", propGUIDs: []),
            FixtureItem(guid: "a-only", propGUIDs: ["catA"]),
            FixtureItem(guid: "a-and-b", propGUIDs: ["catA", "catB"]),
            FixtureItem(guid: "a-b-and-c", propGUIDs: ["catA", "catB", "catC"]),
            FixtureItem(guid: "b-only", propGUIDs: ["catB"]),
        ])
    }

    func test_givenCategoryModeAny_whenCountingMatches_thenMatchesItemsWithAtLeastOneProp() async throws {
        try makeCategoryFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(propGUIDs: ["catA", "catC"], mode: .any)))

        // a-only, a-and-b, a-b-and-c all carry catA; b-only and none do not.
        XCTAssertEqual(count, 3)
    }

    func test_givenCategoryModeAll_whenCountingMatches_thenMatchesOnlyItemsWithEveryProp() async throws {
        try makeCategoryFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(propGUIDs: ["catA", "catB"], mode: .all)))

        // Only a-and-b and a-b-and-c carry both catA and catB.
        XCTAssertEqual(count, 2)
    }

    func test_givenCategoryModeNone_whenCountingMatches_thenMatchesOnlyItemsWithoutAnyProp() async throws {
        try makeCategoryFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(propGUIDs: ["catA"], mode: .none)))

        // Only "none" and "b-only" lack catA.
        XCTAssertEqual(count, 2)
    }

    // MARK: - matchingItemCount: category, empty propGUIDs (vacuous cases)

    func test_givenEmptyPropGUIDsModeAny_whenCountingMatches_thenMatchesNothing() async throws {
        try makeCategoryFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .any)))

        XCTAssertEqual(count, 0, "\"has any of no categories\" is vacuously false")
    }

    func test_givenEmptyPropGUIDsModeAll_whenCountingMatches_thenMatchesEverything() async throws {
        try makeCategoryFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .all)))

        XCTAssertEqual(count, 5, "\"has all of no categories\" is vacuously true")
    }

    func test_givenEmptyPropGUIDsModeNone_whenCountingMatches_thenMatchesEverything() async throws {
        try makeCategoryFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .none)))

        XCTAssertEqual(count, 5, "\"has none of no categories\" is vacuously true")
    }

    func test_givenAnAssignmentRowWithNoPhotoGUID_whenCountingNoneOfACategory_thenOtherPhotosStillMatch() async throws {
        // The real schema doesn't declare CatalogItemGUID NOT NULL (none
        // are NULL today). A single NULL must not make "none of" match
        // nothing -- the classic SQL `NOT IN` + NULL trap.
        try makeCategoryFixture()
        let dbQueue = try DatabaseQueue(path: fixturePath)
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO idCatalogItemDefinition (GUID, CatalogItemGUID) VALUES ('catA', NULL)")
        }
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(propGUIDs: ["catA"], mode: .none)))

        XCTAssertEqual(count, 2, "only \"none\" and \"b-only\" lack catA")
    }

    // MARK: - matchingItemCount: category branches (a selection plus its descendants)

    /// Two branches, each a parent keyword plus its children:
    /// pines = {pines, smooth, tan}, places = {places, lake}.
    /// Photos are tagged only with child keywords, never the parent --
    /// the shape the real catalog actually has.
    private let pinesBranch = CategoryBranch(rootGUID: "pines", propGUIDs: ["pines", "smooth", "tan"])
    private let clothesBranch = CategoryBranch(rootGUID: "places", propGUIDs: ["lake", "places"])

    private func makeBranchFixture() throws {
        try makeFixture([
            FixtureItem(guid: "untagged", propGUIDs: []),
            FixtureItem(guid: "smooth-only", propGUIDs: ["smooth"]),
            FixtureItem(guid: "smooth-and-tan", propGUIDs: ["smooth", "tan"]),
            FixtureItem(guid: "tan-and-lake", propGUIDs: ["tan", "lake"]),
            FixtureItem(guid: "lake-only", propGUIDs: ["lake"]),
        ])
    }

    func test_givenAnyOfABranch_whenOnlyChildKeywordsAreTagged_thenThosePhotosMatch() async throws {
        try makeBranchFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(branches: [pinesBranch], mode: .any)))

        XCTAssertEqual(count, 3, "smooth-only, smooth-and-tan, tan-and-lake carry a pines keyword")
    }

    func test_givenAllOfTwoBranches_whenCountingMatches_thenAPhotoNeedsOneKeywordFromEachBranch() async throws {
        try makeBranchFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(branches: [pinesBranch, clothesBranch], mode: .all)))

        // smooth-and-tan has two keywords, but both from the pines branch:
        // not a match. Only tan-and-lake touches both branches.
        XCTAssertEqual(count, 1)
    }

    func test_givenAllOfOneBranch_whenCountingMatches_thenAnyKeywordInTheBranchIsEnough() async throws {
        // "All of [Pines]" must not demand every keyword under Pines.
        try makeBranchFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(branches: [pinesBranch], mode: .all)))

        XCTAssertEqual(count, 3)
    }

    func test_givenNoneOfABranch_whenCountingMatches_thenPhotosTaggedWithADescendantAreExcluded() async throws {
        try makeBranchFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(category: CategoryFilter(branches: [pinesBranch], mode: .none)))

        XCTAssertEqual(count, 2, "only untagged and lake-only have no pines keyword")
    }

    // MARK: - matchingItemCount: rule groups (all / any / none of, nested)

    /// One photo per rating 1...5, plus an unrated-NULL photo; the
    /// 4- and 5-star photos also carry catA.
    private func makeRuleGroupFixture() throws {
        try makeFixture([
            FixtureItem(guid: "r1", rating: 1),
            FixtureItem(guid: "r2", rating: 2),
            FixtureItem(guid: "r3", rating: 3),
            FixtureItem(guid: "r4-a", rating: 4, propGUIDs: ["catA"]),
            FixtureItem(guid: "r5-a", rating: 5, propGUIDs: ["catA"]),
            FixtureItem(guid: "null-rating", rating: nil),
        ])
    }

    private func count(_ root: RuleGroup) async throws -> Int {
        try await PhotoSupremeCatalog(path: fixturePath).matchingItemCount(for: SampleFilter(root: root))
    }

    func test_givenAnAnyOfGroup_whenCountingMatches_thenAPhotoMatchingEitherRuleCounts() async throws {
        try makeRuleGroupFixture()

        let matches = try await count(
            RuleGroup(match: .any, rules: [.rating(.exactly(1)), .rating(.exactly(5))]))

        XCTAssertEqual(matches, 2)
    }

    func test_givenANoneOfGroup_whenCountingMatches_thenPhotosMatchingAnyRuleAreExcluded() async throws {
        try makeRuleGroupFixture()

        let matches = try await count(
            RuleGroup(match: .none, rules: [.rating(.atLeast(4)), .rating(.exactly(1))]))

        XCTAssertEqual(matches, 3, "r2, r3, and the NULL-rated photo")
    }

    func test_givenANullRating_whenCountingNoneOfARatingRule_thenThePhotoIsNotExcluded() async throws {
        // SQL's three-valued logic: `NOT (Rating >= 3)` is NULL, not
        // true, for a NULL rating -- so a naive NOT would drop the photo
        // from both "rating >= 3" and "none of [rating >= 3]". An unknown
        // result counts as "didn't match", so "none of" must keep it.
        try makeRuleGroupFixture()

        let matchesRule = try await count(RuleGroup(match: .all, rules: [.rating(.atLeast(3))]))
        let matchesNoneOf = try await count(RuleGroup(match: .none, rules: [.rating(.atLeast(3))]))

        XCTAssertEqual(matchesRule + matchesNoneOf, 6, "every photo lands on exactly one side")
    }

    func test_givenANestedGroup_whenCountingMatches_thenItCombinesWithItsParent() async throws {
        // all of: [ rating >= 3, none of: [ has catA ] ] -- i.e. 3+ stars
        // but not tagged catA.
        try makeRuleGroupFixture()

        let matches = try await count(
            RuleGroup(
                match: .all,
                rules: [
                    .rating(.atLeast(3)),
                    .group(RuleGroup(match: .none, rules: [.category(CategoryFilter(propGUIDs: ["catA"], mode: .any))])),
                ]))

        XCTAssertEqual(matches, 1, "only r3")
    }

    func test_givenEmptyGroups_whenCountingMatches_thenAnyOfMatchesNothingAndAllOrNoneOfMatchEverything() async throws {
        try makeRuleGroupFixture()

        let anyOfNothing = try await count(RuleGroup(match: .any, rules: []))
        let allOfNothing = try await count(RuleGroup(match: .all, rules: []))
        let noneOfNothing = try await count(RuleGroup(match: .none, rules: []))

        XCTAssertEqual(anyOfNothing, 0)
        XCTAssertEqual(allOfNothing, 6)
        XCTAssertEqual(noneOfNothing, 6)
    }

    // MARK: - matchingItemCount: file path

    /// Paths shaped like the real catalog's: an absolute folder on an
    /// external volume, then the file name.
    private func makePathFixture() throws {
        try makeFixture([
            FixtureItem(guid: "trip", path: "/Volumes/Photos/library/photos/Travel/2019/IMG_1.jpg"),
            FixtureItem(guid: "trip-png", path: "/Volumes/Photos/library/photos/Travel/2019/scan.png"),
            FixtureItem(guid: "not-a-year", path: "/Volumes/Photos/library/photos/Travel/2019-extra/IMG_2.jpg"),
            FixtureItem(guid: "underscore", path: "/Volumes/Photos/library/photos/Portraits/O/LE_Photo_T_4.jpg"),
            FixtureItem(guid: "no-underscore", path: "/Volumes/Photos/library/photos/Portraits/O/LEXPhoto.jpg"),
            FixtureItem(guid: "percent", path: "/Volumes/Photos/library/photos/100% crop/a.jpg"),
            FixtureItem(guid: "curly", path: "/Volumes/Photos/library/photos/Lil’ Black Dress/b.jpg"),
            FixtureItem(guid: "elsewhere", path: "/Volumes/Other/c.jpg"),
        ])
    }

    private func pathCount(_ kind: PathMatchKind, _ text: String) async throws -> Int {
        try await PhotoSupremeCatalog(path: fixturePath).matchingItemCount(
            for: SampleFilter(root: RuleGroup(match: .all, rules: [.path(PathFilter(kind: kind, text: text))])))
    }

    func test_givenAPathContainsRule_whenCountingMatches_thenOnlyPathsWithThatTextMatch() async throws {
        try makePathFixture()

        let matches = try await pathCount(.contains, "/2019/")

        XCTAssertEqual(matches, 2, "trip and trip-png; /2019-extra/ doesn't contain /2019/")
    }

    func test_givenAPathStartsWithRule_whenCountingMatches_thenOnlyPathsUnderThatPrefixMatch() async throws {
        try makePathFixture()

        let matches = try await pathCount(.startsWith, "/Volumes/Photos/library/photos/Portraits/")

        XCTAssertEqual(matches, 2)
    }

    func test_givenAPathEndsWithRule_whenCountingMatches_thenTheFileNameEndingDecides() async throws {
        try makePathFixture()

        let matches = try await pathCount(.endsWith, ".png")

        XCTAssertEqual(matches, 1)
    }

    func test_givenTextThatSpansFolderAndFileName_whenCountingMatches_thenTheFullPathIsSearched() async throws {
        // The folder and the file name are stored separately; the rule
        // must see them joined, or this would match nothing.
        try makePathFixture()

        let matches = try await pathCount(.contains, "2019/IMG_")

        XCTAssertEqual(matches, 1)
    }

    func test_givenDifferentLetterCase_whenCountingMatches_thenPathMatchingIgnoresCase() async throws {
        try makePathFixture()

        let matches = try await pathCount(.contains, "/travel/")

        XCTAssertEqual(matches, 3)
    }

    func test_givenAnUnderscore_whenCountingMatches_thenItMatchesOnlyALiteralUnderscore() async throws {
        // `_` is a one-character wildcard in SQL LIKE; real file names are
        // full of underscores, so unescaped it would silently over-match.
        try makePathFixture()

        let matches = try await pathCount(.contains, "LE_Photo")

        XCTAssertEqual(matches, 1, "not LEXPhoto")
    }

    func test_givenAPercentSign_whenCountingMatches_thenItMatchesOnlyALiteralPercent() async throws {
        try makePathFixture()

        let matches = try await pathCount(.contains, "100% crop")

        XCTAssertEqual(matches, 1)
    }

    func test_givenNonASCIIText_whenCountingMatches_thenItMatchesExactly() async throws {
        try makePathFixture()

        let matches = try await pathCount(.contains, "Lil’ Black")

        XCTAssertEqual(matches, 1)
    }

    func test_givenEmptyText_whenCountingMatches_thenEveryPathMatches() async throws {
        try makePathFixture()

        let matches = try await pathCount(.contains, "")

        XCTAssertEqual(matches, 8)
    }

    func test_givenANoneOfGroupWithAPathRule_whenCountingMatches_thenThosePathsAreExcluded() async throws {
        try makePathFixture()

        let matches = try await PhotoSupremeCatalog(path: fixturePath).matchingItemCount(
            for: SampleFilter(
                root: RuleGroup(match: .none, rules: [.path(PathFilter(kind: .contains, text: "/Travel/"))])))

        XCTAssertEqual(matches, 5)
    }

    // MARK: - matchingItemCount: combined rating + category

    func test_givenRatingAndCategoryFilters_whenCountingMatches_thenBothMustMatch() async throws {
        try makeFixture([
            FixtureItem(guid: "high-rated-with-cat", rating: 5, propGUIDs: ["catA"]),
            FixtureItem(guid: "high-rated-without-cat", rating: 5, propGUIDs: []),
            FixtureItem(guid: "low-rated-with-cat", rating: 1, propGUIDs: ["catA"]),
        ])
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let count = try await catalog.matchingItemCount(
            for: SampleFilter(
                rating: .atLeast(4),
                category: CategoryFilter(propGUIDs: ["catA"], mode: .any)
            ))

        XCTAssertEqual(count, 1, "only high-rated-with-cat satisfies both constraints")
    }

    // MARK: - sampleGUIDs

    func test_givenNoFilter_whenSamplingFewerThanAvailable_thenReturnsThatManyDistinctGUIDs() async throws {
        try makeFixture((1...50).map { FixtureItem(guid: "item-\($0)") })
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let guids = try await catalog.sampleGUIDs(count: 10)

        XCTAssertEqual(guids.count, 10)
        XCTAssertEqual(Set(guids).count, 10, "no duplicates")
        for guid in guids {
            XCTAssertTrue(guid.hasPrefix("item-"), "every result should come from the fixture")
        }
    }

    // Run many trials rather than one: the underlying algorithm is
    // genuinely randomized (see PhotoSupremeCatalog.sampleGUIDs), so a
    // single run passing proves very little -- a bug here manifests as
    // an occasional, low-probability miss (high density + a tiny
    // remaining shortfall shrinks the oversample batch enough that a
    // specific still-needed rowid can be missed across all retry
    // attempts), not a guaranteed failure. 200 trials gives >99.99%
    // confidence of catching a bug with even a 5% chance of firing per
    // trial ((0.95)^200 ≈ 0.000035), while still running in well under a
    // second against a 5-row fixture.
    func test_givenCountExceedsMatchingRows_whenSampling_thenReturnsEveryMatchOnceNotMore() async throws {
        try makeFixture((1...5).map { FixtureItem(guid: "item-\($0)") })
        let catalog = try PhotoSupremeCatalog(path: fixturePath)
        let expected = Set((1...5).map { "item-\($0)" })

        for trial in 1...200 {
            let guids = try await catalog.sampleGUIDs(count: 1000)
            XCTAssertEqual(Set(guids), expected, "trial \(trial) undersampled: got \(guids.sorted())")
        }
    }

    func test_givenRatingFilter_whenSampling_thenEveryResultSatisfiesTheFilter() async throws {
        try makeFixture((0...5).map { (n: Int) in FixtureItem(guid: "item-\(n)", rating: n) })
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let guids = try await catalog.sampleGUIDs(count: 3, matching: SampleFilter(rating: .atLeast(3)))

        XCTAssertEqual(Set(guids), Set(["item-3", "item-4", "item-5"]))
    }

    func test_givenCategoryFilter_whenSampling_thenEveryResultSatisfiesTheFilter() async throws {
        try makeCategoryFixture()
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let guids = try await catalog.sampleGUIDs(
            count: 10,
            matching: SampleFilter(category: CategoryFilter(propGUIDs: ["catA", "catB"], mode: .all))
        )

        // makeCategoryFixture's only items with both catA and catB.
        XCTAssertEqual(Set(guids), Set(["a-and-b", "a-b-and-c"]))
    }

    func test_givenFilterMatchingNothing_whenSampling_thenReturnsEmpty() async throws {
        try makeFixture((1...20).map { FixtureItem(guid: "item-\($0)", rating: 0) })
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let guids = try await catalog.sampleGUIDs(count: 5, matching: SampleFilter(rating: .atLeast(1)))

        XCTAssertEqual(guids, [])
    }

    func test_givenEmptyCatalog_whenSampling_thenReturnsEmpty() async throws {
        try makeFixture([])
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let guids = try await catalog.sampleGUIDs(count: 5)

        XCTAssertEqual(guids, [])
    }

    // MARK: - listPropTree (category picker data source)

    func test_givenNoCategories_whenListingPropTree_thenReturnsEmpty() async throws {
        try makeFixture([])
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let tree = try await catalog.listPropTree()

        XCTAssertEqual(tree, [])
    }

    func test_givenCategoriesAndNestedProps_whenListingPropTree_thenBuildsTheFullHierarchy() async throws {
        try makeFixture([])
        try insertPropCategories([
            (guid: "cat-places", name: "Places"),
            (guid: "cat-nature", name: "Nature"),
        ])
        try insertProps([
            (guid: "prop-pines", parentGUID: "cat-nature", name: "Pines"),
            (guid: "prop-tall-pines", parentGUID: "prop-pines", name: "Tall Pines"),
        ])
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let tree = try await catalog.listPropTree()

        XCTAssertEqual(tree.map(\.name), ["Nature", "Places"])
        let body = try XCTUnwrap(tree.first { $0.name == "Nature" })
        XCTAssertEqual(body.children.map(\.name), ["Pines"])
        XCTAssertEqual(body.children[0].children.map(\.name), ["Tall Pines"])
    }

    /// Confirmed against the real catalog and by the user directly: the
    /// six built-in categories Photo Supreme ships with (their GUIDs are
    /// the classic brace-wrapped `{XXXXXXXX-XXXX-...}` form, unlike
    /// every user-created prop/category's plain 32-char hex GUID) are
    /// unused here on purpose, and should be excluded from the picker --
    /// same filter an earlier Rust tool
    /// (`~/Projects/rust/lusia`) applied for the same
    /// reason.
    func test_givenBuiltInCategoryWithBraceWrappedGUID_whenListingPropTree_thenExcludesIt() async throws {
        try makeFixture([])
        try insertPropCategories([
            (guid: "{2AD216A8-9A52-482B-87A1-547F0D6C6F6B}", name: "Objects"),
            (guid: "cat-nature", name: "Nature"),
        ])
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let tree = try await catalog.listPropTree()

        XCTAssertEqual(tree.map(\.name), ["Nature"])
    }
}
