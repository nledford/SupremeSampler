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

    /// What the alert would confirm, as its button captures it.
    private func pendingOpening(_ model: SampleBuilderModel, file: StaticString = #filePath, line: UInt = #line) -> ScriptImport? {
        guard case .confirm(let opening) = model.scriptOpenPrompt else {
            XCTFail("expected a confirmation, got \(String(describing: model.scriptOpenPrompt))", file: file, line: line)
            return nil
        }
        return opening
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

    func test_givenAScriptAsTheAppWroteIt_whenOpened_thenItsRulesSizeAndBalanceReplaceTheCurrentOnes() async throws {
        let model = modelWithCatalog()
        model.rules.add(.path)
        let url = try writeScript()

        await model.openScript(at: url)

        XCTAssertNil(model.scriptOpenPrompt, "nothing to ask about")
        XCTAssertEqual(model.currentFilter, savedFilter)
        XCTAssertEqual(model.sampleSize, 321)
        XCTAssertEqual(model.folderBalance, .balanced)
    }

    func test_givenAnOpenedScript_whenNothingIsChanged_thenSavingSuggestsTheSameFile() async throws {
        let model = modelWithCatalog()
        let url = try writeScript(named: "MyOwnName.psc")

        await model.openScript(at: url)

        XCTAssertEqual(model.lastSavedScriptURL, url)
        XCTAssertEqual(model.scriptFileStatus, "Opened MyOwnName.psc")
        XCTAssertEqual(model.suggestedScriptFileName, "MyOwnName.psc")
        model.rules.add(.rating)
        XCTAssertNil(model.lastSavedScriptURL, "the rules no longer match the file")
    }

    func test_givenTheReferenceScriptsName_whenOpened_thenSavingNeverSuggestsIt() async throws {
        // The hand-verified reference must not be overwritten by default.
        let model = modelWithCatalog()
        let url = try writeScript(named: "randomcatalogsample.psc")

        await model.openScript(at: url)

        XCTAssertNotEqual(model.suggestedScriptFileName.lowercased(), "randomcatalogsample.psc")
    }

    func test_givenAnOpenedScript_whenUndone_thenTheEarlierRulesSizeAndBalanceComeBack() async throws {
        let model = modelWithCatalog()
        model.rules.add(.path)
        model.sampleSize = 50
        let before = model.rules
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
        let url = try writeScript()

        undoManager.beginUndoGrouping()
        await model.openScript(at: url)
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

    func test_givenAnOpenedScript_whenTheAppNextLaunches_thenItsRulesAreTheSavedSession() async throws {
        let store = InMemoryRecentCatalogStore()
        let model = modelWithCatalog(store: store)

        await model.openScript(at: try writeScript())

        let session = try XCTUnwrap(SavedSession.decode(store.loadSession()))
        XCTAssertEqual(session.sampleSize, 321)
        XCTAssertEqual(session.rules, model.rules)
    }

    // MARK: - A script edited by hand

    func test_givenAHandEditedScript_whenOpened_thenItAsksFirstAndChangesNothingYet() async throws {
        let model = modelWithCatalog()
        model.rules.add(.path)
        let before = model.rules
        let url = try writeScript { $0.replacingOccurrences(of: "ROWID_MAX_SAMPLE_ATTEMPTS = 8;", with: "ROWID_MAX_SAMPLE_ATTEMPTS = 20;") }

        await model.openScript(at: url)

        guard case .confirm(let pending) = model.scriptOpenPrompt else {
            return XCTFail("expected a confirmation, got \(String(describing: model.scriptOpenPrompt))")
        }
        XCTAssertEqual(pending.script.fileOnlyLines.map(\.text), ["  ROWID_MAX_SAMPLE_ATTEMPTS = 20;"])
        XCTAssertEqual(model.rules, before)
    }

    func test_givenAHandEditedScript_whenConfirmed_thenTheRecoveredRulesOpen() async throws {
        let model = modelWithCatalog()
        let url = try writeScript { $0.replacingOccurrences(of: "Rating >= 4", with: "Rating > 4") }

        await model.openScript(at: url)
        model.confirmScriptOpen(try XCTUnwrap(pendingOpening(model)))

        XCTAssertNil(model.scriptOpenPrompt)
        XCTAssertEqual(model.currentFilter, SampleFilter(root: RuleGroup(match: .all, rules: [.pendingDeletion(false)])))
        XCTAssertEqual(model.sampleSize, 321)
        XCTAssertEqual(model.scriptFileStatus, "Opened RandomRated4Plus.psc; saving replaces its hand edits")
    }

    func test_givenAHandEditedScript_whenCancelled_thenNothingChanges() async throws {
        let model = modelWithCatalog()
        model.rules.add(.path)
        let before = model.rules
        let url = try writeScript { $0.replacingOccurrences(of: "Rating >= 4", with: "Rating > 4") }

        await model.openScript(at: url)
        model.dismissScriptOpenPrompt()

        XCTAssertNil(model.scriptOpenPrompt)
        XCTAssertEqual(model.rules, before)
        XCTAssertEqual(model.sampleSize, 10_000)
        XCTAssertNil(model.lastSavedScriptURL)
    }

    func test_givenTheAlertWasAlreadyDismissed_whenItsButtonConfirms_thenTheScriptStillOpens() async throws {
        // SwiftUI may clear the alert's binding before running the button's
        // action; the button carries what it confirms.
        let model = modelWithCatalog()
        let url = try writeScript { $0.replacingOccurrences(of: "Rating >= 4", with: "Rating > 4") }
        await model.openScript(at: url)
        let opening = try XCTUnwrap(pendingOpening(model))

        model.dismissScriptOpenPrompt()
        model.confirmScriptOpen(opening)

        XCTAssertEqual(model.sampleSize, 321)
    }

    func test_givenAPendingQuestion_whenAnotherCatalogOpens_thenTheQuestionGoesAndCannotBeConfirmed() async throws {
        // Its keyword checks were made against the old catalog's tree.
        let model = modelWithCatalog()
        let url = try writeScript { $0.replacingOccurrences(of: "Rating >= 4", with: "Rating > 4") }
        await model.openScript(at: url)
        let opening = try XCTUnwrap(pendingOpening(model))
        let path = try makeMinimalCatalogFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }

        model.openCatalog(at: path)
        await model.waitForPendingCatalogOpenForTesting()
        XCTAssertEqual(model.catalogPath, path)
        XCTAssertNil(model.scriptOpenPrompt, "the question went when the catalog opened")
        model.confirmScriptOpen(opening)

        XCTAssertEqual(model.sampleSize, 10_000, "the stale question changed nothing")
    }

    func test_givenMoreThanTheLargestSampleSize_whenOpened_thenItAsksAndTheStatusSaysItWasCapped() async throws {
        let model = modelWithCatalog()
        let url = try writeScript { $0.replacingOccurrences(of: "SAMPLE_SIZE = 321;", with: "SAMPLE_SIZE = 5000000;") }

        await model.openScript(at: url)
        model.confirmScriptOpen(try XCTUnwrap(pendingOpening(model)))

        XCTAssertEqual(model.sampleSize, SampleBuilderModel.sampleSizeRange.upperBound)
        XCTAssertEqual(model.scriptFileStatus, "Opened RandomRated4Plus.psc; its sample size was capped")
    }

    func test_givenAScriptSavedAsUTF16_whenOpened_thenItOpens() async throws {
        let model = modelWithCatalog()
        let url = folder.appendingPathComponent("Wide.psc")
        let script = RandomSampleScriptGenerator.generate(sampleSize: 321, filter: savedFilter, folderBalance: .balanced)
        try XCTUnwrap(script.data(using: .utf16)).write(to: url)

        await model.openScript(at: url)

        XCTAssertNil(model.scriptOpenPrompt)
        XCTAssertEqual(model.currentFilter, savedFilter)
    }

    func test_givenTheSameScriptOpenedTwice_thenTheSecondOpenChangesNothing() async throws {
        // Swapping in equal rules would only renumber the rows, and put a
        // do-nothing "Open Script" step on the undo stack. (Checked by row
        // identity: a test's hand-made undo groups keep even empty groups,
        // unlike the app's per-event ones, so counting steps would mislead.)
        let model = modelWithCatalog()
        let url = try writeScript()
        await model.openScript(at: url)
        let afterFirstOpen = model.rules

        await model.openScript(at: url)

        XCTAssertEqual(model.rules, afterFirstOpen, "same rows, same identities")
        XCTAssertEqual(model.scriptFileStatus, "Opened RandomRated4Plus.psc")
    }

    // MARK: - Files that can't be opened

    func test_givenAFileThatIsNotASamplingScript_whenOpened_thenItSaysWhyAndChangesNothing() async throws {
        let model = modelWithCatalog()
        let url = folder.appendingPathComponent("Notes.psc")
        try Data("begin\n  ShowMessage('hi');\nend;\n".utf8).write(to: url)

        await model.openScript(at: url)

        guard case .cannotOpen(let fileName, _) = model.scriptOpenPrompt else {
            return XCTFail("expected an explanation, got \(String(describing: model.scriptOpenPrompt))")
        }
        XCTAssertEqual(fileName, "Notes.psc")
        XCTAssertTrue(model.rules.rules.isEmpty)
    }

    func test_givenAFileFarLargerThanAScript_whenOpened_thenItSaysSoWithoutReadingIt() async throws {
        let model = modelWithCatalog()
        let url = folder.appendingPathComponent("Huge.psc")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(SampleBuilderModel.maximumScriptSize + 1))
        try handle.close()

        await model.openScript(at: url)

        guard case .cannotOpen(_, let reason) = model.scriptOpenPrompt else {
            return XCTFail("expected an explanation, got \(String(describing: model.scriptOpenPrompt))")
        }
        XCTAssertTrue(reason.contains("larger"), reason)
    }

    func test_givenALinkToAFileFarLargerThanAScript_whenOpened_thenItIsRefusedWithoutReadingItWhole() async throws {
        // A link's own size is tiny; what's read is the file it points to.
        let model = modelWithCatalog()
        let target = folder.appendingPathComponent("Huge.bin")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: 2_000_000_000)
        try handle.close()
        let link = folder.appendingPathComponent("Link.psc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let start = Date()

        await model.openScript(at: link)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "didn't read 2 GB")
        guard case .cannotOpen(_, let reason) = model.scriptOpenPrompt else {
            return XCTFail("expected an explanation, got \(String(describing: model.scriptOpenPrompt))")
        }
        XCTAssertTrue(reason.contains("larger"), reason)
    }

    func test_givenAMissingFile_whenOpened_thenItSaysWhy() async {
        let model = modelWithCatalog()

        await model.openScript(at: folder.appendingPathComponent("Gone.psc"))

        guard case .cannotOpen = model.scriptOpenPrompt else {
            return XCTFail("expected an explanation, got \(String(describing: model.scriptOpenPrompt))")
        }
    }
}
