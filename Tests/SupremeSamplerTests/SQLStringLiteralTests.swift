import GRDB
import XCTest

@testable import SupremeSampler

/// Specifies how a text value (a label name, a path fragment) is written
/// into a generated script's SQL: always as pure ASCII. Every script so
/// far has been ASCII, and it's unknown how Script Studio decodes a
/// BOM-less file -- a Delphi-lineage tool may assume the system code
/// page, which would garble "選択" into something that silently matches
/// nothing. SQLite's `char(...)` builds any character from its code
/// point, so non-ASCII never has to appear as raw bytes.
final class SQLStringLiteralTests: XCTestCase {
    func test_givenPlainASCII_whenRendering_thenItIsAQuotedLiteral() {
        XCTAssertEqual(SQLStringLiteral.render("Approved"), "'Approved'")
    }

    func test_givenASingleQuote_whenRendering_thenItIsDoubled() {
        XCTAssertEqual(SQLStringLiteral.render("O'Brien"), "'O''Brien'")
    }

    func test_givenAnEmptyString_whenRendering_thenItIsAnEmptyLiteral() {
        XCTAssertEqual(SQLStringLiteral.render(""), "''")
    }

    func test_givenNonASCIIText_whenRendering_thenItIsBuiltFromCodePoints() {
        XCTAssertEqual(SQLStringLiteral.render("選択"), "char(36984, 25246)")
    }

    func test_givenMixedText_whenRendering_thenASCIIRunsStayReadable() {
        XCTAssertEqual(SQLStringLiteral.render("Lil’ Black"), "'Lil' || char(8217) || ' Black'")
    }

    func test_givenAControlCharacter_whenRendering_thenItIsAlsoACodePoint() {
        XCTAssertEqual(SQLStringLiteral.render("a\tb"), "'a' || char(9) || 'b'")
    }

    func test_givenTrickyStrings_whenRenderedAndEvaluatedBySQLite_thenTheOriginalComesBack() throws {
        let dbQueue = try DatabaseQueue()
        for value in [
            "", "plain", "O'Brien", "''", "選択", "第 2 候補", "Lil’ Black Dress", "a\tb\nc",
            "$$$/Bridge/Preferences/Label/Red=Select", "emoji 📷 end", "Grün", "%_\\",
        ] {
            let literal = SQLStringLiteral.render(value)
            XCTAssertTrue(literal.allSatisfy(\.isASCII), "non-ASCII in \(literal)")
            let roundTripped = try dbQueue.read { try String.fetchOne($0, sql: "SELECT \(literal)") }
            XCTAssertEqual(roundTripped, value, "via \(literal)")
        }
    }
}
