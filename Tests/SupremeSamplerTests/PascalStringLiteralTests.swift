import XCTest

@testable import SupremeSampler

final class PascalStringLiteralTests: XCTestCase {
    func test_givenPlainText_whenEscaping_thenWrapsInSingleQuotes() {
        XCTAssertEqual(PascalStringLiteral.escape("Rating >= 3"), "'Rating >= 3'")
    }

    func test_givenEmptyText_whenEscaping_thenProducesEmptyPascalLiteral() {
        XCTAssertEqual(PascalStringLiteral.escape(""), "''")
    }

    func test_givenTextWithSingleQuote_whenEscaping_thenDoublesIt() {
        // Pascal escapes an embedded ' by doubling it, the same idea as
        // Rust/Python/TS escaping a quote with a backslash, just a
        // different escape character.
        XCTAssertEqual(PascalStringLiteral.escape("O'Brien"), "'O''Brien'")
    }

    func test_givenTextWithMultipleQuotes_whenEscaping_thenDoublesEachOne() {
        XCTAssertEqual(PascalStringLiteral.escape("'a' and 'b'"), "'''a'' and ''b'''")
    }
}
