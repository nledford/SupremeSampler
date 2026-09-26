import XCTest

@testable import SupremeSampler

/// Specifies how `.psc` source is split into runs for the script preview's
/// syntax highlighting: keywords, comments, string literals and numbers,
/// with everything else plain. The preview must show exactly the script
/// that will be saved, so tokenizing never adds, drops or reorders text.
final class PascalTokenizerTests: XCTestCase {
    /// The highlighted runs as "kind:text", leaving out plain text, so each
    /// test reads as just the parts that get a color.
    private func colored(_ source: String) -> [String] {
        PascalTokenizer.tokenize(source)
            .filter { $0.kind != .plain }
            .map { "\($0.kind):\($0.text)" }
    }

    private func rejoined(_ source: String) -> String {
        PascalTokenizer.tokenize(source).map(\.text).joined()
    }

    // MARK: - Lossless

    func test_givenAnySource_whenTokenizing_thenTheTokensRejoinToTheSourceExactly() {
        let sources = [
            "",
            "begin\n  result := 'a''b'; // done\nend;",
            "{ unterminated comment",
            "x := 'unterminated string\ny := 2;",
            "(* star comment *) 1.15 ROWID2",
        ]
        for source in sources {
            XCTAssertEqual(rejoined(source), source)
        }
    }

    func test_givenPlainText_whenTokenizing_thenAdjacentPlainTextIsOneRun() {
        let tokens = PascalTokenizer.tokenize("AExtentSet.OpenSet;")
        XCTAssertEqual(tokens.map(\.kind), [.plain])
    }

    // MARK: - Keywords

    func test_givenKeywordsInAnyCase_whenTokenizing_thenEachIsAKeyword() {
        XCTAssertEqual(colored("BEGIN end Begin"), ["keyword:BEGIN", "keyword:end", "keyword:Begin"])
    }

    func test_givenAKeywordInsideAnIdentifier_whenTokenizing_thenItIsPlain() {
        XCTAssertEqual(colored("beginning AEnd TStringList ForEach _if"), [])
    }

    func test_givenBooleanAndNilLiterals_whenTokenizing_thenTheyAreKeywords() {
        XCTAssertEqual(colored("True false nil"), ["keyword:True", "keyword:false", "keyword:nil"])
    }

    // MARK: - Comments

    func test_givenALineComment_whenTokenizing_thenItRunsToTheEndOfTheLineOnly() {
        XCTAssertEqual(colored("x; // note\nend;"), ["comment:// note", "keyword:end"])
    }

    func test_givenABraceComment_whenTokenizing_thenItSpansLines() {
        XCTAssertEqual(colored("{\n  Header\n}\nconst"), ["comment:{\n  Header\n}", "keyword:const"])
    }

    func test_givenAStarComment_whenTokenizing_thenItIsOneComment() {
        XCTAssertEqual(colored("(* a *) var"), ["comment:(* a *)", "keyword:var"])
    }

    func test_givenAnApostropheInAComment_whenTokenizing_thenNoStringStarts() {
        XCTAssertEqual(colored("// it's fine\nbegin"), ["comment:// it's fine", "keyword:begin"])
    }

    func test_givenAnUnterminatedBraceComment_whenTokenizing_thenItRunsToTheEnd() {
        XCTAssertEqual(colored("{ never closed\nbegin"), ["comment:{ never closed\nbegin"])
    }

    // MARK: - Strings

    func test_givenADoubledQuote_whenTokenizing_thenItStaysInsideOneString() {
        XCTAssertEqual(colored("s := 'O''Brien';"), ["string:'O''Brien'"])
    }

    func test_givenAnEmptyString_whenTokenizing_thenItIsAString() {
        XCTAssertEqual(colored("s := '';"), ["string:''"])
    }

    /// Generated SQL lives inside Pascal strings, and contains characters
    /// that would start a comment outside one.
    func test_givenCommentMarkersInsideAString_whenTokenizing_thenTheyStayString() {
        XCTAssertEqual(
            colored("q := 'a { b } // c (* d';"),
            ["string:'a { b } // c (* d'"])
    }

    func test_givenAnUnterminatedString_whenTokenizing_thenItEndsAtTheLineBreak() {
        XCTAssertEqual(colored("s := 'open\nend;"), ["string:'open", "keyword:end"])
    }

    // MARK: - Numbers

    func test_givenIntegersAndDecimals_whenTokenizing_thenEachIsANumber() {
        XCTAssertEqual(colored("N = 10000; M = 1.15;"), ["number:10000", "number:1.15"])
    }

    func test_givenDigitsInsideAnIdentifier_whenTokenizing_thenTheyArePlain() {
        XCTAssertEqual(colored("ROWID2 A1B"), [])
    }

    func test_givenAMethodCallOnANumberlessName_whenTokenizing_thenTheDotIsNotADecimal() {
        XCTAssertEqual(colored("x := 1 + A.B;"), ["number:1"])
    }

    // MARK: - Generated scripts

    /// Every script the generator can emit, not just hand-written samples:
    /// the text round-trips, and no quote or brace is left in plain text
    /// (one would mean a string or comment was missed and the colors after
    /// it are shifted).
    func test_givenGeneratedScripts_whenTokenizing_thenEveryStringAndCommentIsRecognized() {
        let filters: [SampleFilter] = [
            SampleFilter(root: RuleGroup(match: .all, rules: [])),
            SampleFilter(root: RuleGroup(match: .all, rules: [
                .rating(.isNot(0)),
                .path(PathFilter(kind: .contains, text: "O'Brien {draft} // x", negated: true)),
                .keywordPath(KeywordPathFilter(kind: .hasPart, text: "Lil’ Trees")),
            ])),
        ]
        for filter in filters {
            for balance in [FolderBalance.off, .balanced, .equal] {
                let script = RandomSampleScriptGenerator.generate(
                    sampleSize: 100, filter: filter, folderBalance: balance)
                let tokens = PascalTokenizer.tokenize(script)

                XCTAssertEqual(tokens.map(\.text).joined(), script)
                for token in tokens where token.kind == .plain {
                    XCTAssertFalse(
                        token.text.contains(where: { "'{}".contains($0) }),
                        "stray quote or brace in plain text: \(token.text)")
                }
            }
        }
    }
}
