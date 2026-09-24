import AppKit
import SwiftUI
import XCTest

@testable import SupremeSampler

/// Every kind of rule has to fit the rules pane: on one line at the
/// width a new window gives it, and stacked (operator and value on a
/// second line) at the pane's minimum, three groups deep. Measured as
/// SwiftUI lays the views out (`NSHostingView.fittingSize`, the width a
/// view asks for), with each rule's widest operator and a long value.
@MainActor
final class RuleRowWidthTests: XCTestCase {
    private let tree = CatalogPropNode.buildTree(categories: [(guid: "b", name: "Nature")], props: [])

    /// Each field with its widest operator.
    private let widestRules: [RuleDraft.Content] = [
        .rating(RatingRuleDraft(comparison: .atLeast, value: 5)),
        .keyword(KeywordRuleDraft(operator: .isNoneOf, selectedGUIDs: ["b"])),
        .keyword(KeywordRuleDraft(operator: .doesNotStartWith, text: "Nature\\Trees\\Oak")),
        .path(PathRuleDraft(operator: .doesNotStartWith, text: "/Volumes/Photos/library/")),
        .label(LabelRuleDraft(mode: .none)),
        .fileType(FileTypeRuleDraft(mode: .none)),
        .bookmark(BookmarkRuleDraft(mode: .none)),
        .pendingDeletion(PendingDeletionRuleDraft()),
    ]

    private func width(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    private func row(_ content: RuleDraft.Content) -> RuleRow {
        RuleRow(rule: .constant(RuleDraft(content)), propTree: tree, depth: 0, actions: .none)
    }

    /// What surrounds a row `depth` groups down, inside the rules pane:
    /// the pane's padding and each group box's. Measured from a real
    /// nested tree around the narrowest rule, not added up by hand.
    private func surroundings(depth: Int) -> CGFloat {
        let leaf = RuleDraft.Content.pendingDeletion(PendingDeletionRuleDraft())
        var group = RuleGroupDraft(rules: [RuleDraft(leaf)])
        for _ in 0..<depth { group = RuleGroupDraft(rules: [RuleDraft(.group(group))]) }
        let pane = RuleGroupEditor(group: .constant(group), propTree: tree, depth: 0, onRemove: nil).padding()
        return width(pane) - width(row(leaf).line(field: .pendingDeletion, stacked: false))
    }

    func test_givenEveryKindOfRule_whenLaidOutOnOneLineAtTheTopLevel_thenItFitsANewWindowsRulesPane() {
        for content in widestRules {
            let field = RuleDraft(content).field!
            let needed = width(row(content).line(field: field, stacked: false)) + surroundings(depth: 0)
            XCTAssertLessThanOrEqual(needed, RuleBuilderView.comfortableWidth, "\(field) needs \(needed)")
        }
    }

    func test_givenEveryKindOfRule_whenStackedThreeGroupsDeep_thenItFitsTheNarrowestRulesPane() {
        for content in widestRules {
            let field = RuleDraft(content).field!
            let needed = width(row(content).line(field: field, stacked: true)) + surroundings(depth: 3)
            XCTAssertLessThanOrEqual(needed, RuleBuilderView.minimumWidth, "\(field) needs \(needed)")
        }
    }

    /// The measurement itself: nesting must cost something, or the
    /// checks above would pass for the wrong reason.
    func test_givenDeeperNesting_whenMeasuringSurroundings_thenEachGroupAddsWidth() {
        XCTAssertGreaterThan(surroundings(depth: 3), surroundings(depth: 0))
        XCTAssertGreaterThan(surroundings(depth: 0), 0)
    }
}
