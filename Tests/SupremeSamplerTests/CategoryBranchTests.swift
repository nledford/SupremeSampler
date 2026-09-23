import XCTest

@testable import SupremeSampler

/// Specifies what "selecting a category" means in the rule builder:
/// picking a node in the category tree selects that node *and everything
/// beneath it* (a branch), the same way Lightroom's keyword rule treats
/// a parent keyword. Pure domain logic -- no database involved.
///
/// Why this matters on the real catalog (checked 2026-09-23): no photo
/// is ever assigned a top-level category directly (0 rows), and parent
/// keywords are rarely assigned themselves (e.g. "Trees" has 15
/// children and 0 direct assignments). Matching only the selected GUID
/// made selecting a parent count nothing.
final class CategoryBranchTests: XCTestCase {
    /// Nature -> Pines -> {Tall Pines, Young Pines}, plus Nature -> Arms, and a
    /// second category, Places -> Lake. Mirrors the real catalog's
    /// shape (a three-level chain under Nature).
    private let tree = CatalogPropNode.buildTree(
        categories: [(guid: "cat-nature", name: "Nature"), (guid: "cat-places", name: "Places")],
        props: [
            (guid: "prop-pines", parentGUID: "cat-nature", name: "Pines"),
            (guid: "prop-tall-pines", parentGUID: "prop-pines", name: "Tall Pines"),
            (guid: "prop-young-pines", parentGUID: "prop-pines", name: "Young Pines"),
            (guid: "prop-arms", parentGUID: "cat-nature", name: "Arms"),
            (guid: "prop-lake", parentGUID: "cat-places", name: "Lake"),
        ]
    )

    func test_givenALeafKeywordSelected_whenResolvingBranches_thenTheBranchIsJustThatKeyword() {
        let branches = CategoryBranch.resolve(selectedGUIDs: ["prop-arms"], in: tree)

        XCTAssertEqual(branches, [CategoryBranch(rootGUID: "prop-arms", propGUIDs: ["prop-arms"])])
    }

    func test_givenAParentKeywordSelected_whenResolvingBranches_thenTheBranchIncludesEveryDescendant() {
        let branches = CategoryBranch.resolve(selectedGUIDs: ["prop-pines"], in: tree)

        XCTAssertEqual(
            branches,
            [
                CategoryBranch(
                    rootGUID: "prop-pines",
                    propGUIDs: ["prop-pines", "prop-tall-pines", "prop-young-pines"])
            ])
    }

    func test_givenATopLevelCategorySelected_whenResolvingBranches_thenTheBranchIncludesEveryKeywordAtEveryDepth() {
        let branches = CategoryBranch.resolve(selectedGUIDs: ["cat-nature"], in: tree)

        XCTAssertEqual(branches.count, 1)
        XCTAssertEqual(
            branches[0].propGUIDs,
            ["cat-nature", "prop-arms", "prop-pines", "prop-tall-pines", "prop-young-pines"])
    }

    func test_givenSeveralSelections_whenResolvingBranches_thenOneBranchPerSelectionInStableOrder() {
        // Selection comes from a `Set`, whose iteration order isn't
        // stable between runs. Branches (and each branch's GUIDs) are
        // sorted, so the same selection always yields the same filter,
        // and the same generated script text.
        let branches = CategoryBranch.resolve(selectedGUIDs: ["prop-lake", "prop-pines"], in: tree)

        XCTAssertEqual(branches.map(\.rootGUID), ["prop-lake", "prop-pines"])
    }

    func test_givenASelectedGUIDMissingFromTheTree_whenResolvingBranches_thenItIsKeptAsASingleKeywordBranch() {
        // E.g. a selection left over from a different catalog. Kept
        // rather than silently dropped: it simply matches nothing
        // (for "any"), which the live match count makes visible.
        let branches = CategoryBranch.resolve(selectedGUIDs: ["stale-guid"], in: tree)

        XCTAssertEqual(branches, [CategoryBranch(rootGUID: "stale-guid", propGUIDs: ["stale-guid"])])
    }

    func test_givenNothingSelected_whenResolvingBranches_thenThereAreNoBranches() {
        XCTAssertEqual(CategoryBranch.resolve(selectedGUIDs: [], in: tree), [])
    }

    // MARK: - CategoryFilter's derived view of its branches

    func test_givenOverlappingBranches_whenListingAllPropGUIDs_thenEachGUIDAppearsOnceSorted() {
        let filter = CategoryFilter(
            branches: CategoryBranch.resolve(selectedGUIDs: ["prop-pines", "prop-young-pines"], in: tree),
            mode: .any
        )

        XCTAssertEqual(filter.allPropGUIDs, ["prop-pines", "prop-tall-pines", "prop-young-pines"])
    }
}
