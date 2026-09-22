import GRDB
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
    // Three kinds of tests in this file: pure `currentFilter`/
    // `generatedScript` derivation (no catalog at all); `refreshMatchingCount`
    // against a fake `SampleBuilderCatalog` (see `FakeCatalog`), which is
    // how the stale-request cancellation race is made deterministically
    // testable; and `openCatalog` against a real, small SQLite fixture
    // (see `makeFixturePath`), since `openCatalog` itself constructs a
    // real `PhotoSupremeCatalog` internally and can't take the fake --
    // that's the one seam `SampleBuilderCatalog` doesn't cover.

    /// Builds a minimal real SQLite fixture file (same shape as
    /// `PhotoSupremeCatalogTests`') and returns its path, for the one
    /// method here that can't be tested against `FakeCatalog`.
    private func makeFixturePath(rowCount: Int = 3) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(
                sql: """
                    CREATE TABLE idCatalogItem (
                        GUID TEXT PRIMARY KEY,
                        Rating INTEGER NOT NULL DEFAULT 0
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE idCatalogItemDefinition (
                        GUID TEXT NOT NULL,
                        CatalogItemGUID TEXT NOT NULL,
                        PRIMARY KEY (GUID, CatalogItemGUID)
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE idProp (
                        GUID TEXT PRIMARY KEY,
                        ParentGUID TEXT,
                        PropName TEXT NOT NULL
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE idPropCategory (
                        GUID TEXT PRIMARY KEY,
                        CategoryName TEXT NOT NULL
                    )
                    """)
            for i in 1...rowCount {
                try db.execute(
                    sql: "INSERT INTO idCatalogItem (GUID, Rating) VALUES (?, ?)",
                    arguments: ["item-\(i)", 0]
                )
            }
            // A single top-level category with no children -- enough
            // for tests that just need `propTree` to be non-empty and
            // named something recognizable, without needing to exercise
            // nesting (that's CatalogPropNodeTests' and
            // PhotoSupremeCatalogTests' job).
            try db.execute(
                sql: "INSERT INTO idPropCategory (GUID, CategoryName) VALUES (?, ?)",
                arguments: ["cat-1", "Vacation"]
            )
        }
        return path
    }

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

    func test_givenOutOfRangeSampleSize_whenSetting_thenClampsToRange() {
        // The sample-size control is a free-typed number field, so unlike
        // the `Stepper` it replaced it can produce values outside the
        // range. Those must not reach `SAMPLE_SIZE = ...` in the
        // generated script -- a size of 0 or less would sample nothing,
        // silently.
        let model = SampleBuilderModel()

        model.sampleSize = 0
        XCTAssertEqual(model.sampleSize, 1)
        XCTAssertTrue(model.generatedScript.contains("SAMPLE_SIZE = 1;"))

        model.sampleSize = -5
        XCTAssertEqual(model.sampleSize, 1)

        model.sampleSize = 2_000_000
        XCTAssertEqual(model.sampleSize, 1_000_000)

        // Both bounds and an interior value pass through untouched --
        // the clamp must not be off by one at either end.
        model.sampleSize = 1
        XCTAssertEqual(model.sampleSize, 1)
        model.sampleSize = 1_000_000
        XCTAssertEqual(model.sampleSize, 1_000_000)
        model.sampleSize = 25_000
        XCTAssertEqual(model.sampleSize, 25_000)
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

        let propTree: [CatalogPropNode]
        /// Keyed by 1-based call index (the Nth call to
        /// `matchingItemCount` across this fake's lifetime), so a test
        /// can give the 1st call different behavior than the 2nd.
        let responses: [Int: Response]

        private let lock = NSLock()
        private var callCount = 0

        init(propTree: [CatalogPropNode] = [], responses: [Int: Response] = [:]) {
            self.propTree = propTree
            self.responses = responses
        }

        func listPropTree() async throws -> [CatalogPropNode] { propTree }

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

    // MARK: - openCatalog (against a real SQLite fixture)

    func test_givenValidCatalogPath_whenOpening_thenLoadsPropsAndMatchCount() async throws {
        let path = try makeFixturePath(rowCount: 3)
        let model = SampleBuilderModel()

        model.openCatalog(at: path)
        await model.waitForPendingCatalogOpenForTesting()

        XCTAssertEqual(model.catalogPath, path)
        XCTAssertEqual(model.propTree.map(\.name), ["Vacation"])
        XCTAssertFalse(model.isOpeningCatalog)
        XCTAssertNil(model.errorMessage)
        // openCatalog kicks off a matching-count refresh once it
        // succeeds; wait for that too rather than asserting on a
        // possibly-still-in-flight count.
        await model.waitForPendingMatchCountForTesting()
        XCTAssertEqual(model.matchingCount, 3)
    }

    func test_givenInvalidCatalogPath_whenOpening_thenSetsErrorAndClearsState() async {
        let model = SampleBuilderModel()

        model.openCatalog(at: "/nonexistent/\(UUID().uuidString).sqlite")
        await model.waitForPendingCatalogOpenForTesting()

        XCTAssertNil(model.catalogPath)
        XCTAssertEqual(model.propTree, [])
        XCTAssertNil(model.matchingCount)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isOpeningCatalog)
    }

    /// Exercises the re-entrancy guard added as defense in depth (see
    /// `openCatalog`'s doc comment): calling it again while one is
    /// already opening is a no-op, not a second overlapping attempt.
    func test_givenCatalogAlreadyOpening_whenOpeningAgain_thenSecondCallIsIgnored() async throws {
        let path = try makeFixturePath()
        let model = SampleBuilderModel()

        model.openCatalog(at: path)
        XCTAssertTrue(model.isOpeningCatalog, "first call should have started opening synchronously")

        model.openCatalog(at: "/some/other/path.sqlite")
        await model.waitForPendingCatalogOpenForTesting()

        // If the guard didn't work, the second call's failure path
        // (bad path) could have won the race and left catalogPath nil.
        XCTAssertEqual(model.catalogPath, path)
    }

    func test_givenPickerFailure_whenReported_thenSetsErrorMessage() {
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "disk unmounted" }
        }
        let model = SampleBuilderModel()

        model.reportPickerFailure(FakeError())

        XCTAssertEqual(model.errorMessage, "Couldn't open file picker: disk unmounted")
    }

    func test_givenNoCatalogOpen_whenRefreshingMatchingCount_thenClearsCountWithoutError() {
        let model = SampleBuilderModel()

        model.refreshMatchingCount()

        XCTAssertNil(model.matchingCount)
        XCTAssertFalse(model.isCountingMatches)
    }

    // MARK: - Remembering the last-opened catalog

    /// An in-memory `RecentCatalogStore` fake -- same role as
    /// `FakeCatalog` above, just for the persistence port instead of the
    /// query port. `@unchecked Sendable` justified the same way: the
    /// lock is what actually makes the one piece of mutable state safe
    /// to touch from a background task.
    private final class FakeRecentCatalogStore: RecentCatalogStore, @unchecked Sendable {
        private let lock = NSLock()
        private var path: String?

        init(initialPath: String? = nil) {
            path = initialPath
        }

        func loadPath() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return path
        }

        func savePath(_ path: String?) {
            lock.lock()
            defer { lock.unlock() }
            self.path = path
        }
    }

    func test_givenSuccessfulOpen_whenCatalogOpens_thenPathIsSavedToStore() async throws {
        let path = try makeFixturePath()
        let store = FakeRecentCatalogStore()
        let model = SampleBuilderModel(catalogStore: store)

        model.openCatalog(at: path)
        await model.waitForPendingCatalogOpenForTesting()

        XCTAssertEqual(store.loadPath(), path)
    }

    func test_givenFailedOpen_whenCatalogFailsToOpen_thenPathIsNotSaved() async {
        let store = FakeRecentCatalogStore()
        let model = SampleBuilderModel(catalogStore: store)

        model.openCatalog(at: "/nonexistent/\(UUID().uuidString).sqlite")
        await model.waitForPendingCatalogOpenForTesting()

        XCTAssertNil(store.loadPath())
    }

    func test_givenSavedPathThatStillExists_whenAttemptingAutoOpen_thenOpensItAutomatically() async throws {
        let path = try makeFixturePath(rowCount: 2)
        let store = FakeRecentCatalogStore(initialPath: path)
        let model = SampleBuilderModel(catalogStore: store)

        model.attemptAutoOpenRecentCatalog()
        await model.waitForPendingCatalogOpenForTesting()

        XCTAssertEqual(model.catalogPath, path)
        XCTAssertNil(model.errorMessage)
    }

    func test_givenNoSavedPath_whenAttemptingAutoOpen_thenDoesNothing() {
        let store = FakeRecentCatalogStore()
        let model = SampleBuilderModel(catalogStore: store)

        model.attemptAutoOpenRecentCatalog()

        // Synchronous: attemptAutoOpenRecentCatalog returns immediately
        // without starting a Task at all when there's no saved path, so
        // there's nothing to await here -- if it *had* started opening,
        // isOpeningCatalog would already be true by this point (same
        // reasoning as the CatalogPickerView spinner tests).
        XCTAssertFalse(model.isOpeningCatalog)
        XCTAssertNil(model.catalogPath)
    }

    func test_givenSavedPathNoLongerExists_whenAttemptingAutoOpen_thenFallsBackWithError() async {
        let store = FakeRecentCatalogStore(initialPath: "/nonexistent/\(UUID().uuidString).sqlite")
        let model = SampleBuilderModel(catalogStore: store)

        model.attemptAutoOpenRecentCatalog()
        await model.waitForPendingCatalogOpenForTesting()

        XCTAssertNil(model.catalogPath)
        XCTAssertNotNil(model.errorMessage)
    }

    func test_givenCatalogAlreadyOpen_whenAttemptingAutoOpen_thenDoesNotReopen() {
        let store = FakeRecentCatalogStore(initialPath: "/some/other/path.sqlite")
        let model = SampleBuilderModel(catalogStore: store)
        model.injectCatalogForTesting(FakeCatalog())

        model.attemptAutoOpenRecentCatalog()

        // If the guard were missing, this would have started opening
        // the *store's* path, clobbering the already-injected state.
        XCTAssertFalse(model.isOpeningCatalog)
        XCTAssertEqual(model.catalogPath, "test")
    }
}
