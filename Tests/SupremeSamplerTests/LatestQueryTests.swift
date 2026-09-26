import XCTest

@testable import SupremeSampler

/// Pins the one invariant `LatestQuery` exists to hold: a superseded
/// query's result is dropped, even when it was already past its `await`
/// when the cancellation arrived. That last part is why the delays below
/// deliberately ignore cancellation -- `Task.sleep` would throw instead,
/// and the test would pass for the wrong reason (see the same note on
/// `SampleBuilderModelTests.FakeCatalog`).
@MainActor
final class LatestQueryTests: XCTestCase {
    private struct FakeError: Error, LocalizedError {
        var errorDescription: String? { "fake failure" }
    }

    /// Sleeps without honoring cancellation, so a superseded query really
    /// does reach the point where it would write its result.
    private func uncancellableDelay(_ nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                continuation.resume()
            }
        }
    }

    func test_givenAQuery_whenItFinishes_thenItsResultIsApplied() async {
        let query = LatestQuery<Int>()
        var applied: [Int] = []

        query.run { 42 } apply: { result in
            if case .success(let value) = result { applied.append(value) }
        }
        await query.wait()

        XCTAssertEqual(applied, [42])
    }

    func test_givenAFailingQuery_whenItFinishes_thenTheErrorIsApplied() async {
        let query = LatestQuery<Int>()
        var applied: [String] = []

        query.run { throw FakeError() } apply: { result in
            if case .failure(let error) = result { applied.append(error.localizedDescription) }
        }
        await query.wait()

        XCTAssertEqual(applied.count, 1)
    }

    /// The bug class this type exists to prevent: a slow query for a
    /// filter the user has already changed away from must not overwrite
    /// the newer, current result.
    func test_givenASlowQuerySupersededByAFastOne_whenBothFinish_thenOnlyTheNewerResultIsApplied() async {
        let query = LatestQuery<Int>()
        var applied: [Int] = []

        query.run {
            await self.uncancellableDelay(200_000_000)
            return 100  // slow, would-be-stale
        } apply: { result in
            if case .success(let value) = result { applied.append(value) }
        }
        query.run { 5 } apply: { result in  // fast, current
            if case .success(let value) = result { applied.append(value) }
        }

        await query.wait()
        // Let the superseded query finish too, so a late write would have
        // had every chance to land.
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(applied, [5])
    }

    func test_givenAQueryInFlight_whenCancelled_thenItsResultIsNotApplied() async {
        let query = LatestQuery<Int>()
        var applied: [Int] = []

        query.run {
            await self.uncancellableDelay(100_000_000)
            return 1
        } apply: { result in
            if case .success(let value) = result { applied.append(value) }
        }
        query.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(applied.isEmpty)
    }

    /// `wait()` must mean "the query in flight has finished", including
    /// one that was cancelled -- a seam that returned early would let a
    /// test assert on state the query hadn't finished touching yet.
    func test_givenAQueryInFlight_whenCancelled_thenWaitAwaitsItToActuallyFinish() async {
        let query = LatestQuery<Int>()
        let finished = Flag()

        query.run {
            await self.uncancellableDelay(100_000_000)
            await finished.set()
            return 1
        } apply: { _ in }
        query.cancel()
        await query.wait()

        let didFinish = await finished.value
        XCTAssertTrue(didFinish, "wait() returned before the cancelled query finished")
    }

    /// Set from the query's own (non-isolated) task, read from the test's
    /// main actor -- an `actor` is the safe way to share that, where a
    /// plain `var` would be a data race.
    private actor Flag {
        private(set) var value = false
        func set() { value = true }
    }

    func test_givenNoQueryEverRun_whenWaiting_thenItReturnsImmediately() async {
        await LatestQuery<Int>().wait()
    }
}
