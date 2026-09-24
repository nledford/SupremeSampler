import XCTest

@testable import SupremeSampler

/// Specifies saving the generated script to a `.psc` file: the user picks
/// where in a save panel (faked here), and the file gets the current
/// script in the verified on-disk format. Real files, in a temp folder.
@MainActor
final class ScriptSavingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private struct CountingCatalog: SampleBuilderCatalog {
        var delayNanoseconds: UInt64 = 0
        func listPropTree() async throws -> [CatalogPropNode] { [] }
        func matchingItemCount(for filter: SampleFilter) async throws -> Int {
            try await Task.sleep(nanoseconds: delayNanoseconds)
            return 42
        }
        func folderPhotoCounts(for filter: SampleFilter) async throws -> [FolderPhotoCount] { [] }
    }

    /// A model with a catalog open and the pre-flight count finished --
    /// the state in which saving is allowed.
    private func modelReadyToSave() async -> SampleBuilderModel {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(CountingCatalog())
        model.rules.add(.rating)
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()
        return model
    }

    // MARK: - Saving

    func test_givenACountedFilter_whenSavingToAChosenFile_thenTheFileHoldsTheScriptInPSCFormat() async throws {
        let model = await modelReadyToSave()
        let destination = folder.appendingPathComponent("ThreeStarSample.psc")

        await model.saveScript(using: FakeDestinationChooser(answer: destination), startingIn: nil)

        let saved = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(saved.contains("Rating >= 3"))
        XCTAssertFalse(saved.contains("\r"), "LF line endings, like the committed reference script")
        XCTAssertEqual(model.lastSavedScriptURL, destination)
        XCTAssertNil(model.saveErrorMessage)
    }

    func test_givenAnExistingFileWasChosen_whenSaving_thenItIsReplaced() async throws {
        // The save panel has already asked "Replace?" by the time a
        // destination comes back, so saving just writes.
        let model = await modelReadyToSave()
        let destination = folder.appendingPathComponent("Existing.psc")
        try Data("old contents".utf8).write(to: destination)

        await model.saveScript(using: FakeDestinationChooser(answer: destination), startingIn: nil)

        let saved = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(saved.contains("old contents"))
        XCTAssertTrue(saved.contains("Rating >= 3"))
    }

    func test_givenTheSavePanel_whenSaving_thenItSuggestsTheDefaultNameAndStartingFolder() async {
        let model = await modelReadyToSave()
        let chooser = FakeDestinationChooser(answer: nil)

        await model.saveScript(using: chooser, startingIn: folder)

        XCTAssertEqual(chooser.askedFileName, PSCFile.suggestedFileName)
        XCTAssertEqual(chooser.askedDirectory, folder)
    }

    func test_givenTheUserCancels_whenSaving_thenNothingIsWrittenAndNothingIsReported() async throws {
        let model = await modelReadyToSave()

        await model.saveScript(using: FakeDestinationChooser(answer: nil), startingIn: folder)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertNil(model.lastSavedScriptURL)
        XCTAssertNil(model.saveErrorMessage)
    }

    func test_givenAnUnwritableDestination_whenSaving_thenTheErrorIsReported() async {
        let model = await modelReadyToSave()
        let destination = folder.appendingPathComponent("no-such-folder/Sample.psc")

        await model.saveScript(using: FakeDestinationChooser(answer: destination), startingIn: nil)

        XCTAssertNil(model.lastSavedScriptURL)
        XCTAssertNotNil(model.saveErrorMessage)
    }

    func test_givenAPreviousSave_whenTheNextSaveFails_thenTheOldSuccessIsNoLongerShown() async {
        let model = await modelReadyToSave()
        await model.saveScript(using: FakeDestinationChooser(answer: folder.appendingPathComponent("A.psc")), startingIn: nil)

        await model.saveScript(
            using: FakeDestinationChooser(answer: folder.appendingPathComponent("missing/B.psc")), startingIn: nil)

        XCTAssertNil(model.lastSavedScriptURL)
        XCTAssertNotNil(model.saveErrorMessage)
    }

    // MARK: - When saving is allowed

    // "Never let a script be generated for a filter the user hasn't seen
    // validated against real data" (PRODUCT.md): a file on disk is the
    // artifact that outlives the session, so it waits for the count.

    func test_givenNoCatalogOpen_whenAskingIfSavingIsAllowed_thenItIsNot() {
        XCTAssertFalse(SampleBuilderModel.forTesting().canSaveScript)
    }

    func test_givenTheCountIsStillRunning_whenSaving_thenTheSavePanelIsNeverShown() async {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(CountingCatalog(delayNanoseconds: 200_000_000))
        model.refreshMatchingCount()
        let chooser = FakeDestinationChooser(answer: folder.appendingPathComponent("Early.psc"))

        XCTAssertFalse(model.canSaveScript)
        await model.saveScript(using: chooser, startingIn: nil)

        XCTAssertEqual(chooser.timesAsked, 0)
        await model.waitForPendingMatchCountForTesting()
    }

    func test_givenTheCountHasFinished_whenAskingIfSavingIsAllowed_thenItIs() async {
        let model = await modelReadyToSave()
        XCTAssertTrue(model.canSaveScript)
    }

    func test_givenTheFilterChangedAfterSaving_whenLookingAtTheLastSave_thenItIsCleared() async {
        // "Saved Foo.psc" must not linger next to a script that no longer
        // matches what's in Foo.psc.
        let model = await modelReadyToSave()
        await model.saveScript(using: FakeDestinationChooser(answer: folder.appendingPathComponent("A.psc")), startingIn: nil)

        model.rules.add(.keyword)

        XCTAssertNil(model.lastSavedScriptURL)
    }

    func test_givenTheSampleSizeChangedAfterSaving_whenLookingAtTheLastSave_thenItIsCleared() async {
        let model = await modelReadyToSave()
        await model.saveScript(using: FakeDestinationChooser(answer: folder.appendingPathComponent("A.psc")), startingIn: nil)

        model.sampleSize = 250

        XCTAssertNil(model.lastSavedScriptURL)
    }

    func test_givenTheFolderBalanceChangedAfterSaving_whenLookingAtTheLastSave_thenItIsCleared() async {
        let model = await modelReadyToSave()
        await model.saveScript(using: FakeDestinationChooser(answer: folder.appendingPathComponent("A.psc")), startingIn: nil)

        model.folderBalance = .balanced

        XCTAssertNil(model.lastSavedScriptURL)
    }

    func test_givenFolderBalanceOn_whenSaving_thenTheFileHoldsTheBalancedScript() async throws {
        let model = await modelReadyToSave()
        model.folderBalance = .equal
        let destination = folder.appendingPathComponent("Equal.psc")

        await model.saveScript(using: FakeDestinationChooser(answer: destination), startingIn: nil)

        let saved = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(saved.contains("  AGUIDs := BalancedItemGUIDs(SAMPLE_SIZE);"))
        XCTAssertEqual(model.lastSavedScriptURL, destination)
    }

    func test_givenAnEditIsUndoneAfterSaving_whenLookingAtTheLastSave_thenItShowsAgain() async {
        // The status tracks whether the on-screen script matches the
        // file, so returning to the saved state brings it back.
        let model = await modelReadyToSave()
        let destination = folder.appendingPathComponent("A.psc")
        await model.saveScript(using: FakeDestinationChooser(answer: destination), startingIn: nil)

        model.sampleSize = 250
        model.sampleSize = 10_000

        XCTAssertEqual(model.lastSavedScriptURL, destination)
    }
}
