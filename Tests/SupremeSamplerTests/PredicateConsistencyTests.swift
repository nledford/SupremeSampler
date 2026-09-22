import GRDB
import XCTest

@testable import SupremeSampler

/// `SQLPredicateText` (plain-text SQL, for generated `.psc` scripts) and
/// `PhotoSupremeCatalog`'s private predicate builder (GRDB-parameterized
/// SQL, for live queries) are two independent implementations of the
/// same filtering rules -- see `SQLPredicateText`'s doc comment for why
/// they're kept separate rather than unified. Swift's exhaustive
/// `switch` catches one class of drift between them for free (a new
/// `RatingFilter`/`CategoryMatchMode` case left unhandled in either file
/// is a compile error), but not a *semantic* change to an existing case
/// made in one file and not the other.
///
/// This file closes that gap empirically: for a range of filters, it
/// runs `SQLPredicateText`'s rendered SQL as a raw query against a
/// fixture -- the same thing a generated script would do -- and asserts
/// the resulting count matches `PhotoSupremeCatalog.matchingItemCount`
/// exactly. If the two implementations ever disagree about which rows a
/// filter matches, this fails; nothing else in the test suite would
/// catch that, since `SQLPredicateTextTests` and `PhotoSupremeCatalogTests`
/// each only check their own implementation in isolation.
final class PredicateConsistencyTests: XCTestCase {
    private var fixturePath: String!

    override func setUpWithError() throws {
        fixturePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: fixturePath)
    }

    private struct FixtureItem {
        let guid: String
        let rating: Int
        let propGUIDs: [String]
    }

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
                        GUID TEXT NOT NULL,
                        CatalogItemGUID TEXT NOT NULL,
                        PRIMARY KEY (GUID, CatalogItemGUID)
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

    /// Runs `SQLPredicateText.render(filter)` as a raw query, the same
    /// way `RandomSampleScriptGenerator`'s output would when pasted into
    /// Photo Supreme -- deliberately bypassing GRDB's parameter binding
    /// to exercise the literal-SQL path for real, not just call the
    /// renderer and inspect the string.
    private func rawTextMatchingCount(_ filter: SampleFilter) throws -> Int {
        let dbQueue = try DatabaseQueue(path: fixturePath, configuration: {
            var config = Configuration()
            config.readonly = true
            return config
        }())
        let predicate = SQLPredicateText.render(filter) ?? "1 = 1"
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idCatalogItem WHERE \(predicate)") ?? 0
        }
    }

    func test_givenVariousFilters_whenComparingBothImplementations_thenCountsAgree() throws {
        try makeFixture([
            FixtureItem(guid: "none-r0", rating: 0, propGUIDs: []),
            FixtureItem(guid: "a-r2", rating: 2, propGUIDs: ["catA"]),
            FixtureItem(guid: "ab-r3", rating: 3, propGUIDs: ["catA", "catB"]),
            FixtureItem(guid: "abc-r5", rating: 5, propGUIDs: ["catA", "catB", "catC"]),
            FixtureItem(guid: "b-r5", rating: 5, propGUIDs: ["catB"]),
        ])
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let filters: [SampleFilter] = [
            SampleFilter(),
            SampleFilter(rating: .exactly(5)),
            SampleFilter(rating: .atLeast(3)),
            SampleFilter(rating: .atMost(2)),
            SampleFilter(category: CategoryFilter(propGUIDs: ["catA"], mode: .any)),
            SampleFilter(category: CategoryFilter(propGUIDs: ["catA", "catB"], mode: .all)),
            SampleFilter(category: CategoryFilter(propGUIDs: ["catA"], mode: .none)),
            SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .any)),
            SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .all)),
            SampleFilter(
                rating: .atLeast(3),
                category: CategoryFilter(propGUIDs: ["catB"], mode: .any)
            ),
        ]

        for filter in filters {
            let viaGRDB = try catalog.matchingItemCount(for: filter)
            let viaRawText = try rawTextMatchingCount(filter)
            XCTAssertEqual(
                viaGRDB, viaRawText,
                "PhotoSupremeCatalog and SQLPredicateText disagree for filter \(filter)")
        }
    }
}
