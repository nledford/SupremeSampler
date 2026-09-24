import GRDB
import XCTest

@testable import SupremeSampler

/// The escaping every `LIKE ... ESCAPE '\'` pattern in the app relies on,
/// checked against SQLite itself rather than against a copy of the rule.
final class LikePatternTests: XCTestCase {
    private func sqliteLike(_ value: String, _ pattern: String) throws -> Bool {
        let dbQueue = try DatabaseQueue()
        return try dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT ? LIKE ? ESCAPE '\\'", arguments: [value, pattern]) ?? false
        }
    }

    func test_givenWildcardsAndBackslashes_whenEscaped_thenSQLiteMatchesThemLiterally() throws {
        for text in ["100%", "a_b", "x\\y", "\\", "%_\\"] {
            let pattern = "%" + LikePattern.escape(text) + "%"
            XCTAssertTrue(try sqliteLike("[" + text + "]", pattern), text)
        }
        XCTAssertFalse(try sqliteLike("1000", "%" + LikePattern.escape("1%0") + "%"))
        XCTAssertFalse(try sqliteLike("axb", "%" + LikePattern.escape("a_b") + "%"))
        XCTAssertFalse(try sqliteLike("xy", "%" + LikePattern.escape("x\\y") + "%"))
    }
}
