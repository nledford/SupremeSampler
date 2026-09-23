import XCTest

@testable import SupremeSampler

/// Specifies editing a filter in the rule builder: adding, removing, and
/// changing rules and nested groups, and how the edited rules turn into
/// the domain `SampleFilter` the live count and generated script use.
/// Pure value manipulation -- no views, no catalog.
final class RuleGroupDraftTests: XCTestCase {
    /// Nature -> Pines -> Tall Pines.
    private let tree = CatalogPropNode.buildTree(
        categories: [(guid: "cat-nature", name: "Nature")],
        props: [
            (guid: "prop-pines", parentGUID: "cat-nature", name: "Pines"),
            (guid: "prop-tall-pines", parentGUID: "prop-pines", name: "Tall Pines"),
        ]
    )

    private func filter(_ draft: RuleGroupDraft) -> SampleFilter {
        SampleFilter(root: draft.domainGroup(resolvingCategoriesIn: tree))
    }

    // MARK: - Starting point

    func test_givenANewRuleBuilder_whenNothingIsAdded_thenTheFilterMatchesTheWholeCatalog() {
        XCTAssertEqual(filter(RuleGroupDraft()), SampleFilter())
    }

    // MARK: - Adding rules

    func test_givenAnEmptyGroup_whenAddingARatingRule_thenItDefaultsToAtLeastThreeStars() {
        var draft = RuleGroupDraft()

        draft.add(.rating)

        XCTAssertEqual(filter(draft), SampleFilter(rating: .atLeast(3)))
    }

    func test_givenAnEmptyGroup_whenAddingACategoryRule_thenItMatchesAnyOfNothingUntilCategoriesArePicked() {
        var draft = RuleGroupDraft()

        draft.add(.category)

        XCTAssertEqual(filter(draft), SampleFilter(category: CategoryFilter(branches: [], mode: .any)))
    }

    func test_givenAGroup_whenAddingRules_thenTheyAppearInTheOrderAdded() {
        var draft = RuleGroupDraft()

        draft.add(.category)
        draft.add(.rating)

        XCTAssertEqual(
            filter(draft).root.rules,
            [.category(CategoryFilter(branches: [], mode: .any)), .rating(.atLeast(3))])
    }

    func test_givenAGroup_whenAddingANestedGroup_thenItStartsAsAnEmptyAllOfGroup() {
        var draft = RuleGroupDraft()

        draft.add(.group)

        XCTAssertEqual(filter(draft).root.rules, [.group(RuleGroup(match: .all, rules: []))])
    }

    func test_givenAGroup_whenAddingSeveralRules_thenEachHasItsOwnStableIdentity() {
        // SwiftUI lists key rows by `id`; adding a rule must not change
        // an existing rule's id, or its row would be torn down and rebuilt.
        var draft = RuleGroupDraft()
        draft.add(.rating)
        let firstID = draft.rules[0].id

        draft.add(.rating)
        draft.add(.group)

        XCTAssertEqual(draft.rules[0].id, firstID)
        XCTAssertEqual(Set(draft.rules.map(\.id)).count, 3)
    }

    // MARK: - Editing rules

    func test_givenARatingRule_whenChangingItsComparisonAndValue_thenTheFilterFollows() {
        var draft = RuleGroupDraft()
        draft.add(.rating)

        draft.rules[0].content = .rating(RatingRuleDraft(comparison: .exactly, value: 5))

        XCTAssertEqual(filter(draft), SampleFilter(rating: .exactly(5)))
    }

    func test_givenACategoryRule_whenPickingAParent_thenItsSubcategoriesAreIncluded() {
        var draft = RuleGroupDraft()
        draft.add(.category)

        draft.rules[0].content = .category(CategoryRuleDraft(mode: .none, selectedGUIDs: ["prop-pines"]))

        let pines = CategoryBranch(rootGUID: "prop-pines", propGUIDs: ["prop-pines", "prop-tall-pines"])
        XCTAssertEqual(filter(draft), SampleFilter(category: CategoryFilter(branches: [pines], mode: .none)))
    }

    func test_givenAGroup_whenChangingItsMatchToNoneOf_thenItsRulesBecomeExclusions() {
        var draft = RuleGroupDraft()
        draft.add(.rating)

        draft.match = .none

        XCTAssertEqual(filter(draft).root, RuleGroup(match: .none, rules: [.rating(.atLeast(3))]))
    }

    // MARK: - Nesting

    func test_givenANestedGroup_whenAddingARuleInsideIt_thenTheFilterNestsIt() {
        // "3+ stars, but none of [Pines]": the exclude pattern.
        var draft = RuleGroupDraft()
        draft.add(.rating)
        draft.add(.group)
        guard case .group(var nested) = draft.rules[1].content else { return XCTFail("expected a group") }
        nested.match = .none
        nested.add(.category)
        nested.rules[0].content = .category(CategoryRuleDraft(mode: .any, selectedGUIDs: ["prop-tall-pines"]))
        draft.rules[1].content = .group(nested)

        let tallPines = CategoryBranch(rootGUID: "prop-tall-pines", propGUIDs: ["prop-tall-pines"])
        XCTAssertEqual(
            filter(draft).root,
            RuleGroup(
                match: .all,
                rules: [
                    .rating(.atLeast(3)),
                    .group(RuleGroup(match: .none, rules: [.category(CategoryFilter(branches: [tallPines], mode: .any))])),
                ]))
    }

    // MARK: - Removing rules

    func test_givenSeveralRules_whenRemovingOne_thenOnlyThatRuleIsGone() {
        var draft = RuleGroupDraft()
        draft.add(.rating)
        draft.add(.category)
        let ratingID = draft.rules[0].id

        draft.removeRule(id: ratingID)

        XCTAssertEqual(filter(draft).root.rules, [.category(CategoryFilter(branches: [], mode: .any))])
    }

    func test_givenAnUnknownRuleID_whenRemoving_thenNothingChanges() {
        var draft = RuleGroupDraft()
        draft.add(.rating)
        let before = draft

        draft.removeRule(id: UUID())

        XCTAssertEqual(draft, before)
    }
}
