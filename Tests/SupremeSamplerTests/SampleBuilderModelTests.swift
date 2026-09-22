import XCTest

@testable import SupremeSampler

// `@MainActor` on the test class: SampleBuilderModel is itself
// @MainActor-isolated (required for anything SwiftUI reads), so any code
// touching it -- including test code -- has to run on the main actor
// too. XCTest runs test methods on the main thread by default, but the
// *type checker* still needs this annotation to allow synchronous
// access to a MainActor type from here.
@MainActor
final class SampleBuilderModelTests: XCTestCase {
    // The first block of tests only exercises `currentFilter`/
    // `generatedScript`, pure computed properties with no catalog
    // access. The async block further down exercises
    // `refreshMatchingCount` against a fake `SampleBuilderCatalog`
    // (see `FakeCatalog`) rather than a real SQLite file -- fixture-
    // backed integration against a real file is PhotoSupremeCatalogTests'
    // job; this file's job is the view-model's own state machine
    // (loading flags, error handling, stale-request cancellation).

    func test_givenNoFiltersEnabled_whenComputingCurrentFilter_thenFilterIsUnconstrained() {
        let model = SampleBuilderModel()
        XCTAssertEqual(model.currentFilter, SampleFilter())
    }

    func test_givenRatingEnabled_whenComputingCurrentFilter_thenIncludesRatingFilter() {
        let model = SampleBuilderModel()
        model.ratingEnabled = true
        model.ratingComparison = .atLeast
        model.ratingValue = 4

        XCTAssertEqual(model.currentFilter, SampleFilter(rating: .atLeast(4)))
    }

    func test_givenRatingToggledBackOff_whenComputingCurrentFilter_thenRatingIsNilAgain() {
        let model = SampleBuilderModel()
        model.ratingEnabled = true
        model.ratingValue = 4
        model.ratingEnabled = false

        XCTAssertNil(model.currentFilter.rating)
    }

    func test_givenCategoryEnabled_whenComputingCurrentFilter_thenIncludesCategoryFilter() {
        let model = SampleBuilderModel()
        model.categoryEnabled = true
        model.categoryMode = .all
        model.selectedCategoryGUIDs = ["g1", "g2"]

        let category = model.currentFilter.category
        XCTAssertEqual(category?.mode, .all)
        XCTAssertEqual(Set(category?.propGUIDs ?? []), ["g1", "g2"])
    }

    func test_givenBothFiltersEnabled_whenComputingCurrentFilter_thenIncludesBoth() {
        let model = SampleBuilderModel()
        model.ratingEnabled = true
        model.ratingComparison = .exactly
        model.ratingValue = 5
        model.categoryEnabled = true
        model.categoryMode = .any
        model.selectedCategoryGUIDs = ["g1"]

        let filter = model.currentFilter
        XCTAssertEqual(filter.rating, .exactly(5))
        XCTAssertEqual(filter.category, CategoryFilter(propGUIDs: ["g1"], mode: .any))
    }

    func test_givenSampleSizeAndFilter_whenGeneratingScript_thenReflectsCurrentState() {
        let model = SampleBuilderModel()
        model.sampleSize = 250
        model.ratingEnabled = true
        model.ratingComparison = .exactly
        model.ratingValue = 5

        let script = model.generatedScript

        XCTAssertTrue(script.contains("SAMPLE_SIZE = 250;"))
        XCTAssertTrue(script.contains("Rating = 5"))
    }

    // MARK: - Async catalog behavior (via a fake SampleBuilderCatalog)

    /// A controllable test double for `SampleBuilderCatalog` -- lets
    /// tests dictate exactly how long a call takes and what it returns,
    /// per call index, which is what makes the stale-request race below
    /// possible to test deterministically.
    ///
    /// `props`/`responses` are `let`, set once at construction, rather
    /// than mutable `var`s: that's what actually makes `@unchecked
    /// Sendable` a sound promise here, not just the `NSLock` around
    /// `callCount`. A test configuring them, then never touching them
    /// again, means there's no window for the concurrent
    /// `matchingItemCount` call (running on a background executor) to
    /// race a mutation from the main-actor test method -- the *only*
    /// mutable shared state is `callCount`, which the lock does cover.
    /// An earlier version left `props`/`responses` as `var`s next to
    /// that same lock, which was a real (if not-yet-triggered) gap: nothing
    /// stopped a future test from mutating them after the fake was
    /// already in use.
    private final class FakeCatalog: SampleBuilderCatalog, @unchecked Sendable {
        struct Response {
            var delayNanoseconds: UInt64 = 0
            var result: Result<Int, Error>
        }

        let props: [CatalogProp]
        /// Keyed by 1-based call index (the Nth call to
        /// `matchingItemCount` across this fake's lifetime), so a test
        /// can give the 1st call different behavior than the 2nd.
        let responses: [Int: Response]

        private let lock = NSLock()
        private var callCount = 0

        init(props: [CatalogProp] = [], responses: [Int: Response] = [:]) {
            self.props = props
            self.responses = responses
        }

        func listProps() async throws -> [CatalogProp] { props }

        func matchingItemCount(for filter: SampleFilter) async throws -> Int {
            lock.lock()
            callCount += 1
            let myCall = callCount
            lock.unlock()

            let response = responses[myCall] ?? Response(result: .success(0))
            if response.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: response.delayNanoseconds)
            }
            return try response.result.get()
        }
    }

    private struct FakeError: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    func test_givenInjectedCatalog_whenRefreshingMatchingCount_thenUpdatesCountAndClearsLoadingFlag() async {
        let fake = FakeCatalog(responses: [1: .init(result: .success(42))])
        let model = SampleBuilderModel()
        model.injectCatalogForTesting(fake)

        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()

        XCTAssertEqual(model.matchingCount, 42)
        XCTAssertFalse(model.isCountingMatches)
        XCTAssertNil(model.errorMessage)
    }

    func test_givenCatalogThrows_whenRefreshingMatchingCount_thenSetsErrorAndClearsCount() async {
        let fake = FakeCatalog(responses: [1: .init(result: .failure(FakeError()))])
        let model = SampleBuilderModel()
        model.injectCatalogForTesting(fake)

        model.refreshMatchingCount()
        await model.waitForPendingMatchCountForTesting()

        XCTAssertNil(model.matchingCount)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isCountingMatches)
    }

    /// The property that matters most about the async refactor: a fast
    /// request must win over a slower, now-stale one it superseded, not
    /// the other way around just because the slow one happens to finish
    /// later in wall-clock time. This is the exact bug class a naive
    /// `defer { isCountingMatches = false }` would reintroduce (see the
    /// comment in `refreshMatchingCount` explaining why there isn't one).
    func test_givenSlowerRequestSupersededByFaster_whenBothComplete_thenOnlyLatestResultWins() async throws {
        let fake = FakeCatalog(responses: [
            1: .init(delayNanoseconds: 100_000_000, result: .success(100)),  // slow, would-be-stale
            2: .init(delayNanoseconds: 0, result: .success(5)),  // fast, current
        ])
        let model = SampleBuilderModel()
        model.injectCatalogForTesting(fake)

        model.refreshMatchingCount()  // starts call #1 (slow)
        try await Task.sleep(nanoseconds: 20_000_000)  // let call #1 actually begin
        model.refreshMatchingCount()  // cancels call #1, starts call #2 (fast)
        await model.waitForPendingMatchCountForTesting()  // waits for call #2, the current task

        // If the cancellation/guard logic were broken, call #1's 100ms
        // delay would complete after this point and could still clobber
        // matchingCount -- wait past it to prove it doesn't.
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(model.matchingCount, 5)
        XCTAssertFalse(model.isCountingMatches)
    }
}
