import XCTest

@testable import SupremeSampler

/// Specifies File > Open Script…: a script saved earlier opens back into
/// the rule builder, ready to edit and save again. A script as the app
/// wrote it opens straight away; one that was edited by hand (or can't
/// come back exactly) asks first, and cancelling leaves everything as it
/// was. Real files, in a temp folder.
@MainActor
final class ScriptOpeningTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private struct StubCatalog: SampleBuilderCatalog {
        func listPropTree() async throws -> [CatalogPropNode] { [] }
        func matchingItemCount(for filter: SampleFilter) async throws -> Int { 42 }
        func folderPhotoCounts(for filter: SampleFilter) async throws -> [FolderPhotoCount] { [] }
    }

    private let savedFilter = SampleFilter(
        root: RuleGroup(match: .all, rules: [.rating(.atLeast(4)), .pendingDeletion(false)]))

    private func modelWithCatalog(store: InMemoryRecentCatalogStore = InMemoryRecentCatalogStore()) -> SampleBuilderModel {
        let model = SampleBuilderModel.forTesting(catalogStore: store)
        model.injectCatalogForTesting(StubCatalog())
        return model
    }

    private func writeScript(
        named name: String = "RandomRated4Plus.psc", editing edit: (String) -> String = { $0 }
    ) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let script = RandomSampleScriptGenerator.generate(sampleSize: 321, filter: savedFilter, folderBalance: .balanced)
        try PSCFile.encode(edit(script)).write(to: url)
        return url
    }

    // MARK: - A script as the app wrote it

    func test_givenAScriptAsTheAppWroteIt_whenOpened_thenItsRulesSizeAndBalanceReplaceTheCurrentOnes() throws {
        let model = modelWithCatalog()
        model.rules.add(.path)
        let url = try writeScript()

        model.openScript(at: url)

        XCTAssertNil(model.scriptOpenPrompt, "nothing to ask about")
        XCTAssertEqual(model.currentFilter, savedFilter)
        XCTAssertEqual(model.sampleSize, 321)
        XCTAssertEqual(model.folderBalance, .balanced)
    }

    func test_givenAnOpenedScript_whenNothingIsChanged_thenSavingSuggestsTheSameFile() throws {
        let model = modelWithCatalog()
        let url = try writeScript(named: "MyOwnName.psc")

        model.openScript(at: url)

        XCTAssertEqual(model.lastSavedScriptURL, url)
        XCTAssertEqual(model.scriptFileStatus, "Opened MyOwnName.psc")
        XCTAssertEqual(model.suggestedScriptFileName, "MyOwnName.psc")
        model.rules.add(.rating)
        XCTAssertNil(model.lastSavedScriptURL, "the rules no longer match the file")
    }

    func test_givenTheReferenceScriptsName_whenOpened_thenSavingNeverSuggestsIt() throws {
        // The hand-verified reference must not be overwritten by default.
        let model = modelWithCatalog()
        let url = try writeScript(named: "randomcatalogsample.psc")

        model.openScript(at: url)

        XCTAssertNotEqual(model.suggestedScriptFileName.lowercased(), "randomcatalogsample.psc")
    }

    func test_givenAnOpenedScript_whenUndone_thenTheEarlierRulesSizeAndBalanceComeBack() throws {
        let model = modelWithCatalog()
        model.rules.add(.path)
        model.sampleSize = 50
        let before = model.rules
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
        let url = try writeScript()

        undoManager.beginUndoGrouping()
        model.openScript(at: url)
        undoManager.endUndoGrouping()
        XCTAssertEqual(undoManager.undoActionName, "Open Script")

        undoManager.undo()
        XCTAssertEqual(model.rules, before)
        XCTAssertEqual(model.sampleSize, 50)
        XCTAssertEqual(model.folderBalance, .off)

        undoManager.redo()
        XCTAssertEqual(model.currentFilter, savedFilter)
        XCTAssertEqual(model.sampleSize, 321)
    }

    func test_givenAnOpenedScript_whenTheAppNextLaunches_thenItsRulesAreTheSavedSession() throws {
        let store = InMemoryRecentCatalogStore()
        let model = modelWithCatalog(store: store)

        model.openScript(at: try writeScript())

        let session = try XCTUnwrap(SavedSession.decode(store.loadSession()))
        XCTAssertEqual(session.sampleSize, 321)
        XCTAssertEqual(session.rules, model.rules)
    }

    // MARK: - A script edited by hand

    func test_givenAHandEditedScript_whenOpened_thenItAsksFirstAndChangesNothingYet() throws {
        let model = modelWithCatalog()
        model.rules.add(.path)
        let before = model.rules
        let url = try writeScript { $0.replacingOccurrences(of: "ROWID_MAX_SAMPLE_ATTEMPTS = 8;", with: "ROWID_MAX_SAMPLE_ATTEMPTS = 20;") }

        model.openScript(at: url)

        guard case .confirm(let pending) = model.scriptOpenPrompt else {
            return XCTFail("expected a confirmation, got \(String(describing: model.scriptOpenPrompt))")
        }
        XCTAssertEqual(pending.script.fileOnlyLines.map(\.text), ["  ROWID_MAX_SAMPLE_ATTEMPTS = 20;"])
        XCTAssertEqual(model.rules, before)
    }

    func test_givenAHandEditedScript_whenConfirmed_thenTheRecoveredRulesOpen() throws {
        let model = modelWithCatalog()
        let url = try writeScript { $0.replacingOccurrences(of: "Rating >= 4", with: "Rating > 4") }

        model.openScript(at: url)
        model.confirmScriptOpen()

        XCTAssertNil(model.scriptOpenPrompt)
        XCTAssertEqual(model.currentFilter, SampleFilter(root: RuleGroup(match: .all, rules: [.pendingDeletion(false)])))
        XCTAssertEqual(model.sampleSize, 321)
        XCTAssertEqual(model.scriptFileStatus, "Opened RandomRated4Plus.psc; saving replaces its hand edits")
    }

    func test_givenAHandEditedScript_whenCancelled_thenNothingChanges() throws {
        let model = modelWithCatalog()
        model.rules.add(.path)
        let before = model.rules
        let url = try writeScript { $0.replacingOccurrences(of: "Rating >= 4", with: "Rating > 4") }

        model.openScript(at: url)
        model.dismissScriptOpenPrompt()

        XCTAssertNil(model.scriptOpenPrompt)
        XCTAssertEqual(model.rules, before)
        XCTAssertEqual(model.sampleSize, 10_000)
        XCTAssertNil(model.lastSavedScriptURL)
    }

    // MARK: - Files that can't be opened

    func test_givenAFileThatIsNotASamplingScript_whenOpened_thenItSaysWhyAndChangesNothing() throws {
        let model = modelWithCatalog()
        let url = folder.appendingPathComponent("Notes.psc")
        try Data("begin\n  ShowMessage('hi');\nend;\n".utf8).write(to: url)

        model.openScript(at: url)

        guard case .cannotOpen(let fileName, _) = model.scriptOpenPrompt else {
            return XCTFail("expected an explanation, got \(String(describing: model.scriptOpenPrompt))")
        }
        XCTAssertEqual(fileName, "Notes.psc")
        XCTAssertTrue(model.rules.rules.isEmpty)
        model.confirmScriptOpen()
        XCTAssertTrue(model.rules.rules.isEmpty, "confirming an explanation opens nothing")
    }

    func test_givenAMissingFile_whenOpened_thenItSaysWhy() {
        let model = modelWithCatalog()

        model.openScript(at: folder.appendingPathComponent("Gone.psc"))

        guard case .cannotOpen = model.scriptOpenPrompt else {
            return XCTFail("expected an explanation, got \(String(describing: model.scriptOpenPrompt))")
        }
    }
}
