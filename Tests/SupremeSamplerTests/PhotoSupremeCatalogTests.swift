import GRDB
import XCTest

@testable import SupremeSampler

// BDD-style: each test name reads as Given/When/Then. XCTest has no
// describe/it blocks like Jest or Python's pytest-bdd -- discovery is by
// subclassing XCTestCase and a `test` name prefix (see
// PlaceholderTests.swift's old comment, now removed along with the file
// it was in) -- so the Given/When/Then goes in the method name itself.
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

    /// Writes a minimal `idCatalogItem` table with `rowCount` rows
    /// (rowids 1...rowCount) to `fixturePath`, in WAL journal mode --
    /// matching the real Photo Supreme catalog (see
    /// `~/Pictures/Photo Supreme/docs/README.md`), since
    /// `PhotoSupremeCatalog` opens readonly via a `DatabasePool`, which
    /// requires the database to already be in WAL mode.
    private func makeFixture(rowCount: Int) throws {
        let dbQueue = try DatabaseQueue(path: fixturePath)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "CREATE TABLE idCatalogItem (GUID TEXT PRIMARY KEY)")
            for _ in 0..<rowCount {
                try db.execute(
                    sql: "INSERT INTO idCatalogItem (GUID) VALUES (?)",
                    arguments: [UUID().uuidString]
                )
            }
        }
    }

    func test_givenMissingFile_whenOpening_thenThrowsFileNotFound() {
        let missingPath = "/nonexistent/\(UUID().uuidString).sqlite"

        XCTAssertThrowsError(try PhotoSupremeCatalog(path: missingPath)) { error in
            XCTAssertEqual(error as? CatalogError, .fileNotFound(path: missingPath))
        }
    }

    func test_givenCatalogWithFiveRows_whenFetchingExtent_thenReturnsCountAndMaxRowID() throws {
        try makeFixture(rowCount: 5)
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let extent = try catalog.catalogItemExtent()

        XCTAssertEqual(extent, CatalogExtent(rowCount: 5, maxRowID: 5))
    }

    func test_givenEmptyCatalog_whenFetchingExtent_thenMaxRowIDIsZeroNotNil() throws {
        // MAX(rowid) over zero rows is SQL NULL, not 0 -- worth its own
        // test since a naive `row["maxRowID"]` read into a non-optional
        // Int would crash on that NULL instead of producing a sane value.
        try makeFixture(rowCount: 0)
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let extent = try catalog.catalogItemExtent()

        XCTAssertEqual(extent, CatalogExtent(rowCount: 0, maxRowID: 0))
    }
}
