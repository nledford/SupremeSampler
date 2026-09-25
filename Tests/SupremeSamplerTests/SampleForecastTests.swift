import XCTest

@testable import SupremeSampler

final class SampleForecastTests: XCTestCase {
    func test_givenMoreMatchesThanRequested_whenForecasting_thenTheSampleIsFull() {
        let forecast = SampleForecast(matching: 50_000, requested: 10_000)
        XCTAssertEqual(forecast.kind, .full)
        XCTAssertEqual(forecast.expectedSize, 10_000)
    }

    func test_givenExactlyAsManyMatchesAsRequested_whenForecasting_thenTheSampleIsFull() {
        XCTAssertEqual(SampleForecast(matching: 100, requested: 100).kind, .full)
    }

    func test_givenFewerMatchesThanRequested_whenForecasting_thenTheSampleIsShortAndTakesThemAll() {
        let forecast = SampleForecast(matching: 2, requested: 10_000)
        XCTAssertEqual(forecast.kind, .short)
        XCTAssertEqual(forecast.expectedSize, 2)
    }

    func test_givenNoMatches_whenForecasting_thenTheSampleIsEmpty() {
        let forecast = SampleForecast(matching: 0, requested: 10_000)
        XCTAssertEqual(forecast.kind, .empty)
        XCTAssertEqual(forecast.expectedSize, 0)
    }
}

/// "Sample All N": the one-click answer to a sample that would come up
/// short.
@MainActor
final class UseAllMatchesTests: XCTestCase {
    private struct StubCatalog: SampleBuilderCatalog {
        var count = 7
        func listPropTree() async throws -> [CatalogPropNode] { [] }
        func matchingItemCount(for filter: SampleFilter) async throws -> Int { count }
        func folderPhotoCounts(for filter: SampleFilter) async throws -> [FolderPhotoCount] { [] }
    }

    func test_givenFewerMatchesThanRequested_whenUsingAllMatches_thenTheSampleSizeBecomesTheCount() async {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(StubCatalog(count: 2))
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()
        XCTAssertEqual(model.sampleForecast?.kind, .short)

        model.useAllMatches()

        XCTAssertEqual(model.sampleSize, 2)
        XCTAssertEqual(model.sampleForecast?.kind, .full)
    }

    func test_givenANewerCountRunning_whenUsingAllMatches_thenTheOldCountIsNotUsed() async {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(StubCatalog(count: 2))
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()
        model.refreshMatchingCount()
        XCTAssertTrue(model.isCountingMatches)

        model.useAllMatches()

        XCTAssertEqual(model.sampleSize, 10_000)
    }

    func test_givenNoMatches_whenUsingAllMatches_thenTheSampleSizeIsLeftAlone() async {
        let model = SampleBuilderModel.forTesting()
        model.injectCatalogForTesting(StubCatalog(count: 0))
        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()

        model.useAllMatches()

        XCTAssertEqual(model.sampleSize, 10_000)
        XCTAssertEqual(model.sampleForecast?.kind, .empty)
    }
}

/// The dividers in the rule pickers' menus must neither drop nor repeat
/// an option: a missing one could never be picked again.
final class MenuSectionsTests: XCTestCase {
    private func assertCoversEveryCaseOnce<T: CaseIterable & Hashable>(_ sections: [[T]], file: StaticString = #filePath, line: UInt = #line) {
        let flat = sections.flatMap { $0 }
        XCTAssertEqual(flat.count, T.allCases.count, "an option is missing or repeated", file: file, line: line)
        XCTAssertEqual(Set(flat), Set(T.allCases), file: file, line: line)
        XCTAssertFalse(sections.contains { $0.isEmpty }, "an empty section draws two dividers in a row", file: file, line: line)
    }

    func test_givenEachSectionedPicker_whenListingItsMenu_thenEveryOptionAppearsExactlyOnce() {
        assertCoversEveryCaseOnce(RuleField.menuSections)
        assertCoversEveryCaseOnce(KeywordOperator.menuSections)
        assertCoversEveryCaseOnce(PathOperator.menuSections)
    }

    func test_givenTheKeywordMenu_whenSectioned_thenNoRunIsLongerThanThree() {
        XCTAssertLessThanOrEqual(KeywordOperator.menuSections.map(\.count).max() ?? 0, 3)
    }
}
