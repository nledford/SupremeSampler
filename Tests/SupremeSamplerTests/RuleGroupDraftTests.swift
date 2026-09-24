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

    func test_givenAnEmptyGroup_whenAddingAKeywordRule_thenItMatchesAnyOfNothingUntilKeywordsArePicked() {
        var draft = RuleGroupDraft()

        draft.add(.keyword)

        XCTAssertEqual(filter(draft), SampleFilter(category: CategoryFilter(branches: [], mode: .any)))
    }

    func test_givenAGroup_whenAddingRules_thenTheyAppearInTheOrderAdded() {
        var draft = RuleGroupDraft()

        draft.add(.keyword)
        draft.add(.rating)

        XCTAssertEqual(
            filter(draft).root.rules,
            [.category(CategoryFilter(branches: [], mode: .any)), .rating(.atLeast(3))])
    }

    func test_givenAGroup_whenAddingANestedGroup_thenItStartsAsAnEmptyAllOfGroup() {
        var draft = RuleGroupDraft()

        draft.addGroup()

        XCTAssertEqual(filter(draft).root.rules, [.group(RuleGroup(match: .all, rules: []))])
    }

    func test_givenAGroup_whenAddingSeveralRules_thenEachHasItsOwnStableIdentity() {
        // SwiftUI lists key rows by `id`; adding a rule must not change
        // an existing rule's id, or its row would be torn down and rebuilt.
        var draft = RuleGroupDraft()
        draft.add(.rating)
        let firstID = draft.rules[0].id

        draft.add(.rating)
        draft.addGroup()

        XCTAssertEqual(draft.rules[0].id, firstID)
        XCTAssertEqual(Set(draft.rules.map(\.id)).count, 3)
    }

    func test_givenAnEmptyGroup_whenAddingAPathRule_thenItStartsAsContainsNothingWhichMatchesEverything() {
        var draft = RuleGroupDraft()

        draft.add(.path)

        XCTAssertEqual(filter(draft).root.rules, [.path(PathFilter(kind: .contains, text: ""))])
    }

    func test_givenAnEmptyGroup_whenAddingALabelRule_thenItMatchesAnyOfNothingUntilLabelsArePicked() {
        var draft = RuleGroupDraft()

        draft.add(.label)

        XCTAssertEqual(filter(draft).root.rules, [.label(LabelFilter(labels: [], mode: .any))])
    }

    func test_givenALabelRule_whenPickingLabels_thenTheFilterListsThemInStableOrder() {
        var draft = RuleGroupDraft()
        draft.add(.label)

        draft.rules[0].content = .label(LabelRuleDraft(mode: .none, selectedLabels: ["Red", "", "Select"]))

        XCTAssertEqual(filter(draft).root.rules, [.label(LabelFilter(labels: ["", "Red", "Select"], mode: .none))])
    }

    func test_givenAnEmptyGroup_whenAddingAFileTypeRule_thenItMatchesAnyOfNothingUntilTypesArePicked() {
        var draft = RuleGroupDraft()

        draft.add(.fileType)

        XCTAssertEqual(filter(draft).root.rules, [.fileType(FileTypeFilter(extensions: [], mode: .any))])
    }

    func test_givenAFileTypeRule_whenPickingTypes_thenTheFilterListsThemInStableOrder() {
        var draft = RuleGroupDraft()
        draft.add(.fileType)

        draft.rules[0].content = .fileType(FileTypeRuleDraft(mode: .none, selectedTypes: ["mkv", "gif"]))

        XCTAssertEqual(filter(draft).root.rules, [.fileType(FileTypeFilter(extensions: ["gif", "mkv"], mode: .none))])
    }

    func test_givenAnEmptyGroup_whenAddingABookmarkRule_thenItMatchesAnyOfNothingUntilBookmarksArePicked() {
        var draft = RuleGroupDraft()

        draft.add(.bookmark)

        XCTAssertEqual(filter(draft).root.rules, [.bookmark(BookmarkFilter(values: [], mode: .any))])
    }

    func test_givenABookmarkRule_whenPickingBookmarks_thenTheFilterListsThemInOrder() {
        var draft = RuleGroupDraft()
        draft.add(.bookmark)

        draft.rules[0].content = .bookmark(BookmarkRuleDraft(mode: .none, selectedValues: ["5", "2"]))

        XCTAssertEqual(filter(draft).root.rules, [.bookmark(BookmarkFilter(values: [2, 5], mode: .none))])
    }

    func test_givenAnEmptyGroup_whenAddingAPendingDeletionRule_thenItDefaultsToExcludingPendingPhotos() {
        // The likely use in a sampling tool: keep photos already marked
        // for deletion out of the sample.
        var draft = RuleGroupDraft()

        draft.add(.pendingDeletion)

        XCTAssertEqual(filter(draft).root.rules, [.pendingDeletion(false)])
    }

    func test_givenARatingRule_whenChoosingIsNot_thenTheFilterNegatesTheValue() {
        var draft = RuleGroupDraft()
        draft.add(.rating)

        draft.rules[0].content = .rating(RatingRuleDraft(comparison: .isNot, value: 5))

        XCTAssertEqual(filter(draft), SampleFilter(rating: .isNot(5)))
    }

    func test_givenAPathRule_whenChoosingANegatedOperator_thenTheFilterIsNegated() {
        var draft = RuleGroupDraft()
        draft.add(.path)

        draft.rules[0].content = .path(PathRuleDraft(operator: .doesNotStartWith, text: "/Volumes/Old/"))

        XCTAssertEqual(
            filter(draft).root.rules, [.path(PathFilter(kind: .startsWith, text: "/Volumes/Old/", negated: true))])
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
        draft.add(.keyword)

        draft.rules[0].content = .keyword(KeywordRuleDraft(operator: .isNoneOf, selectedGUIDs: ["prop-pines"]))

        let pines = CategoryBranch(rootGUID: "prop-pines", propGUIDs: ["prop-pines", "prop-tall-pines"])
        XCTAssertEqual(filter(draft), SampleFilter(category: CategoryFilter(branches: [pines], mode: .none)))
    }

    func test_givenAGroup_whenChangingItsMatchToNoneOf_thenItsRulesBecomeExclusions() {
        var draft = RuleGroupDraft()
        draft.add(.rating)

        draft.match = .none

        XCTAssertEqual(filter(draft).root, RuleGroup(match: .none, rules: [.rating(.atLeast(3))]))
    }

    func test_givenAPathRule_whenChangingItsKindAndText_thenTheFilterFollows() {
        var draft = RuleGroupDraft()
        draft.add(.path)

        draft.rules[0].content = .path(PathRuleDraft(operator: .startsWith, text: "/Volumes/Photos/"))

        XCTAssertEqual(filter(draft).root.rules, [.path(PathFilter(kind: .startsWith, text: "/Volumes/Photos/"))])
    }

    // MARK: - Nesting

    func test_givenANestedGroup_whenAddingARuleInsideIt_thenTheFilterNestsIt() {
        // "3+ stars, but none of [Pines]": the exclude pattern.
        var draft = RuleGroupDraft()
        draft.add(.rating)
        draft.addGroup()
        guard case .group(var nested) = draft.rules[1].content else { return XCTFail("expected a group") }
        nested.match = .none
        nested.add(.keyword)
        nested.rules[0].content = .keyword(KeywordRuleDraft(operator: .isAnyOf, selectedGUIDs: ["prop-tall-pines"]))
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
        draft.add(.keyword)
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

    // MARK: - Keyword rules: picked keywords or path text

    func test_givenAKeywordRuleWithKeywordsPicked_whenSwitchingToAPathOperatorAndBack_thenThePicksAreKept() {
        var draft = RuleGroupDraft()
        draft.add(.keyword)
        draft.rules[0].content = .keyword(KeywordRuleDraft(operator: .isAnyOf, selectedGUIDs: ["prop-pines"]))

        draft.rules[0].content = .keyword(KeywordRuleDraft(operator: .contains, selectedGUIDs: ["prop-pines"], text: "leg"))
        XCTAssertEqual(filter(draft).root.rules, [.keywordPath(KeywordPathFilter(kind: .contains, text: "leg"))])

        draft.rules[0].content = .keyword(KeywordRuleDraft(operator: .isAnyOf, selectedGUIDs: ["prop-pines"], text: "leg"))
        let pines = CategoryBranch(rootGUID: "prop-pines", propGUIDs: ["prop-pines", "prop-tall-pines"])
        XCTAssertEqual(filter(draft).root.rules, [.category(CategoryFilter(branches: [pines], mode: .any))])
    }

    func test_givenEachKeywordPathOperator_whenConverting_thenItsKindAndNegationFollow() {
        let expected: [(KeywordOperator, KeywordPathMatchKind, Bool)] = [
            (.contains, .contains, false), (.doesNotContain, .contains, true),
            (.hasPart, .hasPart, false), (.hasNoPart, .hasPart, true),
            (.startsWith, .startsWith, false), (.doesNotStartWith, .startsWith, true),
            (.endsWith, .endsWith, false), (.doesNotEndWith, .endsWith, true),
        ]
        for (keywordOperator, kind, negated) in expected {
            var draft = RuleGroupDraft()
            draft.add(.keyword)
            draft.rules[0].content = .keyword(KeywordRuleDraft(operator: keywordOperator, text: "Trees"))

            XCTAssertEqual(
                filter(draft).root.rules, [.keywordPath(KeywordPathFilter(kind: kind, text: "Trees", negated: negated))],
                "\(keywordOperator)")
        }
    }

    func test_givenEachPickedKeywordsOperator_whenConverting_thenItsModeFollows() {
        let expected: [(KeywordOperator, CategoryMatchMode)] = [(.isAnyOf, .any), (.isAllOf, .all), (.isNoneOf, .none)]
        for (keywordOperator, mode) in expected {
            var draft = RuleGroupDraft()
            draft.add(.keyword)
            draft.rules[0].content = .keyword(KeywordRuleDraft(operator: keywordOperator, text: "ignored"))

            XCTAssertEqual(filter(draft).root.rules, [.category(CategoryFilter(branches: [], mode: mode))])
        }
    }

    // MARK: - Changing a rule's field

    func test_givenARatingRow_whenItsFieldIsChangedToKeyword_thenItKeepsItsPlaceAndIdentityAsAnyOfNothing() {
        var draft = RuleGroupDraft()
        draft.add(.path)
        draft.add(.rating)
        draft.add(.path)
        let ratingID = draft.rules[1].id

        draft.changeField(ofRule: ratingID, to: .keyword)

        XCTAssertEqual(draft.rules[1].id, ratingID)
        XCTAssertEqual(draft.rules[1].field, .keyword)
        XCTAssertEqual(filter(draft).root.rules[1], .category(CategoryFilter(branches: [], mode: .any)))
    }

    func test_givenARow_whenItsFieldIsChangedToTheSameField_thenItsSettingsAreKept() {
        var draft = RuleGroupDraft()
        draft.add(.rating)
        draft.rules[0].content = .rating(RatingRuleDraft(comparison: .exactly, value: 5))
        let before = draft

        draft.changeField(ofRule: draft.rules[0].id, to: .rating)

        XCTAssertEqual(draft, before)
    }

    func test_givenANestedGroupOrAnUnknownRow_whenChangingAField_thenNothingChanges() {
        var draft = RuleGroupDraft()
        draft.addGroup()
        let before = draft

        draft.changeField(ofRule: draft.rules[0].id, to: .rating)
        draft.changeField(ofRule: UUID(), to: .rating)

        XCTAssertEqual(draft, before)
    }

    func test_givenEachField_whenAdded_thenTheRowReportsThatField() {
        for field in RuleField.allCases {
            var draft = RuleGroupDraft()
            draft.add(field)
            XCTAssertEqual(draft.rules[0].field, field)
        }
        var draft = RuleGroupDraft()
        draft.addGroup()
        XCTAssertNil(draft.rules[0].field)
    }

    // MARK: - Inserting after a row (the row's "+")

    func test_givenThreeRows_whenInsertingAfterTheSecond_thenTheNewRuleIsThird() {
        var draft = RuleGroupDraft()
        draft.add(.rating)
        draft.add(.path)
        draft.add(.rating)
        let ids = draft.rules.map(\.id)

        draft.insertRule(.path, after: ids[1])

        XCTAssertEqual(draft.rules.count, 4)
        XCTAssertEqual(draft.rules[2].field, .path)
        XCTAssertEqual([draft.rules[0].id, draft.rules[1].id, draft.rules[3].id], ids)
    }

    func test_givenThreeRows_whenInsertingANestedGroupAfterTheSecond_thenAnEmptyAllOfGroupIsThird() {
        var draft = RuleGroupDraft()
        draft.add(.rating)
        draft.add(.rating)
        draft.add(.rating)

        draft.insertGroup(after: draft.rules[1].id)

        guard case .group(let group) = draft.rules[2].content else { return XCTFail("expected a group third") }
        XCTAssertEqual(group.match, .all)
        XCTAssertEqual(group.rules, [])
    }

    func test_givenAnUnknownRow_whenInserting_thenNothingChanges() {
        var draft = RuleGroupDraft()
        draft.add(.rating)
        let before = draft

        draft.insertRule(.path, after: UUID())
        draft.insertGroup(after: UUID())

        XCTAssertEqual(draft, before)
    }

    // MARK: - The group header's "+"

    func test_givenAnEmptyGroup_whenAskingWhatANewRuleTests_thenItIsRating() {
        XCTAssertEqual(RuleGroupDraft().fieldForNewRule, .rating)
    }

    func test_givenAGroupEndingInAKeywordRule_whenAskingWhatANewRuleTests_thenItIsKeyword() {
        var draft = RuleGroupDraft()
        draft.add(.path)
        draft.addGroup()
        draft.add(.keyword)

        XCTAssertEqual(draft.fieldForNewRule, .keyword)
    }

    func test_givenAGroupEndingInANestedGroup_whenAskingWhatANewRuleTests_thenTheLastRuleDecides() {
        var draft = RuleGroupDraft()
        draft.add(.path)
        draft.addGroup()

        XCTAssertEqual(draft.fieldForNewRule, .path)
    }

    func test_givenAKeywordRule_whenAskingForItsPathFilter_thenOnlyPathOperatorsHaveOne() {
        XCTAssertNil(KeywordRuleDraft(operator: .isAllOf, text: "Pines").keywordPathFilter)
        XCTAssertEqual(
            KeywordRuleDraft(operator: .hasNoPart, text: "Pines").keywordPathFilter,
            KeywordPathFilter(kind: .hasPart, text: "Pines", negated: true))
    }
}
