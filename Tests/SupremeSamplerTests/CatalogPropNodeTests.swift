import XCTest

@testable import SupremeSampler

final class CatalogPropNodeTests: XCTestCase {
    func test_givenNoCategories_whenBuildingTree_thenReturnsEmpty() {
        let tree = CatalogPropNode.buildTree(categories: [], props: [])
        XCTAssertEqual(tree, [])
    }

    func test_givenCategoriesWithNoProps_whenBuildingTree_thenEachIsALeaf() {
        let tree = CatalogPropNode.buildTree(
            categories: [(guid: "cat-b", name: "Places"), (guid: "cat-a", name: "Nature")],
            props: []
        )

        // Sorted by name, not input order.
        XCTAssertEqual(tree.map(\.name), ["Nature", "Places"])
        XCTAssertEqual(tree.map(\.children), [[], []])
    }

    func test_givenOneLevelOfProps_whenBuildingTree_thenNestsUnderTheirCategory() {
        let tree = CatalogPropNode.buildTree(
            categories: [(guid: "cat-nature", name: "Nature")],
            props: [
                (guid: "prop-pines", parentGUID: "cat-nature", name: "Pines"),
                (guid: "prop-arms", parentGUID: "cat-nature", name: "Arms"),
            ]
        )

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "Nature")
        // Sorted by name.
        XCTAssertEqual(tree[0].children.map(\.name), ["Arms", "Pines"])
    }

    /// Mirrors the real catalog's actual shape (see AGENTS.md/this
    /// feature's design notes): Nature -> Pines -> Tall Pines is a real
    /// three-level chain in the live data, ported from a recursive SQL
    /// CTE in an earlier Rust tool into this pure Swift equivalent.
    func test_givenMultipleLevelsOfNesting_whenBuildingTree_thenNestsAllTheWayDown() {
        let tree = CatalogPropNode.buildTree(
            categories: [(guid: "cat-nature", name: "Nature")],
            props: [
                (guid: "prop-pines", parentGUID: "cat-nature", name: "Pines"),
                (guid: "prop-tall-pines", parentGUID: "prop-pines", name: "Tall Pines"),
                (guid: "prop-young-pines", parentGUID: "prop-pines", name: "Young Pines"),
            ]
        )

        let body = tree[0]
        XCTAssertEqual(body.children.map(\.name), ["Pines"])
        let pines = body.children[0]
        XCTAssertEqual(pines.children.map(\.name), ["Tall Pines", "Young Pines"])
        XCTAssertTrue(pines.children.allSatisfy(\.children.isEmpty))
    }

    func test_givenAPropWithNoMatchingParent_whenBuildingTree_thenItIsDroppedSilently() {
        // A prop whose ParentGUID doesn't match any category or other
        // prop GUID (orphaned data) shouldn't crash or appear at the top
        // level unexpectedly -- it just never gets attached anywhere,
        // the same way the recursive SQL CTE this was ported from would
        // never surface a row whose parent chain doesn't reach a root.
        let tree = CatalogPropNode.buildTree(
            categories: [(guid: "cat-nature", name: "Nature")],
            props: [(guid: "prop-orphan", parentGUID: "does-not-exist", name: "Orphan")]
        )

        XCTAssertEqual(tree[0].children, [])
    }

    func test_givenChildrenOrNil_whenNodeHasNoChildren_thenReturnsNilNotEmptyArray() {
        // SwiftUI's List(_:children:) uses nil vs. non-nil (not
        // empty-vs-nonempty) to decide whether a row gets a disclosure
        // triangle at all -- a leaf node must return nil here, or every
        // leaf would render with an always-empty, uselessly clickable
        // expand arrow.
        let leaf = CatalogPropNode(guid: "g", name: "Leaf", children: [])
        XCTAssertNil(leaf.childrenOrNil)

        let parent = CatalogPropNode(guid: "g2", name: "Parent", children: [leaf])
        XCTAssertEqual(parent.childrenOrNil, [leaf])
    }

    /// A prop whose GUID is also a category's, parented under that same
    /// category, is its own child. Unguarded, building the tree recursed
    /// forever. The cap is the one `KeywordPathFilter.keywordPathsCTE`
    /// uses, so the tree and a generated script see the same paths.
    func test_givenAPropThatIsItsOwnAncestor_whenBuildingTree_thenNestingStopsAtTheDepthCap() {
        let tree = CatalogPropNode.buildTree(
            categories: [(guid: "loop", name: "Cat")],
            props: [(guid: "loop", parentGUID: "loop", name: "Loop")]
        )

        func deepest(_ node: CatalogPropNode) -> Int {
            node.children.map { 1 + deepest($0) }.max() ?? 0
        }
        XCTAssertEqual(tree.map(deepest), [CatalogPropNode.maxDepth])
    }
}
