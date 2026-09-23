import XCTest

@testable import SupremeSampler

/// Specifies the shape of a sample filter: a tree of rules, the same
/// model as a Lightroom Smart Collection -- a group says whether *all*,
/// *any*, or *none* of its rules must match, and a rule can itself be a
/// nested group. "None of" is how photos are excluded.
final class SampleFilterTests: XCTestCase {
    func test_givenNoRules_whenCreatingAFilter_thenItIsUnconstrained() {
        XCTAssertTrue(SampleFilter().isUnconstrained)
        XCTAssertEqual(SampleFilter().root, RuleGroup(match: .all, rules: []))
    }

    func test_givenRatingAndCategory_whenCreatingAFlatFilter_thenBothAreRulesOfAnAllOfGroup() {
        let category = CategoryFilter(propGUIDs: ["g1"], mode: .any)

        let filter = SampleFilter(rating: .atLeast(3), category: category)

        XCTAssertEqual(
            filter.root,
            RuleGroup(match: .all, rules: [.rating(.atLeast(3)), .category(category)]))
    }

    func test_givenOnlyACategory_whenCreatingAFlatFilter_thenTheRatingRuleIsOmitted() {
        let category = CategoryFilter(propGUIDs: ["g1"], mode: .none)

        XCTAssertEqual(SampleFilter(category: category).root.rules, [.category(category)])
    }

    func test_givenAnEmptyAnyOfGroup_whenAskingIfUnconstrained_thenItIsNot() {
        // "Any of no rules" matches nothing -- the opposite of
        // unconstrained, so it must still produce a WHERE clause.
        XCTAssertFalse(SampleFilter(root: RuleGroup(match: .any, rules: [])).isUnconstrained)
    }

    func test_givenAnAllOfGroupWithRules_whenAskingIfUnconstrained_thenItIsNot() {
        XCTAssertFalse(SampleFilter(rating: .exactly(5)).isUnconstrained)
    }
}
