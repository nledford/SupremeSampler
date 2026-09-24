import XCTest

@testable import SupremeSampler

final class KeywordPathTests: XCTestCase {
    /// Nature -> Trees -> Oak, plus a sibling category -- the shape of the
    /// real catalog's custom categories (depth 3 at most, 2026-09-24).
    private let tree = CatalogPropNode.buildTree(
        categories: [(guid: "cat-nature", name: "Nature"), (guid: "cat-places", name: "Places")],
        props: [
            (guid: "trees", parentGUID: "cat-nature", name: "Trees"),
            (guid: "oak", parentGUID: "trees", name: "Oak"),
            (guid: "beach", parentGUID: "cat-places", name: "Beach"),
        ]
    )

    func test_givenANestedKeyword_whenBuildingPaths_thenItsPathRunsFromTheRootCategoryJoinedByBackslashes() {
        let paths = KeywordPath.all(in: tree)

        XCTAssertEqual(paths.first { $0.guid == "oak" }?.text, "Nature\\Trees\\Oak")
    }

    func test_givenATree_whenBuildingPaths_thenEveryNodeIncludingRootCategoriesHasOnePath() {
        let paths = KeywordPath.all(in: tree)

        XCTAssertEqual(
            paths.map(\.text),
            ["Nature", "Nature\\Trees", "Nature\\Trees\\Oak", "Places", "Places\\Beach"]
        )
    }

    func test_givenNoCategories_whenBuildingPaths_thenThereAreNone() {
        XCTAssertEqual(KeywordPath.all(in: []), [])
    }

    func test_givenANestedKeyword_whenBuildingPaths_thenItKeepsItsOwnName() {
        XCTAssertEqual(KeywordPath.all(in: tree).first { $0.guid == "oak" }?.name, "Oak")
    }
}
