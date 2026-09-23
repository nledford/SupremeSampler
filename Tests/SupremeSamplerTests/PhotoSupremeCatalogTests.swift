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
        let rating: Int
        let propGUIDs: [String]

        init(guid: String = UUID().uuidString, rating: Int = 0, propGUIDs: [String] = []) {
            self.guid = guid
            self.rating = rating
            self.propGUIDs = propGUIDs
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
                        Rating INTEGER NOT NULL DEFAULT 0
                    )
                    """)
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
                try db.execute(
                    sql: "INSERT INTO idCatalogItem (GUID, Rating) VALUES (?, ?)",
                    arguments: [item.guid, item.rating]
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
        try makeFixture((0...5).map { FixtureItem(guid: "item-\($0)", rating: $0) })
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
        try makeFixture((0...5).map { FixtureItem(guid: "item-\($0)", rating: $0) })
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
