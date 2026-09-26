import SwiftUI
import XCTest

@testable import SupremeSampler

/// Specifies the script preview's colors: the highlighted text is exactly
/// the script, each kind of token has its own color, and plain text keeps
/// the view's default color (so it follows light and dark mode).
final class ScriptHighlighterTests: XCTestCase {
    private let sample = """
        { Header }
        const
          SAMPLE_SIZE = 100;
        // note
        q := 'SELECT 1';
        """

    func test_givenAScript_whenHighlighting_thenTheTextIsTheScriptExactly() {
        let highlighted = ScriptHighlighter.highlight(sample)
        XCTAssertEqual(String(highlighted.characters), sample)
    }

    func test_givenAScript_whenHighlighting_thenEachTokenIsColoredByItsKind() {
        let highlighted = ScriptHighlighter.highlight(sample)

        // `runs` are the stretches of text sharing the same attributes.
        var colorByText: [String: Color?] = [:]
        for run in highlighted.runs {
            colorByText[String(highlighted[run.range].characters)] = run.foregroundColor
        }

        XCTAssertEqual(colorByText["{ Header }"], ScriptHighlighter.color(for: .comment))
        XCTAssertEqual(colorByText["const"], ScriptHighlighter.color(for: .keyword))
        XCTAssertEqual(colorByText["100"], ScriptHighlighter.color(for: .number))
        XCTAssertEqual(colorByText["// note"], ScriptHighlighter.color(for: .comment))
        XCTAssertEqual(colorByText["'SELECT 1'"], ScriptHighlighter.color(for: .string))
    }

    func test_givenPlainText_whenHighlighting_thenItHasNoColorOfItsOwn() {
        XCTAssertNil(ScriptHighlighter.color(for: .plain))
        let highlighted = ScriptHighlighter.highlight("AExtentSet.OpenSet;")
        XCTAssertEqual(highlighted.runs.map(\.foregroundColor), [nil])
    }

    func test_givenEachColoredKind_whenChoosingColors_thenNoTwoKindsShareOne() {
        let colors = [PascalToken.Kind.keyword, .comment, .string, .number]
            .compactMap(ScriptHighlighter.color(for:))
        XCTAssertEqual(colors.count, 4)
        XCTAssertEqual(Set(colors).count, 4)
    }
}
