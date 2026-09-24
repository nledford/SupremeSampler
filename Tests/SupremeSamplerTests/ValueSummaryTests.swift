import XCTest

@testable import SupremeSampler

/// What a rule row's value button says about its current picks, so a
/// one-line row still shows what the rule tests.
final class ValueSummaryTests: XCTestCase {
    func test_givenNothingPicked_whenSummarizing_thenThePlaceholderShows() {
        XCTAssertEqual(ValueSummary.text(for: [], placeholder: "Choose…"), "Choose…")
    }

    func test_givenOneOrTwoPicks_whenSummarizing_thenEachIsNamed() {
        XCTAssertEqual(ValueSummary.text(for: ["Trees"], placeholder: "Choose…"), "Trees")
        XCTAssertEqual(ValueSummary.text(for: ["Trees", "Rivers"], placeholder: "Choose…"), "Trees, Rivers")
    }

    func test_givenMoreThanTwoPicks_whenSummarizing_thenTheRestAreCounted() {
        XCTAssertEqual(ValueSummary.text(for: ["Trees", "Rivers", "Arm", "Pines"], placeholder: "Choose…"), "Trees, Rivers +2")
    }

    func test_givenPickedKeywords_whenNaming_thenTheyComeInTreeOrderByTheirOwnName() {
        let tree = CatalogPropNode.buildTree(
            categories: [(guid: "nature", name: "Nature")],
            props: [
                (guid: "trees", parentGUID: "nature", name: "Trees"),
                (guid: "arm", parentGUID: "nature", name: "Arm"),
            ])

        XCTAssertEqual(ValueSummary.keywordNames(for: ["trees", "arm", "gone"], in: tree), ["Arm", "Trees"])
    }

    func test_givenCatalogValuesInEachState_whenSummarizing_thenTheStateOrThePicksShow() {
        let loaded = CatalogValues.loaded([ValueCount(value: "", count: 3), ValueCount(value: "Red", count: 1)])

        XCTAssertEqual(ValueSummary.text(for: .loading, picked: [], name: { $0 }), "Loading…")
        XCTAssertEqual(ValueSummary.text(for: .failed("boom"), picked: ["Red"], name: { $0 }), "Couldn't load")
        XCTAssertEqual(ValueSummary.text(for: loaded, picked: [], name: { $0 }), "Choose…")
        XCTAssertEqual(
            ValueSummary.text(for: loaded, picked: ["Red", ""], name: { $0.isEmpty ? "No label" : $0 }), "No label, Red")
    }
}
