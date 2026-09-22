import Foundation
import Observation

/// Holds all rule-builder UI state and derives the domain objects
/// (`SampleFilter`, the generated script) from it.
///
/// `@Observable` (Swift's modern replacement for the older
/// `ObservableObject`/`@Published` pattern, available macOS 14+) makes
/// every stored property here trackable by SwiftUI: read one from a
/// view's `body`, and that view automatically re-renders when it
/// changes. It's the same idea as a Vue/Svelte reactive store, or MobX
/// in TypeScript -- mutate a field, dependent UI updates itself, no
/// manual "notify observers" call. There's no direct standard-library
/// equivalent in Rust; the closest analogues (Dioxus/Leptos signals) are
/// themselves recent, framework-specific additions, not part of the
/// language.
///
/// `@MainActor` pins every property access and method call on this
/// class to the main thread -- required for anything SwiftUI reads, and
/// a simple way to rule out data races on this object without hand-
/// written locking, similar in spirit to how a single-threaded JS event
/// loop makes shared mutable state safe without a mutex.
///
/// Catalog access (`openCatalog`, `refreshMatchingCount`) runs
/// asynchronously via GRDB's own `async` reads (see
/// `PhotoSupremeCatalog`), off the main actor while the query itself
/// executes, resuming here to update state. This used to be synchronous
/// -- a deliberate simplification given how fast most queries benchmark
/// (see AGENTS.md) -- until a real category matching ~700k photos froze
/// the UI, which is exactly the signal that comment said to watch for.
@Observable
@MainActor
final class SampleBuilderModel {
    private(set) var catalogPath: String?
    private(set) var availableProps: [CatalogProp] = []
    private(set) var matchingCount: Int?
    private(set) var errorMessage: String?
    private(set) var isOpeningCatalog = false
    private(set) var isCountingMatches = false

    private var catalog: (any SampleBuilderCatalog)?

    // Tracks the in-flight match-count query so a newer request can
    // cancel a still-running older one -- otherwise a slow query for a
    // filter you've already changed away from could finish *after* a
    // faster, more current one and overwrite its result with stale
    // data. The same problem an `AbortController` solves for a
    // superseded `fetch()` in JS, or that dropping a previous
    // `JoinHandle` solves in Rust.
    private var matchCountTask: Task<Void, Never>?

    // Not used for cancellation (see the doc comment on `openCatalog`
    // for why that isn't needed today) -- tracked only so a test can
    // deterministically await this Task's completion instead of
    // guessing a sleep duration, the same reason `matchCountTask` is
    // awaitable via `waitForPendingMatchCountForTesting`.
    private var openCatalogTask: Task<Void, Never>?

    var sampleSize: Int = 10_000

    var ratingEnabled = false
    var ratingComparison: RatingComparisonKind = .atLeast
    var ratingValue: Int = 3

    var categoryEnabled = false
    var categoryMode: CategoryMatchMode = .any
    var selectedCategoryGUIDs: Set<String> = []

    /// Derives the domain filter from the current toggles/values --
    /// pure, no catalog access, trivially testable without a real file.
    var currentFilter: SampleFilter {
        SampleFilter(
            rating: ratingEnabled ? ratingFilter : nil,
            category: categoryEnabled ? categoryFilter : nil
        )
    }

    private var ratingFilter: RatingFilter {
        switch ratingComparison {
        case .exactly: return .exactly(ratingValue)
        case .atLeast: return .atLeast(ratingValue)
        case .atMost: return .atMost(ratingValue)
        }
    }

    private var categoryFilter: CategoryFilter {
        CategoryFilter(propGUIDs: Array(selectedCategoryGUIDs), mode: categoryMode)
    }

    /// The generated `.psc` source for the current filter/size -- pure,
    /// recomputed on every read. SwiftUI's diffing means a view only
    /// actually re-renders when this (or whatever it reads) changes, so
    /// there's no need to cache it by hand.
    var generatedScript: String {
        RandomSampleScriptGenerator.generate(sampleSize: sampleSize, filter: currentFilter)
    }

    /// Opens `path` and loads its category list, then kicks off a match
    /// count for the current filter. Not `async` itself -- called from
    /// a synchronous SwiftUI `.fileImporter` completion -- but launches
    /// a `Task` internally so the caller doesn't block while it runs;
    /// `isOpeningCatalog` is what a view shows a spinner for meanwhile.
    ///
    /// Unlike `refreshMatchingCount`, this doesn't track its `Task` or
    /// guard against a second overlapping call -- currently safe only
    /// because the one real call site, `CatalogPickerView`, replaces its
    /// "Open Catalog…" button with the spinner while `isOpeningCatalog`
    /// is true and is itself unmounted (by `ContentView`) the moment a
    /// catalog opens successfully, so nothing can invoke this a second
    /// time while a first is still in flight. The `guard` below is
    /// defense in depth against that invariant breaking later (e.g. a
    /// future "switch catalog" feature that can call this while one is
    /// already open) -- without it, two overlapping opens could
    /// interleave in the same way `refreshMatchingCount` used to be able
    /// to before this refactor.
    func openCatalog(at path: String) {
        guard !isOpeningCatalog else { return }
        errorMessage = nil
        isOpeningCatalog = true
        openCatalogTask = Task {
            defer { isOpeningCatalog = false }
            do {
                let opened = try PhotoSupremeCatalog(path: path)
                availableProps = try await opened.listProps()
                catalog = opened
                catalogPath = path
                refreshMatchingCount()
            } catch {
                catalog = nil
                catalogPath = nil
                availableProps = []
                matchingCount = nil
                errorMessage = "Couldn't open catalog: \(error.localizedDescription)"
            }
        }
    }

    /// Surfaces a failure from the system file picker itself (rare --
    /// permissions, a volume disappearing mid-pick, etc.; the far more
    /// common "user just cancelled" case doesn't call this at all).
    func reportPickerFailure(_ error: Error) {
        errorMessage = "Couldn't open file picker: \(error.localizedDescription)"
    }

    /// Re-runs the pre-flight match count for `currentFilter` in the
    /// background. Called after opening a catalog, and again by the
    /// view whenever `currentFilter` changes (via `.onChange`) -- so
    /// "342 photos match" stays live as rules are edited, the same
    /// pre-flight validation idea discussed before any script generator
    /// existed.
    func refreshMatchingCount() {
        matchCountTask?.cancel()

        guard let catalog else {
            isCountingMatches = false
            matchingCount = nil
            return
        }

        let filter = currentFilter
        isCountingMatches = true

        matchCountTask = Task {
            do {
                let count = try await catalog.matchingItemCount(for: filter)
                // Only a task that actually finishes uninterrupted gets
                // to update state -- deliberately NOT a `defer`, and
                // deliberately checked again here rather than trusting
                // the `matchCountTask?.cancel()` above alone: a
                // superseded task might already be past this `await`
                // and about to write its (stale) result by the time the
                // next `refreshMatchingCount()` call cancels it, so
                // `isCancelled` is what actually gates whether it's
                // still allowed to touch `matchingCount`/
                // `isCountingMatches`. A `defer`-based reset here would
                // have a bug: a cancelled task's cleanup could clear
                // `isCountingMatches` right after a *newer* task has
                // already set it back to true, ending the spinner while
                // the newer query is still genuinely running.
                guard !Task.isCancelled else { return }
                matchingCount = count
                errorMessage = nil
                isCountingMatches = false
            } catch {
                guard !Task.isCancelled else { return }
                matchingCount = nil
                errorMessage = "Couldn't count matching photos: \(error.localizedDescription)"
                isCountingMatches = false
            }
        }
    }

    /// Test seam: substitutes a catalog conforming to
    /// `SampleBuilderCatalog` without going through the real file-
    /// opening path in `openCatalog`. Plain `internal` (Swift's
    /// unmarked default access level, visible module-wide -- closer to
    /// Rust's `pub(crate)` than to `private`) rather than gated behind
    /// `#if DEBUG`: `@testable import SupremeSampler` already only
    /// works from this module's own test target, so there's no
    /// production-visibility risk to guard against further.
    func injectCatalogForTesting(_ catalog: any SampleBuilderCatalog, availableProps: [CatalogProp] = []) {
        self.catalog = catalog
        self.catalogPath = "test"
        self.availableProps = availableProps
    }

    /// Test seam: awaits whatever `refreshMatchingCount()` call is
    /// currently in flight, so a test can wait for it to actually finish
    /// instead of guessing how long to sleep.
    func waitForPendingMatchCountForTesting() async {
        await matchCountTask?.value
    }

    /// Test seam: awaits whatever `openCatalog(at:)` call is currently
    /// in flight.
    func waitForPendingCatalogOpenForTesting() async {
        await openCatalogTask?.value
    }
}
