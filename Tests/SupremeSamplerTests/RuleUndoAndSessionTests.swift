import XCTest

@testable import SupremeSampler

/// Rule edits are undoable, and the rules, sample size and folder
/// balance come back on the next launch -- for the same catalog only.
@MainActor
final class RuleUndoAndSessionTests: XCTestCase {
    private struct StubCatalog: SampleBuilderCatalog {
        var count = 7
        func listPropTree() async throws -> [CatalogPropNode] { [] }
        func matchingItemCount(for filter: SampleFilter) async throws -> Int { count }
        func folderPhotoCounts(for filter: SampleFilter) async throws -> [FolderPhotoCount] { [] }
    }

    // MARK: - Undo

    func test_givenAnUndoManager_whenARuleIsAddedThenUndone_thenTheRulesGoBack() {
        let model = SampleBuilderModel.forTesting()
        let undoManager = UndoManager()
        // A plain `UndoManager` groups by run-loop event; tests make one
        // group per edit by hand instead.
        undoManager.groupsByEvent = false
        model.undoManager = undoManager

        undoManager.beginUndoGrouping()
        model.rules.add(.rating)
        undoManager.endUndoGrouping()
        XCTAssertEqual(model.rules.rules.count, 1)
        XCTAssertEqual(undoManager.undoActionName, "Rule Change")

        undoManager.undo()
        XCTAssertTrue(model.rules.rules.isEmpty)

        undoManager.redo()
        XCTAssertEqual(model.rules.rules.count, 1)
    }

    func test_givenAnUndoManager_whenARemovedNestedGroupIsUndone_thenTheWholeGroupComesBack() {
        let model = SampleBuilderModel.forTesting()
        model.rules.addGroup()
        if case .group(var nested) = model.rules.rules[0].content {
            nested.add(.keyword)
            nested.add(.path)
            model.rules.rules[0].content = .group(nested)
        }
        let before = model.rules
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager

        undoManager.beginUndoGrouping()
        model.rules.removeRule(id: model.rules.rules[0].id)
        undoManager.endUndoGrouping()
        undoManager.undo()

        XCTAssertEqual(model.rules, before)
    }

    func test_givenNoUndoManager_whenEditingRules_thenNothingBreaks() {
        let model = SampleBuilderModel.forTesting()
        model.rules.add(.rating)
        XCTAssertEqual(model.rules.rules.count, 1)
    }

    // MARK: - The saved session

    func test_givenACatalogOpen_whenEditing_thenTheSessionIsSavedForThatCatalog() {
        let store = InMemoryRecentCatalogStore()
        let model = SampleBuilderModel.forTesting(catalogStore: store)
        model.injectCatalogForTesting(StubCatalog())

        model.rules.add(.keyword)
        model.sampleSize = 2_500
        model.folderBalance = .equal

        let session = SavedSession.decode(store.loadSession())
        XCTAssertEqual(session?.catalogPath, "test")
        XCTAssertEqual(session?.rules, model.rules)
        XCTAssertEqual(session?.sampleSize, 2_500)
        XCTAssertEqual(session?.folderBalance, .equal)
    }

    func test_givenNoCatalogOpen_whenEditing_thenNothingIsSaved() {
        let store = InMemoryRecentCatalogStore()
        let model = SampleBuilderModel.forTesting(catalogStore: store)

        model.rules.add(.rating)

        XCTAssertNil(store.loadSession())
    }

    /// Opens `path` and waits for the open to finish.
    private func open(_ model: SampleBuilderModel, _ path: String) async {
        model.openCatalog(at: path)
        await model.waitForPendingCatalogOpenForTesting()
        // The file-type scan runs on after the open; finish it before the
        // test deletes the file or opens another.
        await model.waitForPendingFileTypesForTesting()
    }

    private func sessionRules(_ field: RuleField) -> RuleGroupDraft {
        var rules = RuleGroupDraft(match: .any)
        rules.add(field)
        rules.addGroup()
        return rules
    }

    func test_givenASessionForTheRememberedCatalog_whenAutoOpening_thenItsRulesSizeAndBalanceComeBack() async throws {
        let path = try makeMinimalCatalogFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rules = sessionRules(.label)
        let session = SavedSession(catalogPath: path, rules: rules, sampleSize: 123, folderBalance: .balanced)
        let store = InMemoryRecentCatalogStore(initialPath: path, initialSession: session.encoded())
        let model = SampleBuilderModel.forTesting(catalogStore: store)

        model.attemptAutoOpenRecentCatalog()
        await model.waitForPendingCatalogOpenForTesting()
        await model.waitForPendingFileTypesForTesting()

        XCTAssertEqual(model.catalogPath, path)
        XCTAssertEqual(model.rules, rules)
        XCTAssertEqual(model.sampleSize, 123)
        XCTAssertEqual(model.folderBalance, .balanced)
    }

    func test_givenASessionForADifferentCatalog_whenAutoOpening_thenTheRulesStartEmpty() async throws {
        let path = try makeMinimalCatalogFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SavedSession(
            catalogPath: "/nonexistent/other.cat.db", rules: sessionRules(.rating), sampleSize: 123, folderBalance: .equal)
        let store = InMemoryRecentCatalogStore(initialPath: path, initialSession: session.encoded())
        let model = SampleBuilderModel.forTesting(catalogStore: store)

        model.attemptAutoOpenRecentCatalog()
        await model.waitForPendingCatalogOpenForTesting()
        await model.waitForPendingFileTypesForTesting()

        XCTAssertTrue(model.rules.rules.isEmpty)
        XCTAssertEqual(model.sampleSize, 10_000)
    }

    /// Regression: the session used to be restored before the open, so a
    /// catalog that failed to open (an unplugged drive) left its rules on
    /// screen, and opening another catalog then saved them under that
    /// one -- keyword GUIDs from the wrong catalog, and the first
    /// catalog's saved session overwritten.
    func test_givenTheRememberedCatalogFailsToOpen_whenAnotherOpens_thenItGetsNoneOfTheFirstCatalogsRules() async throws {
        let other = try makeMinimalCatalogFixture()
        defer { try? FileManager.default.removeItem(atPath: other) }
        let missing = "/nonexistent/\(UUID().uuidString).cat.db"
        let firstSession = SavedSession(
            catalogPath: missing, rules: sessionRules(.keyword), sampleSize: 77, folderBalance: .equal)
        let store = InMemoryRecentCatalogStore(initialPath: missing, initialSession: firstSession.encoded())
        let model = SampleBuilderModel.forTesting(catalogStore: store)

        model.attemptAutoOpenRecentCatalog()
        await model.waitForPendingCatalogOpenForTesting()
        await model.waitForPendingFileTypesForTesting()
        XCTAssertNil(model.catalogPath, "precondition: the remembered catalog fails to open")
        XCTAssertTrue(model.rules.rules.isEmpty, "a failed open restores nothing")

        await open(model, other)

        XCTAssertEqual(model.catalogPath, other)
        XCTAssertTrue(model.rules.rules.isEmpty)
        XCTAssertEqual(SavedSession.decode(store.loadSession()), firstSession, "the first catalog's session is kept")
    }

    func test_givenRulesForOneCatalog_whenSwitchingToAnother_thenTheRulesAndUndoHistoryAreCleared() async throws {
        let first = try makeMinimalCatalogFixture()
        let second = try makeMinimalCatalogFixture()
        defer {
            try? FileManager.default.removeItem(atPath: first)
            try? FileManager.default.removeItem(atPath: second)
        }
        let store = InMemoryRecentCatalogStore()
        let model = SampleBuilderModel.forTesting(catalogStore: store)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
        await open(model, first)
        undoManager.beginUndoGrouping()
        model.rules.add(.keyword)
        undoManager.endUndoGrouping()
        XCTAssertTrue(undoManager.canUndo)

        await open(model, second)

        XCTAssertTrue(model.rules.rules.isEmpty)
        XCTAssertFalse(undoManager.canUndo, "undo would bring the first catalog's rules back")
        XCTAssertEqual(SavedSession.decode(store.loadSession())?.catalogPath, first, "switching alone saves nothing")

        // And back again: the first catalog's session is still there.
        await open(model, first)
        XCTAssertEqual(model.rules.rules.count, 1)
    }

    func test_givenASessionRestoredOnOpen_whenUndoing_thenTheRestoreIsNotUndone() async throws {
        let path = try makeMinimalCatalogFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rules = sessionRules(.path)
        let session = SavedSession(catalogPath: path, rules: rules, sampleSize: 5, folderBalance: .off)
        let model = SampleBuilderModel.forTesting(catalogStore: InMemoryRecentCatalogStore(initialSession: session.encoded()))
        let undoManager = UndoManager()
        model.undoManager = undoManager  // handed over before the open, as ContentView does

        await open(model, path)

        XCTAssertEqual(model.rules, rules)
        XCTAssertFalse(undoManager.canUndo)
    }

    func test_givenUnreadableSessionData_whenOpening_thenItIsIgnored() async throws {
        let path = try makeMinimalCatalogFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = SampleBuilderModel.forTesting(
            catalogStore: InMemoryRecentCatalogStore(initialSession: Data("not json".utf8)))

        await open(model, path)

        XCTAssertEqual(model.catalogPath, path)
        XCTAssertTrue(model.rules.rules.isEmpty)
    }

    /// Menu enums are saved by case name: rewording a menu label must not
    /// make every saved session unreadable.
    func test_givenMenuChoices_whenEncodingASession_thenCaseNamesAreStoredNotMenuLabels() throws {
        var rules = RuleGroupDraft()
        rules.rules = [
            RuleDraft(.rating(RatingRuleDraft(comparison: .atLeast, value: 4))),
            RuleDraft(.keyword(KeywordRuleDraft(operator: .hasNoPart))),
            RuleDraft(.path(PathRuleDraft(operator: .doesNotStartWith, text: "x"))),
        ]
        let json = try XCTUnwrap(
            SavedSession(catalogPath: "/x", rules: rules, sampleSize: 1, folderBalance: .off).encoded()
                .flatMap { String(data: $0, encoding: .utf8) })

        XCTAssertTrue(json.contains("\"atLeast\""), json)
        XCTAssertTrue(json.contains("\"hasNoPart\""), json)
        XCTAssertTrue(json.contains("\"doesNotStartWith\""), json)
        XCTAssertFalse(json.contains("is at least"), json)
        XCTAssertFalse(json.contains("has no part named"), json)
    }

    func test_givenEveryKindOfRule_whenRoundTrippingASession_thenNothingIsLost() throws {
        var rules = RuleGroupDraft(match: .none)
        for field in RuleField.allCases { rules.add(field) }
        if case .keyword(var keyword) = rules.rules[1].content {
            keyword.operator = .hasNoPart
            keyword.selectedGUIDs = ["a", "b"]
            keyword.text = "Nature\\Trees"
            rules.rules[1].content = .keyword(keyword)
        }
        rules.addGroup()
        let session = SavedSession(catalogPath: "/x.cat.db", rules: rules, sampleSize: 42, folderBalance: .off)

        XCTAssertEqual(SavedSession.decode(session.encoded()), session)
    }
}

/// While a rule's text field is focused, AppKit's field editor undoes the
/// typing itself; the model registers the whole edit as one step when
/// editing ends, instead of once per debounced commit (which put each
/// edit on the stack twice and made ⌘Z bounce between old and new text).
@MainActor
final class TextEditUndoTests: XCTestCase {
    private func modelWithPathRule() -> (SampleBuilderModel, UndoManager) {
        let model = SampleBuilderModel.forTesting()
        model.rules.add(.path)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
        return (model, undoManager)
    }

    private func setPathText(_ model: SampleBuilderModel, _ text: String) {
        model.rules.rules[0].content = .path(PathRuleDraft(operator: .contains, text: text))
    }

    func test_givenSeveralCommitsWhileAFieldIsFocused_whenEditingEnds_thenOneUndoStepRevertsThemAll() {
        let (model, undoManager) = modelWithPathRule()
        let before = model.rules

        // One group per event, as in the app: each debounced commit, and
        // the blur that ends the edit, is its own run-loop turn.
        func inGroup(_ body: () -> Void) {
            undoManager.beginUndoGrouping()
            body()
            undoManager.endUndoGrouping()
        }
        inGroup { model.beginTextEditing() }
        inGroup { setPathText(model, "tr") }
        inGroup { setPathText(model, "travel") }
        inGroup { model.endTextEditing() }

        // One undo goes all the way back -- not to "tr", which is where
        // it would stop if each commit had been registered.
        undoManager.undo()
        XCTAssertEqual(model.rules, before)

        undoManager.redo()
        guard case .path(let path) = model.rules.rules[0].content else { return XCTFail("not a path rule") }
        XCTAssertEqual(path.text, "travel")
    }

    func test_givenAFocusedFieldWithNoChange_whenEditingEnds_thenNothingIsRegistered() {
        let (model, undoManager) = modelWithPathRule()

        model.beginTextEditing()
        model.endTextEditing()

        XCTAssertFalse(undoManager.canUndo)
    }

    func test_givenAnUndoWhileAFieldIsFocused_whenEditingEnds_thenTheUndoIsNotItselfUndone() {
        let (model, undoManager) = modelWithPathRule()
        undoManager.beginUndoGrouping()
        setPathText(model, "old")
        undoManager.endUndoGrouping()

        model.beginTextEditing()
        undoManager.undo()  // back to "", with a redo registered
        model.endTextEditing()

        XCTAssertTrue(undoManager.canRedo, "ending the edit must not register over the redo")
        guard case .path(let path) = model.rules.rules[0].content else { return XCTFail("not a path rule") }
        XCTAssertEqual(path.text, "")
    }

    func test_givenUnbalancedEndCalls_whenEditingRulesAfterwards_thenUndoStillRegisters() {
        let (model, undoManager) = modelWithPathRule()
        model.endTextEditing()  // never began: ignored

        undoManager.beginUndoGrouping()
        setPathText(model, "x")
        undoManager.endUndoGrouping()

        XCTAssertTrue(undoManager.canUndo)
    }
}
