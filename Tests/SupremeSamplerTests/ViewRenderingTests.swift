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
///    `ContentView.copyScript`) can be tested for real:
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

    // MARK: - SampleSettingsView

    func test_givenDefaultState_whenBuildingSampleSettingsView_thenBodyDoesNotCrash() {
        let view = SampleSettingsView(model: SampleBuilderModel.forTesting())
        _ = view.body
    }

    func test_givenRules_whenBuildingSampleSettingsView_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel.forTesting()
        model.rules.add(.rating)
        model.rules.add(.keyword)
        model.rules.addGroup()
        let view = SampleSettingsView(model: model)
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
        group.add(.keyword)
        group.addGroup()
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
            .keyword(KeywordRuleDraft()),
            .keyword(KeywordRuleDraft(operator: .isAllOf, selectedGUIDs: ["prop-pines"])),
            .keyword(KeywordRuleDraft(operator: .hasNoPart, text: "Pines")),
            .keyword(KeywordRuleDraft(operator: .isEmpty)),
            .keywordCount(KeywordCountRuleDraft()),
            .path(PathRuleDraft()),
            .label(LabelRuleDraft()),
            .fileType(FileTypeRuleDraft()),
            .bookmark(BookmarkRuleDraft()),
            .pendingDeletion(PendingDeletionRuleDraft()),
            .group(RuleGroupDraft(match: .none, rules: [RuleDraft(.rating(RatingRuleDraft()))])),
        ] {
            _ = RuleRow(rule: .constant(RuleDraft(content)), propTree: nestedTree, depth: 1, actions: .none).body
        }
    }

    func test_givenAKeywordRule_whenBuildingItsControls_thenBothEmptyAndNonEmptyTreesAndPathTextRender() {
        _ = KeywordRuleControls(rule: .constant(KeywordRuleDraft()), propTree: []).body
        _ = KeywordRuleControls(
            rule: .constant(KeywordRuleDraft(operator: .isNoneOf, selectedGUIDs: ["cat-nature"])), propTree: nestedTree
        ).body
        _ = KeywordRuleControls(rule: .constant(KeywordRuleDraft(operator: .hasPart, text: "Pines")), propTree: nestedTree)
            .body
        _ = KeywordRuleControls(rule: .constant(KeywordRuleDraft(operator: .hasPart, text: "")), propTree: nestedTree)
            .body
    }

    func test_givenAKeywordTreeAndPicks_whenBuildingThePickerPopover_thenBodyDoesNotCrash() {
        _ = KeywordTreePicker(propTree: [], selection: .constant([])).body
        _ = KeywordTreePicker(propTree: nestedTree, selection: .constant(["prop-pines"])).body
    }

    func test_givenMatchingKeywords_whenBuildingTheMatchesList_thenBodyDoesNotCrash() {
        _ = KeywordMatchesList(paths: []).body
        _ = KeywordMatchesList(paths: KeywordPath.all(in: nestedTree)).body
    }

    func test_givenAPathRule_whenBuildingItsControls_thenEachKindRenders() {
        for pathOperator in PathOperator.allCases {
            _ = PathRuleControls(rule: .constant(PathRuleDraft(operator: pathOperator, text: "/2019/"))).body
        }
    }

    func test_givenALabelRule_whenBuildingItsControls_thenEachLoadStateRenders() {
        let loaded = CatalogValues.loaded([ValueCount(value: "", count: 3), ValueCount(value: "選択", count: 1)])
        for values in [CatalogValues.loading, loaded, .failed("no idLabel column")] {
            _ = LabelRuleControls(rule: .constant(LabelRuleDraft(mode: .none, selectedLabels: [""])), labels: values).body
            _ = CatalogValuePicker(values: values, selection: .constant([""]), noun: "labels").body
        }
    }

    /// A draft held outside SwiftUI, so a test can edit it through a
    /// view's binding and read the result -- a `Binding` built from a
    /// getter/setter pair over this box.
    private final class DraftBox {
        var group: RuleGroupDraft
        init(_ group: RuleGroupDraft) { self.group = group }
        var binding: Binding<RuleGroupDraft> { Binding(get: { self.group }, set: { self.group = $0 }) }
    }

    func test_givenAPathRowAmongOthers_whenItsPlusIsClicked_thenARuleOfTheSameFieldFollowsIt() {
        var draft = RuleGroupDraft()
        draft.add(.path)
        draft.add(.rating)
        let box = DraftBox(draft)
        let editor = RuleGroupEditor(group: box.binding, propTree: [], depth: 0, onRemove: nil)

        editor.actions(for: box.group.rules[0]).add(.rule)

        XCTAssertEqual(box.group.rules.map(\.field), [.path, .path, .rating])
    }

    func test_givenARowWhoseFieldChanged_whenItsOldControlWritesLate_thenTheNewFieldIsKept() {
        var draft = RuleGroupDraft()
        draft.add(.path)
        let box = DraftBox(draft)
        let rowBinding = Binding(get: { box.group.rules[0] }, set: { box.group.rules[0] = $0 })
        let row = RuleRow(rule: rowBinding, propTree: [], depth: 0, actions: .none)
        let oldPathControl = row.payload(
            fallback: PathRuleDraft(), { if case .path(let p) = $0 { return p }; return nil }, RuleDraft.Content.path)

        box.group.changeField(ofRule: box.group.rules[0].id, to: .keyword)
        oldPathControl.wrappedValue = PathRuleDraft(operator: .contains, text: "late")

        XCTAssertEqual(box.group.rules[0].field, .keyword)
    }

    func test_givenTheAddButton_whenClickedWithOrWithoutOption_thenOptionAddsANestedGroup() {
        XCTAssertEqual(AddRuleMenu.Choice.forClick(optionHeld: false), .rule)
        XCTAssertEqual(AddRuleMenu.Choice.forClick(optionHeld: true), .group)
        _ = AddRuleMenu(accessibilityLabel: "Add", onAdd: { _ in }).body
    }

    func test_givenAFileTypeRule_whenBuildingItsControls_thenEachLoadStateRenders() {
        let loaded = CatalogValues.loaded([ValueCount(value: "jpg", count: 9), ValueCount(value: "", count: 1)])
        for values in [CatalogValues.loading, loaded, .failed("timeout")] {
            _ = FileTypeRuleControls(rule: .constant(FileTypeRuleDraft()), fileTypes: values).body
        }
    }

    func test_givenABookmarkRule_whenBuildingItsControls_thenEachLoadStateRenders() {
        let loaded = CatalogValues.loaded([ValueCount(value: "0", count: 9), ValueCount(value: "5", count: 1)])
        for values in [CatalogValues.loading, loaded, .failed("x")] {
            _ = BookmarkRuleControls(rule: .constant(BookmarkRuleDraft(selectedValues: ["5"])), bookmarks: values).body
        }
    }

    func test_givenAPendingDeletionRule_whenBuildingItsControls_thenBothChoicesRender() {
        for isPending in [true, false] {
            _ = PendingDeletionRuleControls(rule: .constant(PendingDeletionRuleDraft(isPending: isPending))).body
        }
    }

    func test_givenAKeywordCountRule_whenBuildingItsControls_thenBodyDoesNotCrash() {
        for value in [0, 1, 99] {
            _ = KeywordCountRuleControls(rule: .constant(KeywordCountRuleDraft(comparison: .isNot, value: value))).body
        }
    }

    func test_givenARatingRule_whenBuildingItsControls_thenBodyDoesNotCrash() {
        _ = RatingRuleControls(rule: .constant(RatingRuleDraft(comparison: .atMost, value: 0))).body
    }

    func test_givenEachFolderBalance_whenBuildingSampleSettingsView_thenBodyDoesNotCrash() {
        for balance in FolderBalance.allCases {
            let model = SampleBuilderModel.forTesting()
            model.folderBalance = balance
            _ = SampleSettingsView(model: model).body
        }
    }

    func test_givenEachFolderAuditState_whenBuildingSampleSettingsView_thenBodyDoesNotCrash() async {
        let folders = [FolderPhotoCount(path: "/p/a/", photos: 5), FolderPhotoCount(path: "/p/b/", photos: 1)]
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests(folders: folders))
        model.folderBalance = .balanced

        model.refreshFolderAudit()
        _ = SampleSettingsView(model: model).body  // checking folders
        await model.waitForPendingFolderAuditForTesting()
        XCTAssertNotNil(model.folderBalancePreview)
        _ = SampleSettingsView(model: model).body  // the preview
    }

    func test_givenShares_whenFormattingPercents_thenATinyShareIsNotShownAsZero() {
        XCTAssertEqual(SampleSettingsView.percent(0.806), "81%")
        XCTAssertEqual(SampleSettingsView.percent(0.001), "<1%")
        XCTAssertEqual(SampleSettingsView.percent(0), "0%")
    }

    func test_givenCountingMatches_whenBuildingSampleSettingsView_thenBodyDoesNotCrash() {
        // isCountingMatches is set synchronously at the start of
        // refreshMatchingCount(), before the query itself runs, so this
        // is observable without awaiting anything -- same technique as
        // the CatalogPickerView "opening in progress" test above.
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests(matchDelayNanoseconds: 50_000_000))
        model.refreshMatchingCount()
        XCTAssertTrue(model.isCountingMatches)

        let view = SampleSettingsView(model: model)
        _ = view.body
    }

    func test_givenMatchCountAndError_whenBuildingSampleSettingsView_thenBodyDoesNotCrash() async {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests())
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()
        model.reportPickerFailure(NSError(domain: "test", code: 1))

        let view = SampleSettingsView(model: model)
        _ = view.body
    }

    // MARK: - ScriptPreviewView

    func test_givenGeneratedScript_whenBuildingScriptPreviewView_thenBodyDoesNotCrash() {
        let view = ScriptPreviewView(model: SampleBuilderModel.forTesting())
        _ = view.body
    }

    func test_givenGeneratedScript_whenPreviewing_thenItShowsTheScriptHighlighted() {
        let model = SampleBuilderModel.forTesting()
        let view = ScriptPreviewView(model: model)

        XCTAssertEqual(view.highlightedScript, ScriptHighlighter.highlight(model.generatedScript))
        XCTAssertTrue(view.highlightedScript.runs.contains { $0.foregroundColor != nil })
    }

    // MARK: - Copy (toolbar and Edit > Copy Script)

    func test_givenTheWindowsCopyAction_whenCopying_thenTheClipboardReceivesTheScript() {
        // A fake, never the real NSPasteboard.general -- see
        // ClipboardWriting's doc comment. An earlier version of this
        // test wrote to the real system clipboard, which leaked a test
        // marker string into it outside the test run entirely.
        let clipboard = FakeClipboard()
        let model = SampleBuilderModel.forTesting()
        model.rules.add(.rating)
        let view = ContentView(model: model, clipboard: clipboard)

        view.copyScript()

        XCTAssertEqual(clipboard.writtenText, model.generatedScript)
        XCTAssertEqual(model.copyCount, 1)
    }

    func test_givenACatalogPath_whenTitlingTheWindow_thenTheTitleIsTheFileAndTheSubtitleItsFolder() {
        let model = SampleBuilderModel.forTesting()
        let view = ContentView(model: model)
        XCTAssertEqual(view.catalogTitle, "Supreme Sampler")
        XCTAssertEqual(view.catalogFolder, "")

        model.injectCatalogForTesting(FakeCatalogForViewTests())  // path "test"
        XCTAssertEqual(view.catalogTitle, "test")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            ContentView.folderDisplay(forCatalogAt: home + "/Pictures/Library/a.cat.db"), "~/Pictures/Library")
        XCTAssertEqual(ContentView.folderDisplay(forCatalogAt: "/Volumes/Photos/a.cat.db"), "/Volumes/Photos")
    }

    func test_givenAnyModel_whenBuildingTheToolbarButtons_thenBodyDoesNotCrash() {
        _ = ScriptToolbarButtons(model: SampleBuilderModel.forTesting(), copy: {}, save: {}).body
    }

    func test_givenEachForecast_whenAskingForTheSaveHelp_thenAShortOrEmptySampleIsSpelledOut() {
        XCTAssertEqual(
            ScriptToolbarButtons.saveHelp(canSave: false, forecast: nil), "Available once the match count has finished")
        XCTAssertEqual(
            ScriptToolbarButtons.saveHelp(canSave: true, forecast: SampleForecast(matching: 50, requested: 10)),
            "Save as a .psc file (⌘S)")
        XCTAssertEqual(
            ScriptToolbarButtons.saveHelp(canSave: true, forecast: SampleForecast(matching: 2, requested: 10_000)),
            "Save as a .psc file (⌘S). It will pick 2, not the \(10_000.formatted()) requested.")
        XCTAssertEqual(
            ScriptToolbarButtons.saveHelp(canSave: true, forecast: SampleForecast(matching: 0, requested: 10)),
            "Save as a .psc file (⌘S). No photos match it right now.")
    }

    // MARK: - MatchSummaryView

    private func countedModel(matching count: Int = 0) async -> SampleBuilderModel {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(FakeCatalogForViewTests(matchCount: count))
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()
        return model
    }

    func test_givenEachCountState_whenBuildingMatchSummaryView_thenBodyDoesNotCrash() async {
        _ = MatchSummaryView(model: SampleBuilderModel.forTesting()).body  // not counted

        for count in [0, 2, 1_000_000] {
            let model = await countedModel(matching: count)
            _ = MatchSummaryView(model: model).body  // empty, short, full
        }

        let counting = await countedModel(matching: 5)
        counting.injectCatalogForTesting(FakeCatalogForViewTests(matchDelayNanoseconds: 50_000_000))
        counting.refreshMatchingCount()
        XCTAssertTrue(counting.isCountingMatches)
        _ = MatchSummaryView(model: counting).body  // an old count, dimmed

        let failed = await countedModel()
        failed.reportPickerFailure(NSError(domain: "test", code: 1))
        _ = MatchSummaryView(model: failed).body  // the error, with Try Again
    }

    func test_givenASavedOrFailedSave_whenBuildingMatchSummaryView_thenBodyDoesNotCrash() async {
        let saved = await countedModel()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".psc")
        defer { try? FileManager.default.removeItem(at: destination) }
        await saved.saveScript(using: FakeDestinationChooser(answer: destination), startingIn: nil)
        XCTAssertNotNil(saved.lastSavedScriptURL)
        _ = MatchSummaryView(model: saved).body

        let failed = await countedModel()
        await failed.saveScript(
            using: FakeDestinationChooser(answer: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/A.psc")),
            startingIn: nil)
        XCTAssertNotNil(failed.saveErrorMessage)
        _ = MatchSummaryView(model: failed).body
    }

    func test_givenCounts_whenWritingTheHeadline_thenItReadsAsASentence() {
        XCTAssertEqual(MatchSummaryView.headlineText(count: 0), "No photos match")
        XCTAssertEqual(MatchSummaryView.headlineText(count: 1), "1 photo matches")
        // `.formatted()` follows the machine's locale, so the expectation
        // does too, rather than assuming "," as the thousands separator.
        XCTAssertEqual(MatchSummaryView.headlineText(count: 245_112), "\(245_112.formatted()) photos match")
    }

    func test_givenEachFolderBalance_whenDescribingAFullSample_thenTheBalanceIsNamed() {
        let forecast = SampleForecast(matching: 50_000, requested: 10_000)
        XCTAssertEqual(
            MatchSummaryView.fullSampleText(forecast: forecast, balance: .off),
            "The script will pick \(10_000.formatted()) of them at random.")
        XCTAssertEqual(
            MatchSummaryView.fullSampleText(forecast: forecast, balance: .balanced),
            "The script will pick \(10_000.formatted()) of them at random, balanced across folders.")
        XCTAssertEqual(
            MatchSummaryView.fullSampleText(forecast: forecast, balance: .equal),
            "The script will pick \(10_000.formatted()) of them at random, spread equally across folders.")
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
