import AppKit
import SwiftUI
import XCTest

@testable import SupremeSampler

/// Behavior that depends on which views are actually on screen, so it's
/// checked with `ContentView` really rendered in a window (`HostedWindow`,
/// which explains why it must be on screen) rather than by evaluating
/// `.body` -- modifiers like `.onChange` only run while SwiftUI is
/// rendering.
@MainActor
final class WindowLayoutTests: XCTestCase {
    /// Counts match-count queries.
    private final class CountingCatalog: SampleBuilderCatalog, @unchecked Sendable {
        private(set) var matchCountQueries = 0

        func listPropTree() async throws -> [CatalogPropNode] { [] }

        func matchingItemCount(for filter: SampleFilter) async throws -> Int {
            await MainActor.run { matchCountQueries += 1 }
            return 7
        }

        func folderPhotoCounts(for filter: SampleFilter) async throws -> [FolderPhotoCount] { [] }
    }

    func test_givenTheScriptPaneHidden_whenARuleChanges_thenTheMatchCountStillRefreshes() async throws {
        let catalog = CountingCatalog()
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(catalog)
        let hosted = HostedWindow(
            ContentView(model: model, showsScript: .constant(false)), size: NSSize(width: 1300, height: 700))
        try await hosted.settle()
        let before = catalog.matchCountQueries

        model.rules.add(.rating)

        try await hosted.waitUntil { catalog.matchCountQueries > before }
        XCTAssertGreaterThan(catalog.matchCountQueries, before, "no count query after a rule change")
        await hosted.close()
    }

    func test_givenTheSidebarCollapsed_whenARuleChanges_thenTheMatchCountStillRefreshes() async throws {
        let catalog = CountingCatalog()
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(catalog)
        let hosted = HostedWindow(ContentView(model: model, columnVisibility: .detailOnly), size: NSSize(width: 1200, height: 700))
        try await hosted.settle()
        let before = catalog.matchCountQueries

        model.rules.add(.rating)

        try await hosted.waitUntil { catalog.matchCountQueries > before }
        XCTAssertGreaterThan(catalog.matchCountQueries, before, "no count query after a rule change")
        await hosted.close()
    }

    /// The whole window at its minimum width with the script shown, over
    /// a rule tree using every field and a nested group, then a rule
    /// added: it must lay out without AppKit's constraint-loop exception,
    /// which XCTest records as a failure of this test on its own (the
    /// real app crashed this way with the script as an `.inspector`).
    func test_givenTheMinimumWindowWidthAndEveryKindOfRule_whenShown_thenItLaysOutWithoutALayoutLoop() async throws {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(
            CountingCatalog(),
            propTree: CatalogPropNode.buildTree(
                categories: [(guid: "nature", name: "Nature")], props: [(guid: "trees", parentGUID: "nature", name: "Trees")]))
        for field in RuleField.allCases { model.rules.add(field) }
        model.rules.addGroup()
        if case .group(var nested) = model.rules.rules[model.rules.rules.count - 1].content {
            nested.match = .none
            nested.add(.keyword)
            nested.add(.path)
            model.rules.rules[model.rules.rules.count - 1].content = .group(nested)
        }

        let hosted = HostedWindow(
            ContentView(model: model, showsScript: .constant(true)), size: NSSize(width: ContentView.minimumWidth, height: 600))
        try await hosted.settle(for: .seconds(1))
        // Adding a rule with the script showing is what crashed the app
        // when the script was an `.inspector`.
        model.rules.add(.rating)
        model.rules.addGroup()
        try await hosted.settle(for: .seconds(1))

        // The window can't be narrower than its panes' minimums, so the
        // rules pane really had its minimum or more (widths it's measured
        // against in `RuleRowWidthTests`).
        XCTAssertEqual(hosted.window.contentLayoutRect.width, ContentView.minimumWidth, accuracy: 1)
        await hosted.close()
    }

    /// ⌘S is registered by the window (`ContentView`), not the script
    /// pane, which can be hidden -- a hidden pane's views are gone. This
    /// checks the window's own action saves; that File > Save Script…
    /// reaches it with the pane hidden was checked by hand in the running
    /// app (2026-09-24), since `.focusedSceneValue` needs a real scene.
    func test_givenTheWindowsSaveAction_whenSaving_thenTheScriptIsSavedThroughItsChooser() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".psc")
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(CountingCatalog())
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()
        let chooser = FakeDestinationChooser(answer: destination)
        let view = ContentView(model: model, showsScript: .constant(false), destinationChooser: chooser)

        XCTAssertTrue(view.saveScriptAction.isEnabled)
        await view.saveScript()

        XCTAssertEqual(chooser.askedDirectory, PSCFile.preferredDirectory())
        XCTAssertEqual(model.lastSavedScriptURL, destination)
    }

    func test_givenACatalogOpen_whenBuildingTheRulesPane_thenBodyDoesNotCrash() {
        let model = SampleBuilderModel.forTesting()
        model.rules.add(.keyword)
        _ = RuleBuilderView(model: model).body
    }
}
