import XCTest

@testable import SupremeSampler

/// Specifies turning a script read from disk into rules the rule builder
/// can edit: each rule becomes the row that would have written it, and
/// keyword lists become picks in the open catalog's tree -- with anything
/// that doesn't line up with the tree reported, not silently changed.
final class ScriptImportTests: XCTestCase {
    /// Nature -> Pines -> Tall Pines, and Nature -> Oaks.
    private let tree = CatalogPropNode.buildTree(
        categories: [(guid: "nature", name: "Nature")],
        props: [
            (guid: "pines", parentGUID: "nature", name: "Pines"),
            (guid: "tall-pines", parentGUID: "pines", name: "Tall Pines"),
            (guid: "oaks", parentGUID: "nature", name: "Oaks"),
        ]
    )

    private let url = URL(fileURLWithPath: "/tmp/RandomSample.psc")

    private func readScript(_ filter: SampleFilter, size: Int = 100, balance: FolderBalance = .off) throws -> ReadScript {
        let text = RandomSampleScriptGenerator.generate(sampleSize: size, filter: filter, folderBalance: balance)
        guard case .read(let script) = ScriptReader.read(text) else { throw XCTSkip("unreadable") }
        return script
    }

    private func importing(_ filter: SampleFilter) throws -> ScriptImport {
        ScriptImport(url: url, script: try readScript(filter), tree: tree)
    }

    private func flat(_ rules: FilterRule...) -> SampleFilter {
        SampleFilter(root: RuleGroup(match: .all, rules: rules))
    }

    private func branchesFromPicks(_ picks: Set<String>) -> [CategoryBranch] {
        CategoryBranch.resolve(selectedGUIDs: picks, in: tree)
    }

    /// The single keyword row the import made.
    private func keywordRow(_ result: ScriptImport, file: StaticString = #filePath, line: UInt = #line) -> KeywordRuleDraft? {
        guard case .keyword(let keyword) = result.rules.rules.first?.content else {
            XCTFail("expected a keyword row, got \(result.rules.rules)", file: file, line: line)
            return nil
        }
        return keyword
    }

    // MARK: - Rows for each kind of rule

    func test_givenEachKindOfRule_whenImported_thenTheRowsBuildTheSameFilter() throws {
        let filter = flat(
            .rating(.isNot(2)),
            .keywordPath(KeywordPathFilter(kind: .hasPart, text: "Oak", negated: true)),
            .keywordCount(.atMost(3)),
            .path(PathFilter(kind: .endsWith, text: ".png", negated: false)),
            .label(LabelFilter(labels: ["", "Red"], mode: .none)),
            .fileType(FileTypeFilter(extensions: ["jpg"], mode: .any)),
            .bookmark(BookmarkFilter(values: [2, 5], mode: .none)),
            .pendingDeletion(false),
            .group(RuleGroup(match: .none, rules: [.rating(.exactly(1)), .rating(.exactly(0))])))

        let result = try importing(filter)

        XCTAssertEqual(SampleFilter(root: result.rules.domainGroup(resolvingCategoriesIn: tree)), filter)
        XCTAssertEqual(result.rules.rules.map(\.field), [
            .rating, .keyword, .keywordCount, .path, .label, .fileType, .bookmark, .pendingDeletion, nil,
        ])
        XCTAssertFalse(result.needsConfirmation)
    }

    func test_givenNoKeywordsOrSomeKeywords_whenImported_thenTheyBecomeTheKeywordFieldsEmptinessTests() throws {
        let empty = try importing(flat(.keywordCount(.isEmpty)))
        let notEmpty = try importing(flat(.keywordCount(.isNotEmpty)))

        XCTAssertEqual(keywordRow(empty)?.operator, .isEmpty)
        XCTAssertEqual(keywordRow(notEmpty)?.operator, .isNotEmpty)
    }

    func test_givenTheSizeAndBalance_whenImported_thenTheyComeAlong() throws {
        let result = ScriptImport(url: url, script: try readScript(flat(), size: 777, balance: .equal), tree: tree)

        XCTAssertEqual(result.sampleSize, 777)
        XCTAssertEqual(result.folderBalance, .equal)
    }

    // MARK: - Keyword picks

    func test_givenAWholeBranch_whenImported_thenItsTopKeywordIsThePick() throws {
        let filter = flat(.category(CategoryFilter(branches: branchesFromPicks(["pines"]), mode: .any)))

        let result = try importing(filter)

        XCTAssertEqual(keywordRow(result)?.operator, .isAnyOf)
        XCTAssertEqual(keywordRow(result)?.selectedGUIDs, ["pines"])
        XCTAssertFalse(result.needsConfirmation)
    }

    func test_givenSeveralBranches_whenImportedForEachMode_thenEachBranchIsPicked() throws {
        for (mode, op) in [(CategoryMatchMode.any, KeywordOperator.isAnyOf), (.all, .isAllOf), (.none, .isNoneOf)] {
            let filter = flat(.category(CategoryFilter(branches: branchesFromPicks(["pines", "oaks"]), mode: mode)))

            let result = try importing(filter)

            XCTAssertEqual(keywordRow(result)?.operator, op)
            XCTAssertEqual(keywordRow(result)?.selectedGUIDs, ["pines", "oaks"], "\(mode)")
            XCTAssertFalse(result.needsConfirmation, "\(mode)")
        }
    }

    func test_givenAKeywordNoLongerInTheCatalog_whenImported_thenItIsKeptAndCounted() throws {
        let filter = flat(.category(CategoryFilter(propGUIDs: ["oaks", "gone"], mode: .any)))

        let result = try importing(filter)

        XCTAssertEqual(keywordRow(result)?.selectedGUIDs, ["oaks", "gone"])
        XCTAssertEqual(result.missingKeywordCount, 1)
        XCTAssertTrue(result.needsConfirmation)
    }

    func test_givenABranchThatHasGrownSinceSaving_whenImported_thenTheChangeIsReported() throws {
        // Saved when Pines had no children; Tall Pines was added since, so
        // picking Pines now takes in one more keyword than the script did.
        let saved = CategoryBranch(rootGUID: "pines", propGUIDs: ["pines"])
        let filter = flat(.category(CategoryFilter(branches: [saved], mode: .any)))

        let result = try importing(filter)

        XCTAssertEqual(keywordRow(result)?.selectedGUIDs, ["pines"])
        XCTAssertTrue(result.keywordsResolveDifferently)
        XCTAssertTrue(result.needsConfirmation)
    }

    // MARK: - Edited scripts

    func test_givenAnEditedScript_whenImported_thenItNeedsConfirming() throws {
        let text = RandomSampleScriptGenerator.generate(sampleSize: 10, filter: flat(.rating(.atLeast(3))))
            .replacingOccurrences(of: "Rating >= 3", with: "Rating > 3")
        guard case .read(let script) = ScriptReader.read(text) else { return XCTFail("readable") }

        let result = ScriptImport(url: url, script: script, tree: tree)

        XCTAssertTrue(result.needsConfirmation)
        XCTAssertEqual(result.script.unreadableClauses, ["Rating > 3"])
    }
}

/// Specifies what the "open anyway?" alert says about a script that
/// won't come back exactly as it is.
final class ScriptImportNoticeTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Mine.psc")

    private func opening(_ edit: (String) -> String, tree: [CatalogPropNode] = []) throws -> ScriptImport {
        let filter = SampleFilter(root: RuleGroup(match: .all, rules: [.rating(.atLeast(3)), .pendingDeletion(false)]))
        let text = edit(RandomSampleScriptGenerator.generate(sampleSize: 10, filter: filter))
        guard case .read(let script) = ScriptReader.read(text) else { throw XCTSkip("unreadable") }
        return ScriptImport(url: url, script: script, tree: tree)
    }

    func test_givenAnUnreadableCondition_thenTheNoticeQuotesItAndTheButtonSaysRecover() throws {
        let result = try opening { $0.replacingOccurrences(of: "Rating >= 3", with: "Rating > 3") }

        XCTAssertTrue(result.notices.contains { $0.contains("Rating > 3") }, "\(result.notices)")
        XCTAssertEqual(result.confirmTitle, "Recover 1 Rule")
    }

    func test_givenOnlyEditedLines_thenTheNoticeCountsThemAndTheButtonSaysOpen() throws {
        let result = try opening {
            $0.replacingOccurrences(of: "ROWID_MAX_SAMPLE_ATTEMPTS = 8;", with: "ROWID_MAX_SAMPLE_ATTEMPTS = 9;")
        }

        XCTAssertTrue(result.notices.contains { $0.contains("1 line") }, "\(result.notices)")
        XCTAssertEqual(result.confirmTitle, "Open Rules")
    }

    func test_givenMissingKeywords_thenTheNoticeSaysSo() throws {
        let result = try opening {
            $0.replacingOccurrences(of: "Rating >= 3", with:
                "idCatalogItem.GUID IN (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d WHERE d.GUID IN (''GONE'') AND d.CatalogItemGUID IS NOT NULL)")
        }

        XCTAssertEqual(result.missingKeywordCount, 1)
        XCTAssertTrue(result.notices.contains { $0.contains("1 picked keyword") }, "\(result.notices)")
    }
}
