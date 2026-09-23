import XCTest

@testable import SupremeSampler

final class RandomSampleScriptGeneratorTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_758_000_000)  // 2025-09-16T05:20:00Z

    // MARK: - Structural invariants, any filter

    /// These lines are unconditional boilerplate -- present regardless
    /// of filter -- transcribed directly from the real, committed,
    /// verified-compiling-and-running RandomCatalogSample.psc. This test
    /// exists to catch transcription drift in that boilerplate, since
    /// the generator hand-copies it rather than reading the file at
    /// runtime (see RandomSampleScriptGenerator's doc comment for why).
    private let invariantLines = [
        "const",
        "  ROWID_OVERSAMPLE_MARGIN = 1.15;",
        "const",
        "  ROWID_MAX_SAMPLE_ATTEMPTS = 8;",
        "const",
        "  ROWID_MAX_BATCH_SIZE = 100000;",
        "function RandomItemGUIDs(ACount: Integer): TStringList;",
        "  Randomize;",
        "  result := TStringList.Create;",
        "  result.Sorted := True;",
        "  result.Duplicates := dupIgnore;",
        "    ATotalRows := AExtentSet.FieldValue('RowCount');",
        "    AMaxRowID := AExtentSet.FieldValue('MaxRowID');",
        "  if (ATotalRows > 0) and (AMaxRowID > 0) then",
        "    if ACount > ATotalRows then",
        "      ACount := ATotalRows;",
        "    ADensity := ATotalRows / AMaxRowID;",
        "    while (result.Count < ACount) and (AAttempt < ROWID_MAX_SAMPLE_ATTEMPTS) do",
        "      ABatchSize := Trunc(AShortfall / ADensity * ROWID_OVERSAMPLE_MARGIN) + 1;",
        "        for I := 1 to ABatchSize do",
        "          ACandidates.Add(IntToStr(Trunc(Random * AMaxRowID) + 1));",
        "function BuildRandomItems: TCatalogItems;",
        "  AGUIDs := RandomItemGUIDs(SAMPLE_SIZE);",
        "    AClassGUID := PublicCatalog.StoreItemGUIDsToTempList(AGUIDs, False);",
        "procedure OpenNewTabForDataset(ADatasets: TDBXOMDataSets);",
        "  AColl: Variant;",
        "    PublicBroadCast(nil, 'OpenNewTab', nil);",
        "    PublicBroadCastRequest(nil, 'ActiveCollection', AData);",
        "    AColl := AData.Data;",
        "    AColl.Clear;",
        "    AColl.Items._DataSets := ADatasets;",
        "    PublicBroadCast(nil, 'RefreshActiveCollection', nil);",
        "procedure OpenRandomSample;",
        "  AItems := BuildRandomItems;",
        "  OpenNewTabForDataset(ADatasets);",
        "begin",
        "  OpenRandomSample;",
        "end;",
    ]

    func test_givenAnyFilter_whenGenerating_thenIncludesAllRandomCatalogSampleBoilerplate() {
        for filter in [SampleFilter(), SampleFilter(rating: .atLeast(3))] {
            let script = RandomSampleScriptGenerator.generate(
                sampleSize: 10000, filter: filter, generatedAt: fixedDate)
            for line in invariantLines {
                XCTAssertTrue(
                    script.contains(line),
                    "missing boilerplate line for filter \(filter): \(line)")
            }
        }
    }

    /// `invariantLines` above is hand-copied into this test file, which
    /// means it can go wrong the same way the generator itself can: by
    /// transcription error, or by silently drifting to match whatever
    /// the generator produces instead of what the real script says (that
    /// exact failure mode happened once already during development --
    /// `invariantLines` briefly asserted `"end."`, matching a bug in the
    /// generator, instead of the real file's `"end;"`). This test closes
    /// that gap by reading the actual sibling-repo file directly, so
    /// neither side can be silently "corrected" to match the other.
    ///
    /// Skips (doesn't fail) if that file isn't present -- it's a
    /// different git repo on the same machine, not something this
    /// repo/CI necessarily has checked out. `throw XCTSkip(...)` is
    /// Swift/XCTest's way of marking a test inconclusive rather than
    /// pass or fail, similar in spirit to `pytest.skip(...)` or Rust's
    /// `#[ignore]`, except decided at runtime here rather than
    /// declared up front.
    func test_givenNoFilter_whenGenerating_thenMatchesRealScriptVerbatimLineForLine() throws {
        let realScriptPath = "~/Projects/pascal/photo supreme/RandomCatalogSample.psc"
        guard let realScript = try? String(contentsOfFile: realScriptPath, encoding: .utf8) else {
            throw XCTSkip("RandomCatalogSample.psc not found at \(realScriptPath) -- skipping cross-repo check")
        }

        // Lines 1-13 of the real file are its own header comment block,
        // which SupremeSampler's generator intentionally replaces with
        // its own (see RandomSampleScriptGenerator.headerLines) rather
        // than reproducing verbatim -- everything else, starting from
        // "const", is meant to be identical for an unfiltered sample.
        // Blank lines filtered out for two reasons: they're not
        // meaningful to assert on (the generated file's blank-line
        // layout doesn't need to match the real file's), and, unlike
        // Python's `"" in "abc"` or JS's `"abc".includes("")` (both
        // `true`), Swift's `String.contains(_:)` returns `false` for an
        // empty needle -- every blank line would otherwise fail this
        // loop for a reason that has nothing to do with the thing being
        // tested.
        let realBodyLines = realScript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop { $0 != "const" }
            .filter { !$0.isEmpty }

        let generated = RandomSampleScriptGenerator.generate(sampleSize: 10000, generatedAt: fixedDate)

        for line in realBodyLines {
            XCTAssertTrue(
                generated.contains(line),
                "generated output is missing this exact line from the real script: \(line)")
        }
    }

    // MARK: - Sample size

    func test_givenSampleSize_whenGenerating_thenSetsTheConstant() {
        let script = RandomSampleScriptGenerator.generate(sampleSize: 2500, generatedAt: fixedDate)
        XCTAssertTrue(script.contains("SAMPLE_SIZE = 2500;"))
    }

    // MARK: - Unfiltered

    func test_givenNoFilter_whenGenerating_thenExtentQueryHasNoWhereClause() {
        let script = RandomSampleScriptGenerator.generate(sampleSize: 100, generatedAt: fixedDate)
        // The exact unfiltered extent-query text, ending in a bare `;` --
        // this alone proves no WHERE clause got appended. (Checking that
        // the word "WHERE" is absent anywhere in the whole script would
        // be wrong: the sample query's "WHERE rowid IN (...)" always
        // contains it, filter or no filter.)
        XCTAssertTrue(
            script.contains(
                "'SELECT COUNT(*) AS RowCount, MAX(rowid) AS MaxRowID FROM idCatalogItem';"))
    }

    func test_givenNoFilter_whenGenerating_thenSampleQueryHasNoAndClause() {
        let script = RandomSampleScriptGenerator.generate(sampleSize: 100, generatedAt: fixedDate)
        XCTAssertTrue(script.contains("ACandidates.CommaText + ')';"))
    }

    // MARK: - Filtered

    func test_givenRatingFilter_whenGenerating_thenExtentQueryGetsWhereClause() {
        let script = RandomSampleScriptGenerator.generate(
            sampleSize: 100, filter: SampleFilter(rating: .atLeast(3)), generatedAt: fixedDate)

        // One merged string literal, not `'base' + ' WHERE ...'` -- see
        // the doc comment on extentCommandTextLines for why two adjacent
        // literals joined by `+` is specifically what this interpreter
        // rejects.
        XCTAssertTrue(
            script.contains(
                "'SELECT COUNT(*) AS RowCount, MAX(rowid) AS MaxRowID FROM idCatalogItem WHERE Rating >= 3';"
            ))
    }

    func test_givenRatingFilter_whenGenerating_thenSampleQueryGetsAndClause() {
        let script = RandomSampleScriptGenerator.generate(
            sampleSize: 100, filter: SampleFilter(rating: .atLeast(3)), generatedAt: fixedDate)

        // `')' + ACandidates.CommaText` still ends with a *variable*
        // immediately before this literal, so `+` here joins a variable
        // to a literal (proven to compile), not two literals.
        XCTAssertTrue(script.contains("ACandidates.CommaText + ') AND Rating >= 3';"))
    }

    func test_givenCategoryFilterWithGUIDContainingQuote_whenGenerating_thenBothEscapingLayersApply() {
        // "O''Brien" at the SQL level (one escape pass) becomes
        // "O''''Brien" once *that* text is itself wrapped as a Pascal
        // string literal (a second escape pass over the already-escaped
        // text) -- the nested-quoting compounding effect
        // SQLPredicateText's and PascalStringLiteral's doc comments both
        // call out. This is the sharpest edge in the whole generator;
        // worth its own explicit test rather than trusting the two unit-
        // tested layers to compose correctly by inspection alone.
        let filter = SampleFilter(category: CategoryFilter(propGUIDs: ["O'Brien"], mode: .any))
        let script = RandomSampleScriptGenerator.generate(sampleSize: 100, filter: filter, generatedAt: fixedDate)

        XCTAssertTrue(script.contains("d.GUID IN (''O''''Brien'')"))
    }

    // MARK: - Rule groups

    func test_givenAnAnyOfRootGroup_whenGenerating_thenBothQueriesKeepTheORInsideParentheses() {
        // The sampling query appends the predicate after
        // `rowid IN (...) AND`; an unparenthesized OR there would match
        // photos outside the random batch.
        let filter = SampleFilter(root: RuleGroup(match: .any, rules: [.rating(.exactly(5)), .rating(.exactly(1))]))
        let script = RandomSampleScriptGenerator.generate(sampleSize: 100, filter: filter, generatedAt: fixedDate)

        XCTAssertTrue(script.contains("FROM idCatalogItem WHERE (Rating = 5 OR Rating = 1)';"))
        XCTAssertTrue(script.contains("ACandidates.CommaText + ') AND (Rating = 5 OR Rating = 1)';"))
    }

    func test_givenNestedGroups_whenGenerating_thenHeaderSummarizesTheTreeIndented() {
        let filter = SampleFilter(
            root: RuleGroup(
                match: .all,
                rules: [
                    .rating(.atLeast(4)),
                    .group(
                        RuleGroup(
                            match: .none,
                            rules: [.category(CategoryFilter(propGUIDs: ["A"], mode: .any))])),
                ]))
        let script = RandomSampleScriptGenerator.generate(sampleSize: 100, filter: filter, generatedAt: fixedDate)

        XCTAssertTrue(
            script.contains(
                """
                  Rating filter: at least 4
                  Match none of:
                    Category filter: any of 1 categories (including subcategories)
                """))
    }

    func test_givenAnAnyOfRootGroup_whenGenerating_thenHeaderSaysSoBeforeItsRules() {
        let filter = SampleFilter(root: RuleGroup(match: .any, rules: [.rating(.exactly(5)), .rating(.exactly(1))]))
        let script = RandomSampleScriptGenerator.generate(sampleSize: 100, filter: filter, generatedAt: fixedDate)

        XCTAssertTrue(
            script.contains(
                """
                  Match any of:
                    Rating filter: exactly 5
                    Rating filter: exactly 1
                """))
    }

    // MARK: - Header

    func test_givenFilter_whenGenerating_thenHeaderSummarizesIt() {
        let filter = SampleFilter(
            rating: .atLeast(4),
            category: CategoryFilter(propGUIDs: ["A", "B"], mode: .all)
        )
        let script = RandomSampleScriptGenerator.generate(sampleSize: 100, filter: filter, generatedAt: fixedDate)

        XCTAssertTrue(script.contains("Rating filter: at least 4"))
        XCTAssertTrue(script.contains("Category filter: all of 2 categories (including subcategories)"))
    }

    func test_givenNoFilter_whenGenerating_thenHeaderOmitsFilterSummaryLines() {
        let script = RandomSampleScriptGenerator.generate(sampleSize: 100, generatedAt: fixedDate)
        XCTAssertFalse(script.contains("Rating filter:"))
        XCTAssertFalse(script.contains("Category filter:"))
    }

    // MARK: - Balanced syntax (cheap sanity check, not a real compiler)

    /// Strips `//`-to-end-of-line from each line first. Without this,
    /// ordinary English comment text produces false positives: an
    /// apostrophe like "isn't" reads as an unterminated string to a
    /// naive quote-counter, and mathematical interval notation like
    /// "[0,1)" has a `)` with no matching `(` (the matching bracket is
    /// `[`, not `(`) -- both are real content already in this file's
    /// comments (copied from the real committed .psc), neither is a
    /// syntax problem, since `//` comments aren't parsed as code or
    /// strings at all. `map(...).joined(...)` here does the same job as
    /// Python's `"\n".join(line.split("//")[0] for line in text.split("\n"))`
    /// or Rust's `.lines().map(...).collect::<Vec<_>>().join("\n")`.
    private func strippingComments(_ script: String) -> String {
        script.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                // `omittingEmptySubsequences: false` matters here: an
                // empty line, or a line that's just a comment with
                // nothing before `//`, would otherwise split into zero
                // pieces (Swift's default drops empty pieces) and crash
                // on the `[0]` below -- not a hypothetical, this crashed
                // the first time with the default `true`.
                line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0]
            }
            .joined(separator: "\n")
    }

    // MARK: - Interpreter quirk: no two adjacent string literals joined by `+`

    /// Confirmed by hand in Script Studio (see AGENTS.md): this
    /// interpreter rejects `'literal1' + 'literal2'` with a syntax
    /// error, even though `'literal1' + SomeVariable + 'literal2'`
    /// compiles fine -- the shape every *other* CommandText assignment
    /// in the verified reference script already uses. A regression test
    /// on its own, not just an assertion baked into the two "GetsClause"
    /// tests above, since this is exactly the kind of thing a future
    /// edit to `extentCommandTextLines`/`sampleCommandTextLines` could
    /// silently reintroduce without either of those noticing (they only
    /// check for the *presence* of the merged text, not the *absence*
    /// of the old, broken shape).
    func test_givenAnyFilter_whenGenerating_thenNeverJoinsTwoAdjacentStringLiteralsWithPlus() {
        for filter in [
            SampleFilter(),
            SampleFilter(rating: .exactly(5)),
            SampleFilter(category: CategoryFilter(propGUIDs: ["A", "B", "C"], mode: .all)),
            SampleFilter(rating: .atMost(2), category: CategoryFilter(propGUIDs: ["A"], mode: .none)),
            SampleFilter(
                root: RuleGroup(
                    match: .none,
                    rules: [
                        .rating(.exactly(1)),
                        .group(RuleGroup(match: .any, rules: [.category(CategoryFilter(propGUIDs: ["O'B"], mode: .all))])),
                    ])),
        ] {
            let script = RandomSampleScriptGenerator.generate(sampleSize: 100, filter: filter, generatedAt: fixedDate)
            let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            for (previous, current) in zip(lines, lines.dropFirst()) {
                let previousEndsWithLiteralPlus = previous.hasSuffix("' +")
                let currentStartsWithLiteral = current.hasPrefix("'")
                XCTAssertFalse(
                    previousEndsWithLiteralPlus && currentStartsWithLiteral,
                    """
                    found two adjacent string literals joined by '+' for filter \(filter): \
                    "\(previous)" followed by "\(current)"
                    """)
            }
        }
    }

    func test_givenAnyFilter_whenGenerating_thenQuotesAndParensAreBalanced() {
        for filter in [
            SampleFilter(),
            SampleFilter(rating: .exactly(5)),
            SampleFilter(category: CategoryFilter(propGUIDs: ["A", "B", "C"], mode: .all)),
            SampleFilter(rating: .atMost(2), category: CategoryFilter(propGUIDs: ["A"], mode: .none)),
            SampleFilter(
                root: RuleGroup(
                    match: .none,
                    rules: [
                        .rating(.exactly(1)),
                        .group(RuleGroup(match: .any, rules: [.category(CategoryFilter(propGUIDs: ["O'B"], mode: .all))])),
                    ])),
        ] {
            let script = RandomSampleScriptGenerator.generate(sampleSize: 100, filter: filter, generatedAt: fixedDate)
            let code = strippingComments(script)

            XCTAssertEqual(
                code.filter { $0 == "'" }.count % 2, 0,
                "unbalanced single quotes for filter \(filter)")
            XCTAssertEqual(
                code.filter { $0 == "(" }.count,
                code.filter { $0 == ")" }.count,
                "unbalanced parens for filter \(filter)")
        }
    }
}
