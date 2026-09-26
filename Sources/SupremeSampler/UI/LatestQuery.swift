import Foundation

/// Runs one background query at a time: starting a new one cancels the
/// previous, and only a query that finishes *uncancelled* is allowed to
/// write its result.
///
/// That invariant is the whole point of this type. It is easy to get
/// subtly wrong -- `SampleBuilderModel`'s match count once cleared its
/// "counting" flag from a `defer`, which let a cancelled query's cleanup
/// stomp a newer query's state -- and it used to be written out three
/// times (match count, folder audit, file types), each with its own
/// `Task` handle and its own pair of `guard !Task.isCancelled` checks.
/// Here it is written once, and tested once.
///
/// The same problem an `AbortController` solves for a superseded
/// `fetch()` in JS, or that dropping a previous `JoinHandle` solves in
/// Rust.
///
/// `@MainActor` because every caller's `apply` touches UI state, and
/// because the callers themselves are main-actor-isolated. `work` is
/// `@Sendable` and non-isolated, so the query itself still runs off the
/// main thread.
@MainActor
final class LatestQuery<Value: Sendable> {
    private var task: Task<Void, Never>?

    /// Cancels any query in flight, then starts `work`. `apply` runs on
    /// the main actor with the result -- but only if this query is still
    /// the current one when `work` finishes. A superseded query's result
    /// is dropped, even if it was already past its `await` when the
    /// cancellation arrived.
    func run(
        _ work: @escaping @Sendable () async throws -> Value,
        apply: @escaping @MainActor (Result<Value, Error>) -> Void
    ) {
        task?.cancel()
        // No `self` capture: the closure needs only `work` and `apply`,
        // so there is no query-holds-task-holds-query cycle to break.
        task = Task {
            let result: Result<Value, Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            apply(result)
        }
    }

    /// Cancels the query in flight, if any. `apply` is not called for it.
    ///
    /// The task handle is deliberately kept, not cleared: `wait()` means
    /// "the query in flight has finished", and a cancelled query is
    /// still in flight until it observes the cancellation. Clearing it
    /// here would make `wait()` return before the query had actually
    /// stopped, which is exactly the kind of guess the test seams exist
    /// to avoid.
    func cancel() {
        task?.cancel()
    }

    /// Test seam: awaits the query in flight, if any, so a test can wait
    /// for it to actually finish instead of guessing a sleep duration.
    func wait() async {
        await task?.value
    }
}
