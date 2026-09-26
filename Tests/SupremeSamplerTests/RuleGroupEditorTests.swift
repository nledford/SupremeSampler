import SwiftUI
import XCTest

@testable import SupremeSampler

/// The group header's "+" appends *inside its own group* -- the contract
/// that makes a nested group's header behave differently from its
/// parent's. Driven through `RuleGroupEditor.addToGroup`, the same seam
/// `actions(for:)` exposes for a row's "+", because there's no way to
/// click a real button from XCTest (see `ViewRenderingTests`).
@MainActor
final class RuleGroupEditorTests: XCTestCase {
    /// Holds a draft so a `Binding` can write back to it. A `final class`
    /// (a reference type, like a JS/Python object) rather than a `var`:
    /// `Binding(get:set:)`'s closures escape, and Swift won't let an
    /// escaping closure capture an `inout` parameter.
    private final class DraftBox {
        var draft: RuleGroupDraft
        init(_ draft: RuleGroupDraft) { self.draft = draft }
    }

    /// An editor over a real, mutable draft, at `depth` (0 is the root).
    private func editor(for box: DraftBox, depth: Int = 0) -> RuleGroupEditor {
        RuleGroupEditor(
            group: Binding(get: { box.draft }, set: { box.draft = $0 }),
            propTree: [],
            depth: depth,
            onRemove: nil)
    }

    private func ratingRule() -> RuleDraft { RuleDraft(.rating(RatingRuleDraft())) }
    private func pathRule() -> RuleDraft { RuleDraft(.path(PathRuleDraft())) }

    func test_givenAGroupWhoseLastRuleIsRating_whenTheHeaderAddsARule_thenItAppendsARatingRule() {
        let box = DraftBox(RuleGroupDraft(rules: [ratingRule()]))

        editor(for: box).addToGroup(.rule)

        XCTAssertEqual(box.draft.rules.count, 2)
        XCTAssertEqual(box.draft.rules.last?.field, .rating)
    }

    /// The header's "+" repeats the group's last *plain* rule, skipping
    /// nested groups -- a nested group has no field to repeat.
    func test_givenAGroupWhoseLastRuleIsANestedGroup_whenTheHeaderAddsARule_thenItRepeatsTheLastPlainRulesField() {
        let box = DraftBox(
            RuleGroupDraft(rules: [pathRule(), RuleDraft(.group(RuleGroupDraft()))]))

        editor(for: box).addToGroup(.rule)

        XCTAssertEqual(box.draft.rules.count, 3)
        XCTAssertEqual(box.draft.rules.last?.field, .path)
    }

    func test_givenAnEmptyGroup_whenTheHeaderAddsARule_thenItAddsARatingRule() {
        let box = DraftBox(RuleGroupDraft())

        editor(for: box).addToGroup(.rule)

        XCTAssertEqual(box.draft.rules.map(\.field), [.rating])
    }

    func test_givenAGroup_whenTheHeaderAddsANestedGroup_thenItAppendsAnEmptyAllOfGroup() {
        let box = DraftBox(RuleGroupDraft(rules: [ratingRule()]))

        editor(for: box).addToGroup(.group)

        XCTAssertEqual(box.draft.rules.count, 2)
        guard case .group(let nested)? = box.draft.rules.last?.content else {
            return XCTFail("expected a nested group, got \(String(describing: box.draft.rules.last?.content))")
        }
        XCTAssertEqual(nested.match, .all)
        XCTAssertTrue(nested.rules.isEmpty)
    }

    /// The point of a nested group's own header: its "+" grows *it*, not
    /// the group around it.
    func test_givenANestedGroup_whenItsHeaderAddsARule_thenTheParentIsUntouched() {
        let box = DraftBox(
            RuleGroupDraft(rules: [RuleDraft(.group(RuleGroupDraft(rules: [ratingRule()])))]))
        let nestedEditor = RuleGroupEditor(
            group: Binding(
                get: {
                    guard case .group(let nested) = box.draft.rules[0].content else {
                        return RuleGroupDraft()
                    }
                    return nested
                },
                set: { box.draft.rules[0].content = .group($0) }),
            propTree: [],
            depth: 1,
            onRemove: nil)

        nestedEditor.addToGroup(.rule)

        XCTAssertEqual(box.draft.rules.count, 1, "the parent group gained a rule")
        guard case .group(let nested) = box.draft.rules[0].content else {
            return XCTFail("the nested group disappeared")
        }
        XCTAssertEqual(nested.rules.count, 2)
        // The count alone would also pass if the "+" appended the wrong
        // kind of row, so assert what it actually appended.
        XCTAssertEqual(nested.rules.last?.field, .rating)
    }
}
