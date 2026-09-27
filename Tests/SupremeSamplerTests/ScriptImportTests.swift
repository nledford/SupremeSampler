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

    func test_givenAGroupHoldingOnlyAKeywordAnyOfSeveral_whenImported_thenItStillMatchesAnyOfThem() throws {
        // `(GUID IN (a, b))` also reads as a one-branch "all of" rule;
        // splitting that branch into "all of" picks once turned OR into AND.
        let rules = RuleGroupDraft(
            match: .all,
            rules: [
                RuleDraft(.rating(RatingRuleDraft())),
                RuleDraft(
                    .group(
                        RuleGroupDraft(
                            match: .any,
                            rules: [RuleDraft(.keyword(KeywordRuleDraft(operator: .isAnyOf, selectedGUIDs: ["pines", "oaks"])))]))),
            ])
        let filter = SampleFilter(root: rules.domainGroup(resolvingCategoriesIn: tree))

        let result = try importing(filter)

        XCTAssertFalse(result.needsConfirmation, "\(result.notices)")
        XCTAssertEqual(
            SQLPredicateText.render(SampleFilter(root: result.rules.domainGroup(resolvingCategoriesIn: tree))),
            SQLPredicateText.render(filter))
    }

    func test_givenAGroupOfKeywordAnyOfRules_whenImported_thenEachRuleKeepsItsOwnKeywords() throws {
        let filter = flat(
            .group(
                RuleGroup(
                    match: .all,
                    rules: [
                        .category(CategoryFilter(branches: branchesFromPicks(["pines", "oaks"]), mode: .any)),
                        .category(CategoryFilter(branches: branchesFromPicks(["tall-pines"]), mode: .any)),
                    ])))

        let result = try importing(filter)

        XCTAssertFalse(result.needsConfirmation, "\(result.notices)")
        XCTAssertEqual(
            SQLPredicateText.render(SampleFilter(root: result.rules.domainGroup(resolvingCategoriesIn: tree))),
            SQLPredicateText.render(filter))
    }

    func test_givenEveryPairOfKeywordAnyOfRowsInAGroup_whenSavedThenOpened_thenEachOpensUnchangedWithoutAsking() throws {
        // Exhaustive over small cases: order, repeats, a subtree twice,
        // single and multiple picks, each kind of group, nested or not.
        let pickSets: [Set<String>] = [
            ["nature"], ["pines"], ["tall-pines"], ["oaks"], ["pines", "oaks"], ["pines", "tall-pines"], ["oaks", "tall-pines"],
        ]
        for first in pickSets {
            for second in pickSets {
                for match in [GroupMatch.all, .any, .none] {
                    for nested in [false, true] {
                        let rows = [first, second].map {
                            RuleDraft(.keyword(KeywordRuleDraft(operator: .isAnyOf, selectedGUIDs: $0)))
                        }
                        let group = RuleGroupDraft(match: match, rules: rows)
                        let draft = nested
                            ? RuleGroupDraft(match: .all, rules: [RuleDraft(.rating(RatingRuleDraft())), RuleDraft(.group(group))])
                            : group
                        let filter = SampleFilter(root: draft.domainGroup(resolvingCategoriesIn: tree))
                        let label = "\(first) \(second) \(match) nested: \(nested)"

                        let result = try importing(filter)

                        XCTAssertEqual(
                            SQLPredicateText.render(SampleFilter(root: result.rules.domainGroup(resolvingCategoriesIn: tree))),
                            SQLPredicateText.render(filter), label)
                        XCTAssertFalse(result.needsConfirmation, "\(label): \(result.notices)")
                    }
                }
            }
        }
    }

    func test_givenRandomRuleBuilderStates_whenSavedThenOpened_thenEachOpensUnchangedWithoutAsking() throws {
        // The whole trip a user makes: rows on screen -> script -> read ->
        // rows again. Anything that asks, or changes the SQL, is a false
        // alarm or a silent change of meaning.
        var rng = RandomRuleTrees.SeededGenerator(state: 20_260_927)
        let guids = ["nature", "pines", "tall-pines", "oaks", "gone"]
        for trial in 0..<500 {
            let draft = RandomRuleTrees.randomDraftGroup(depth: 3, keywordGUIDs: guids, using: &rng)
            let filter = SampleFilter(root: draft.domainGroup(resolvingCategoriesIn: tree))
            // "gone" isn't in the tree: counted, and asked about, correctly.
            let usesMissingKeyword = SQLPredicateText.render(filter)?.contains("'gone'") == true

            let result = try importing(filter)

            XCTAssertEqual(
                SQLPredicateText.render(SampleFilter(root: result.rules.domainGroup(resolvingCategoriesIn: tree))),
                SQLPredicateText.render(filter), "trial \(trial)")
            XCTAssertEqual(result.needsConfirmation, usesMissingKeyword, "trial \(trial): \(result.notices)")
        }
    }

    func test_givenMoreThanTheLargestSampleSize_whenImported_thenItAsksAndSaysItWillBeCapped() throws {
        let result = ScriptImport(url: url, script: try readScript(flat(), size: 5_000_000), tree: tree)

        XCTAssertTrue(result.needsConfirmation)
        XCTAssertTrue(result.notices.contains { $0.contains("5,000,000") && $0.contains("1,000,000") }, "\(result.notices)")
        XCTAssertEqual(result.statusNote, "its sample size was capped")
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
        XCTAssertEqual(result.statusNote, "its keyword rules now match different keywords")
    }

    func test_givenAMissingBranchOfSeveralKeywords_whenImported_thenEachMissingKeywordIsCountedOnce() throws {
        let filter = flat(
            .category(CategoryFilter(branches: [CategoryBranch(rootGUID: "gone", propGUIDs: ["gone", "gone-child"])], mode: .any)),
            .category(CategoryFilter(propGUIDs: ["gone"], mode: .none)))

        XCTAssertEqual(try importing(filter).missingKeywordCount, 2)
    }

    // MARK: - Edited scripts

    func test_givenAnEditedScript_whenImported_thenItNeedsConfirming() throws {
        let text = RandomSampleScriptGenerator.generate(sampleSize: 10, filter: flat(.rating(.atLeast(3))))
            .replacingOccurrences(of: "Rating >= 3", with: "Rating > 3")
        guard case .read(let script) = ScriptReader.read(text) else { return XCTFail("readable") }

        let result = ScriptImport(url: url, script: script, tree: tree)

        XCTAssertTrue(result.needsConfirmation)
        XCTAssertEqual(result.script.unreadableClauses, ["Rating > 3"])
        XCTAssertEqual(result.statusNote, "saving replaces its hand edits")
    }

    func test_givenAnUnchangedScript_thenThereIsNothingToNote() throws {
        XCTAssertNil(try importing(flat(.rating(.atLeast(3)))).statusNote)
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
        XCTAssertTrue(result.notices.contains { $0.contains("1 of its keywords isn't") }, "\(result.notices)")
    }
}

/// Specifies the alert's own title and message.
@MainActor
final class ScriptOpenPromptTextTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Mine.psc")

    private func opening(_ text: String, tree: [CatalogPropNode] = []) throws -> ScriptImport {
        guard case .read(let script) = ScriptReader.read(text) else { throw XCTSkip("unreadable") }
        return ScriptImport(url: url, script: script, tree: tree)
    }

    func test_givenAHandEditedScript_thenTheAlertSaysItWasChangedAndAsksToOpenAnyway() throws {
        let text = RandomSampleScriptGenerator.generate(sampleSize: 10)
            .replacingOccurrences(of: "ROWID_MAX_SAMPLE_ATTEMPTS = 8;", with: "ROWID_MAX_SAMPLE_ATTEMPTS = 9;")
        let prompt = SampleBuilderModel.ScriptOpenPrompt.confirm(try opening(text))

        XCTAssertEqual(prompt.title, "“Mine.psc” was changed outside \(AppName.current)")
        XCTAssertTrue(prompt.message.hasSuffix("Open its rules anyway? The script file isn't changed until you save."))
    }

    func test_givenKeywordsThatMovedSinceSaving_thenTheAlertBlamesTheKeywordsNotTheFile() throws {
        let tree = CatalogPropNode.buildTree(
            categories: [(guid: "nature", name: "Nature")], props: [(guid: "pines", parentGUID: "nature", name: "Pines")])
        let filter = SampleFilter(
            root: RuleGroup(
                match: .all,
                rules: [.category(CategoryFilter(branches: [CategoryBranch(rootGUID: "nature", propGUIDs: ["nature"])], mode: .any))]))
        let result = try opening(RandomSampleScriptGenerator.generate(sampleSize: 10, filter: filter), tree: tree)
        let prompt = SampleBuilderModel.ScriptOpenPrompt.confirm(result)

        XCTAssertEqual(prompt.title, "“Mine.psc” doesn't match this catalog's keywords")
        XCTAssertTrue(prompt.message.contains("Keywords have been added, moved or removed"), prompt.message)
    }

    func test_givenAFileThatCannotOpen_thenTheAlertGivesTheReason() {
        let prompt = SampleBuilderModel.ScriptOpenPrompt.cannotOpen(fileName: "Notes.psc", reason: "It isn't a text file.")

        XCTAssertEqual(prompt.title, "Can't open “Notes.psc”")
        XCTAssertEqual(prompt.message, "It isn't a text file.")
    }
}
