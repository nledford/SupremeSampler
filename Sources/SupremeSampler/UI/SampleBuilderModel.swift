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
/// Catalog access (`openCatalog`, `refreshMatchingCount`) is called
/// directly, synchronously, from the main actor rather than dispatched
/// to a background queue/Task -- a deliberate simplification given the
/// benchmarks in AGENTS.md (sub-second even against the real multi-million-row
/// catalog): if a catalog operation ever becomes slow enough to visibly
/// freeze the UI, that's the signal to introduce real background
/// dispatch, not something to build preemptively now.
@Observable
@MainActor
final class SampleBuilderModel {
    private(set) var catalogPath: String?
    private(set) var availableProps: [CatalogProp] = []
    private(set) var matchingCount: Int?
    private(set) var errorMessage: String?

    private var catalog: PhotoSupremeCatalog?

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

    func openCatalog(at path: String) {
        errorMessage = nil
        do {
            let opened = try PhotoSupremeCatalog(path: path)
            catalog = opened
            catalogPath = path
            availableProps = try opened.listProps()
            refreshMatchingCount()
        } catch {
            catalog = nil
            catalogPath = nil
            availableProps = []
            matchingCount = nil
            errorMessage = "Couldn't open catalog: \(error.localizedDescription)"
        }
    }

    /// Surfaces a failure from the system file picker itself (rare --
    /// permissions, a volume disappearing mid-pick, etc.; the far more
    /// common "user just cancelled" case doesn't call this at all).
    func reportPickerFailure(_ error: Error) {
        errorMessage = "Couldn't open file picker: \(error.localizedDescription)"
    }

    /// Re-runs the pre-flight match count for `currentFilter`. Called
    /// after opening a catalog, and again by the view whenever
    /// `currentFilter` changes (via `.onChange`) -- so "342 photos
    /// match" stays live as rules are edited, the same pre-flight
    /// validation idea discussed before any script generator existed.
    func refreshMatchingCount() {
        guard let catalog else { return }
        do {
            matchingCount = try catalog.matchingItemCount(for: currentFilter)
            errorMessage = nil
        } catch {
            matchingCount = nil
            errorMessage = "Couldn't count matching photos: \(error.localizedDescription)"
        }
    }
}
