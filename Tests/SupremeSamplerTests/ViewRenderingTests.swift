import SwiftUI
import XCTest

@testable import SupremeSampler

/// SwiftUI view `body` properties are declarative descriptions, not
/// executable business logic in the traditional sense -- there's no
/// equivalent of asserting "clicking this button produces this output"
/// without a full UI-testing harness (XCUITest), which this project
/// doesn't have. What these tests *can* honestly verify:
///
/// 1. Constructing each view with a range of representative model
///    states and evaluating `.body` doesn't crash -- accessing a
///    computed property genuinely executes its getter, the same way
///    calling a pure function in Rust/Python/TS executes its body, so
///    this does exercise the real branch logic (the `if`/`else` in each
///    view), just without rendering pixels or letting anyone click
///    anything.
/// 2. Logic that got *pulled out* of a view for exactly this reason
///    (`CatalogPickerView.handleFileImporterResult`,
///    `ScriptPreviewView.copyToClipboard`) can be tested for real:
///    called directly, with real assertions on what it did (the model's
///    resulting state, the actual system clipboard).
///
/// Where this stops short of proof: it can't confirm a `Picker`/`List`/
/// `TextField` is wired to the right binding, or that tapping a real
/// button on screen produces the described effect -- that's what the
/// manual `just run` pass covers instead (see AGENTS.md).
@MainActor
final class ViewRenderingTests: XCTestCase {
    // MARK: - ContentView

    func test_givenNoCatalogOpen_whenBuildingContentView_thenBodyDoesNotCrash() {
        let view = ContentView(model: SampleBuilderModel.forTesting())
        _ = view.body
    }

    func test_givenCatalogOpen_whenBuildingContentView_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests())
        let view = ContentView(model: model)
        _ = view.body
    }

    func test_givenSuccessfulPick_whenHandlingCatalogFileImporterResult_thenModelStartsOpening() {
        // Exercises the menu-bar "Open Catalog…" command's handler
        // directly, the same technique CatalogPickerView's equivalent
        // test below uses -- no way to drive the system Open panel or
        // the app's real menu bar from XCTest.
        let model = SampleBuilderModel.forTesting()
        let view = ContentView(model: model)

        view.handleCatalogFileImporterResult(.success(URL(fileURLWithPath: "/nonexistent/catalog.cat.db")))

        XCTAssertTrue(model.isOpeningCatalog)
    }

    func test_givenFailedPick_whenHandlingCatalogFileImporterResult_thenModelReportsError() {
        let model = SampleBuilderModel.forTesting()
        let view = ContentView(model: model)

        view.handleCatalogFileImporterResult(.failure(NSError(domain: "test", code: 1)))

        XCTAssertNotNil(model.errorMessage)
    }

    func test_givenCatalogAlreadyOpen_whenHandlingCatalogFileImporterResultAgain_thenSwitchesToNewCatalog() {
        // The whole point of the menu command: it has to work from the
        // already-has-a-catalog-open state too, not just the initial
        // picker screen -- this is what distinguishes it from
        // CatalogPickerView's own (first-open-only) handler.
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests(), propTree: [CatalogPropNode(guid: "g1", name: "Old", children: [])])
        let view = ContentView(model: model)

        view.handleCatalogFileImporterResult(.success(URL(fileURLWithPath: "/nonexistent/other-catalog.cat.db")))

        XCTAssertTrue(model.isOpeningCatalog)
    }

    // MARK: - CatalogPickerView

    func test_givenDefaultState_whenBuildingCatalogPickerView_thenBodyDoesNotCrash() {
        let view = CatalogPickerView(model: SampleBuilderModel.forTesting())
        _ = view.body
    }

    func test_givenOpeningInProgress_whenBuildingCatalogPickerView_thenBodyDoesNotCrash() {
        // isOpeningCatalog is set synchronously before openCatalog's
        // Task even starts running, so this is observable immediately
        // without awaiting anything.
        let model = SampleBuilderModel.forTesting()
        model.openCatalog(at: "/nonexistent/\(UUID().uuidString).sqlite")
        XCTAssertTrue(model.isOpeningCatalog)

        let view = CatalogPickerView(model: model)
        _ = view.body
    }

    func test_givenErrorMessage_whenBuildingCatalogPickerView_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel.forTesting()
        model.reportPickerFailure(NSError(domain: "test", code: 1))

        let view = CatalogPickerView(model: model)
        _ = view.body
    }

    func test_givenSuccessfulPick_whenHandlingFileImporterResult_thenModelStartsOpening() {
        let model = SampleBuilderModel.forTesting()
        let view = CatalogPickerView(model: model)

        view.handleFileImporterResult(.success(URL(fileURLWithPath: "/nonexistent/catalog.cat.db")))

        // Real assertion, not just "didn't crash": the model actually
        // received the call and started its (doomed, since the path is
        // fake) open attempt.
        XCTAssertTrue(model.isOpeningCatalog)
    }

    func test_givenFailedPick_whenHandlingFileImporterResult_thenModelReportsError() {
        let model = SampleBuilderModel.forTesting()
        let view = CatalogPickerView(model: model)

        view.handleFileImporterResult(.failure(NSError(domain: "test", code: 1)))

        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - SampleBuilderView

    func test_givenDefaultState_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        let view = SampleBuilderView(model: SampleBuilderModel.forTesting())
        _ = view.body
    }

    func test_givenRules_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel.forTesting()
        model.rules.add(.rating)
        model.rules.add(.category)
        model.rules.add(.group)
        let view = SampleBuilderView(model: model)
        _ = view.body
    }

    // The rule editor's rows are their own view structs; SwiftUI only
    // evaluates a child's `body` while really rendering, so each one is
    // built directly here, once per meaningful state.

    private let nestedTree = [
        CatalogPropNode(
            guid: "cat-nature",
            name: "Nature",
            children: [CatalogPropNode(guid: "prop-pines", name: "Pines", children: [])]
        )
    ]

    func test_givenEachGroupMatchAndDepth_whenBuildingRuleGroupEditor_thenBodyDoesNotCrash() {
        var group = RuleGroupDraft()
        group.add(.rating)
        group.add(.category)
        group.add(.group)
        for match in [GroupMatch.all, .any, .none] {
            group.match = match
            _ = RuleGroupEditor(group: .constant(group), propTree: nestedTree, depth: 0, onRemove: nil).body
            _ = RuleGroupEditor(group: .constant(group), propTree: nestedTree, depth: 2, onRemove: {}).body
        }
        _ = RuleGroupEditor(group: .constant(RuleGroupDraft()), propTree: [], depth: 0, onRemove: nil).body
    }

    func test_givenEachRuleKind_whenBuildingRuleRow_thenBodyDoesNotCrash() {
        for content: RuleDraft.Content in [
            .rating(RatingRuleDraft()),
            .category(CategoryRuleDraft()),
            .category(CategoryRuleDraft(mode: .all, selectedGUIDs: ["prop-pines"])),
            .path(PathRuleDraft()),
            .label(LabelRuleDraft()),
            .fileType(FileTypeRuleDraft()),
            .bookmark(BookmarkRuleDraft()),
            .pendingDeletion(PendingDeletionRuleDraft()),
            .group(RuleGroupDraft(match: .none, rules: [RuleDraft(.rating(RatingRuleDraft()))])),
        ] {
            _ = RuleRow(rule: .constant(RuleDraft(content)), propTree: nestedTree, depth: 1, onRemove: {}).body
        }
    }

    func test_givenACategoryRule_whenBuildingItsRow_thenBothEmptyAndNonEmptyTreesRender() {
        _ = CategoryRuleRow(rule: .constant(CategoryRuleDraft()), propTree: [], onRemove: {}).body
        _ = CategoryRuleRow(
            rule: .constant(CategoryRuleDraft(mode: .none, selectedGUIDs: ["cat-nature"])),
            propTree: nestedTree,
            onRemove: {}
        ).body
    }

    func test_givenAPathRule_whenBuildingItsRow_thenEachKindRenders() {
        for pathOperator in PathOperator.allCases {
            _ = PathRuleRow(rule: .constant(PathRuleDraft(operator: pathOperator, text: "/2019/")), onRemove: {}).body
        }
    }

    func test_givenALabelRule_whenBuildingItsRow_thenEachLoadStateRenders() {
        let loaded = CatalogValues.loaded([ValueCount(value: "", count: 3), ValueCount(value: "選択", count: 1)])
        for values in [CatalogValues.loading, loaded, .failed("no idLabel column")] {
            _ = LabelRuleRow(
                rule: .constant(LabelRuleDraft(mode: .none, selectedLabels: [""])), labels: values, onRemove: {}
            ).body
        }
    }

    func test_givenAFileTypeRule_whenBuildingItsRow_thenEachLoadStateRenders() {
        let loaded = CatalogValues.loaded([ValueCount(value: "jpg", count: 9), ValueCount(value: "", count: 1)])
        for values in [CatalogValues.loading, loaded, .failed("timeout")] {
            _ = FileTypeRuleRow(rule: .constant(FileTypeRuleDraft()), fileTypes: values, onRemove: {}).body
        }
    }

    func test_givenABookmarkRule_whenBuildingItsRow_thenEachLoadStateRenders() {
        let loaded = CatalogValues.loaded([ValueCount(value: "0", count: 9), ValueCount(value: "5", count: 1)])
        for values in [CatalogValues.loading, loaded, .failed("x")] {
            _ = BookmarkRuleRow(rule: .constant(BookmarkRuleDraft()), bookmarks: values, onRemove: {}).body
        }
    }

    func test_givenAPendingDeletionRule_whenBuildingItsRow_thenBothChoicesRender() {
        for isPending in [true, false] {
            _ = PendingDeletionRuleRow(rule: .constant(PendingDeletionRuleDraft(isPending: isPending)), onRemove: {}).body
        }
    }

    func test_givenARatingRule_whenBuildingItsRow_thenBodyDoesNotCrash() {
        _ = RatingRuleRow(rule: .constant(RatingRuleDraft(comparison: .atMost, value: 0)), onRemove: {}).body
    }

    func test_givenEachFolderBalance_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        for balance in FolderBalance.allCases {
            let model = SampleBuilderModel.forTesting()
            model.folderBalance = balance
            _ = SampleBuilderView(model: model).body
        }
    }

    func test_givenEachFolderAuditState_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() async {
        let folders = [FolderPhotoCount(path: "/p/a/", photos: 5), FolderPhotoCount(path: "/p/b/", photos: 1)]
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests(folders: folders))
        model.folderBalance = .balanced

        model.refreshFolderAudit()
        _ = SampleBuilderView(model: model).body  // checking folders
        await model.waitForPendingFolderAuditForTesting()
        XCTAssertNotNil(model.folderBalancePreview)
        _ = SampleBuilderView(model: model).body  // the preview
    }

    func test_givenShares_whenFormattingPercents_thenATinyShareIsNotShownAsZero() {
        XCTAssertEqual(SampleBuilderView.percent(0.806), "81%")
        XCTAssertEqual(SampleBuilderView.percent(0.001), "<1%")
        XCTAssertEqual(SampleBuilderView.percent(0), "0%")
    }

    func test_givenCountingMatches_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        // isCountingMatches is set synchronously at the start of
        // refreshMatchingCount(), before the query itself runs, so this
        // is observable without awaiting anything -- same technique as
        // the CatalogPickerView "opening in progress" test above.
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests(matchDelayNanoseconds: 50_000_000))
        model.refreshMatchingCount()
        XCTAssertTrue(model.isCountingMatches)

        let view = SampleBuilderView(model: model)
        _ = view.body
    }

    func test_givenMatchCountAndError_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() async {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests())
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()
        model.reportPickerFailure(NSError(domain: "test", code: 1))

        let view = SampleBuilderView(model: model)
        _ = view.body
    }

    // MARK: - ScriptPreviewView

    func test_givenGeneratedScript_whenBuildingScriptPreviewView_thenBodyDoesNotCrash() {
        let view = ScriptPreviewView(model: SampleBuilderModel.forTesting())
        _ = view.body
    }

    func test_givenText_whenCopyingToClipboard_thenClipboardReceivesIt() {
        // A fake, never the real NSPasteboard.general -- see
        // ClipboardWriting's doc comment. An earlier version of this
        // test wrote to the real system clipboard, which leaked a test
        // marker string into it outside the test run entirely.
        let clipboard = FakeClipboard()
        let view = ScriptPreviewView(model: SampleBuilderModel.forTesting(), clipboard: clipboard)
        let text = "SELECT GUID FROM idCatalogItem;"

        view.copyToClipboard(text)

        XCTAssertEqual(clipboard.writtenText, text)
    }

    // MARK: - ScriptPreviewView: saving

    private func countedModel() async -> SampleBuilderModel {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests())
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()
        return model
    }

    func test_givenTheSaveButton_whenSaving_thenThePaneSavesThroughItsChooserStartingInTheScriptsRepo() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".psc")
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = await countedModel()
        let chooser = FakeDestinationChooser(answer: destination)
        let view = ScriptPreviewView(model: model, destinationChooser: chooser)

        await view.saveScript()

        XCTAssertEqual(chooser.askedDirectory, PSCFile.preferredDirectory())
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(model.lastSavedScriptURL, destination)
    }

    func test_givenASavedOrFailedSave_whenBuildingScriptPreviewView_thenBodyDoesNotCrash() async {
        let saved = await countedModel()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".psc")
        defer { try? FileManager.default.removeItem(at: destination) }
        await saved.saveScript(using: FakeDestinationChooser(answer: destination), startingIn: nil)
        _ = ScriptPreviewView(model: saved, destinationChooser: FakeDestinationChooser(answer: nil)).body

        let failed = await countedModel()
        await failed.saveScript(
            using: FakeDestinationChooser(answer: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/A.psc")),
            startingIn: nil)
        XCTAssertNotNil(failed.saveErrorMessage)
        _ = ScriptPreviewView(model: failed, destinationChooser: FakeDestinationChooser(answer: nil)).body
    }
}

private final class FakeClipboard: ClipboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _writtenText: String?

    var writtenText: String? {
        lock.lock()
        defer { lock.unlock() }
        return _writtenText
    }

    func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        _writtenText = text
    }
}

/// A minimal `SampleBuilderCatalog` fake for view-rendering tests, which
/// only need *some* catalog to be present/absent -- unlike
/// `SampleBuilderModelTests.FakeCatalog`, this doesn't need per-call
/// scripted responses, just a fixed prop list and an optional artificial
/// delay so a test can observe `isCountingMatches == true` before the
/// query resolves.
private struct FakeCatalogForViewTests: SampleBuilderCatalog {
    var propTree: [CatalogPropNode] = []
    var matchCount: Int = 0
    var matchDelayNanoseconds: UInt64 = 0
    var folders: [FolderPhotoCount] = []

    func listPropTree() async throws -> [CatalogPropNode] { propTree }

    func matchingItemCount(for filter: SampleFilter) async throws -> Int {
        if matchDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: matchDelayNanoseconds)
        }
        return matchCount
    }

    func folderPhotoCounts(for filter: SampleFilter) async throws -> [FolderPhotoCount] { folders }
}
