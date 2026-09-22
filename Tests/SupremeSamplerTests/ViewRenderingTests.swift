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
/// `Stepper` is wired to the right binding, or that tapping a real
/// button on screen produces the described effect -- that's what the
/// manual `just run` pass covers instead (see AGENTS.md).
@MainActor
final class ViewRenderingTests: XCTestCase {
    // MARK: - ContentView

    func test_givenNoCatalogOpen_whenBuildingContentView_thenBodyDoesNotCrash() {
        let view = ContentView(model: SampleBuilderModel())
        _ = view.body
    }

    func test_givenCatalogOpen_whenBuildingContentView_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel()
        model.injectCatalogForTesting(FakeCatalogForViewTests())
        let view = ContentView(model: model)
        _ = view.body
    }

    // MARK: - CatalogPickerView

    func test_givenDefaultState_whenBuildingCatalogPickerView_thenBodyDoesNotCrash() {
        let view = CatalogPickerView(model: SampleBuilderModel())
        _ = view.body
    }

    func test_givenOpeningInProgress_whenBuildingCatalogPickerView_thenBodyDoesNotCrash() {
        // isOpeningCatalog is set synchronously before openCatalog's
        // Task even starts running, so this is observable immediately
        // without awaiting anything.
        let model = SampleBuilderModel()
        model.openCatalog(at: "/nonexistent/\(UUID().uuidString).sqlite")
        XCTAssertTrue(model.isOpeningCatalog)

        let view = CatalogPickerView(model: model)
        _ = view.body
    }

    func test_givenErrorMessage_whenBuildingCatalogPickerView_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel()
        model.reportPickerFailure(NSError(domain: "test", code: 1))

        let view = CatalogPickerView(model: model)
        _ = view.body
    }

    func test_givenSuccessfulPick_whenHandlingFileImporterResult_thenModelStartsOpening() {
        let model = SampleBuilderModel()
        let view = CatalogPickerView(model: model)

        view.handleFileImporterResult(.success(URL(fileURLWithPath: "/nonexistent/catalog.cat.db")))

        // Real assertion, not just "didn't crash": the model actually
        // received the call and started its (doomed, since the path is
        // fake) open attempt.
        XCTAssertTrue(model.isOpeningCatalog)
    }

    func test_givenFailedPick_whenHandlingFileImporterResult_thenModelReportsError() {
        let model = SampleBuilderModel()
        let view = CatalogPickerView(model: model)

        view.handleFileImporterResult(.failure(NSError(domain: "test", code: 1)))

        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - SampleBuilderView

    func test_givenDefaultState_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        let view = SampleBuilderView(model: SampleBuilderModel())
        _ = view.body
    }

    func test_givenRatingEnabled_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel()
        model.ratingEnabled = true
        let view = SampleBuilderView(model: model)
        _ = view.body
    }

    func test_givenCategoryEnabledWithNoProps_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel()
        model.categoryEnabled = true
        let view = SampleBuilderView(model: model)
        _ = view.body
    }

    func test_givenCategoryEnabledWithPropsSelected_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel()
        model.injectCatalogForTesting(
            FakeCatalogForViewTests(),
            propTree: [CatalogPropNode(guid: "g1", name: "Vacation", children: [])]
        )
        model.categoryEnabled = true
        model.selectedCategoryGUIDs = ["g1"]

        let view = SampleBuilderView(model: model)
        _ = view.body
    }

    func test_givenNestedCategoryTree_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        // A non-trivial tree (a category with children) so the outline
        // view's disclosure-triangle/children rendering path gets
        // exercised too, not just the flat-leaf case above.
        let model = SampleBuilderModel()
        model.injectCatalogForTesting(
            FakeCatalogForViewTests(),
            propTree: [
                CatalogPropNode(
                    guid: "cat-nature",
                    name: "Nature",
                    children: [CatalogPropNode(guid: "prop-pines", name: "Pines", children: [])]
                )
            ]
        )
        model.categoryEnabled = true

        let view = SampleBuilderView(model: model)
        _ = view.body
    }

    func test_givenCountingMatches_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() {
        // isCountingMatches is set synchronously at the start of
        // refreshMatchingCount(), before the query itself runs, so this
        // is observable without awaiting anything -- same technique as
        // the CatalogPickerView "opening in progress" test above.
        let model = SampleBuilderModel()
        model.injectCatalogForTesting(FakeCatalogForViewTests(matchDelayNanoseconds: 50_000_000))
        model.refreshMatchingCount()
        XCTAssertTrue(model.isCountingMatches)

        let view = SampleBuilderView(model: model)
        _ = view.body
    }

    func test_givenMatchCountAndError_whenBuildingSampleBuilderView_thenBodyDoesNotCrash() async {
        let model = SampleBuilderModel()
        model.injectCatalogForTesting(FakeCatalogForViewTests())
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()
        model.reportPickerFailure(NSError(domain: "test", code: 1))

        let view = SampleBuilderView(model: model)
        _ = view.body
    }

    // MARK: - ScriptPreviewView

    func test_givenGeneratedScript_whenBuildingScriptPreviewView_thenBodyDoesNotCrash() {
        let view = ScriptPreviewView(model: SampleBuilderModel())
        _ = view.body
    }

    func test_givenText_whenCopyingToClipboard_thenClipboardReceivesIt() {
        // A fake, never the real NSPasteboard.general -- see
        // ClipboardWriting's doc comment. An earlier version of this
        // test wrote to the real system clipboard, which leaked a test
        // marker string into it outside the test run entirely.
        let clipboard = FakeClipboard()
        let view = ScriptPreviewView(model: SampleBuilderModel(), clipboard: clipboard)
        let text = "SELECT GUID FROM idCatalogItem;"

        view.copyToClipboard(text)

        XCTAssertEqual(clipboard.writtenText, text)
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

    func listPropTree() async throws -> [CatalogPropNode] { propTree }

    func matchingItemCount(for filter: SampleFilter) async throws -> Int {
        if matchDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: matchDelayNanoseconds)
        }
        return matchCount
    }
}
