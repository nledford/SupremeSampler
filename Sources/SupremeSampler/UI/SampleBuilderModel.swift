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
    private(set) var propTree: [CatalogPropNode] = []
    /// The open catalog's color labels, for the label rule's picker.
    private(set) var catalogLabels: CatalogValues = .loading
    /// The open catalog's bookmark values, for the bookmark rule's picker.
    private(set) var catalogBookmarks: CatalogValues = .loading
    /// The open catalog's file types, for the file-type rule's picker.
    /// Loaded in the background after opening (see `loadFileTypes`).
    private(set) var catalogFileTypes: CatalogValues = .loading
    private var fileTypesTask: Task<Void, Never>?
    private(set) var matchingCount: Int?
    private(set) var errorMessage: String?
    private(set) var isOpeningCatalog = false
    private(set) var isCountingMatches = false
    /// Why the last save failed, if it did; cleared by the next success.
    private(set) var saveErrorMessage: String?

    /// What was last written to disk, and from which filter, size and
    /// folder balance -- kept
    /// so `lastSavedScriptURL` can tell whether the script on screen
    /// still matches that file.
    private struct SavedScript {
        let url: URL
        let filter: SampleFilter
        let sampleSize: Int
        let folderBalance: FolderBalance
    }
    private var lastSave: SavedScript?

    private var catalog: (any SampleBuilderCatalog)?

    /// Where "which catalog was last opened" is persisted across app
    /// launches, the same port pattern as `catalog`/`SampleBuilderCatalog`.
    private let catalogStore: any RecentCatalogStore

    /// Deliberately no default for `catalogStore`: it used to default to
    /// the real `UserDefaults` store, and every test that wrote
    /// `SampleBuilderModel()` and opened a fixture overwrote the real
    /// app's remembered catalog path. Now the choice is explicit --
    /// `ContentView` passes the real store; previews and tests pass
    /// `InMemoryRecentCatalogStore` -- and forgetting is a compile error.
    init(catalogStore: any RecentCatalogStore) {
        self.catalogStore = catalogStore
    }

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

    /// The bounds the sample size is held to. Lives on the model rather
    /// than only in the view because the control that sets it is a
    /// free-typed number field, not a `Stepper` -- a `Stepper` enforces
    /// its own `in:` range, a text field doesn't, so without this a
    /// typed `0` or negative value would flow straight into
    /// `SAMPLE_SIZE = ...` and generate a script that silently samples
    /// nothing.
    static let sampleSizeRange = 1...1_000_000

    /// Bumped every time `sampleSize`'s `didSet` actually clamps a value
    /// (not on every write -- only when the typed value was out of
    /// range). `SampleSettingsView` reads this to force its `TextField`
    /// to rebuild.
    ///
    /// Why that's needed: confirmed by hand in the running app that
    /// without it, typing an out-of-range value (e.g. "5000000") left
    /// the field showing that raw, un-clamped text indefinitely -- even
    /// though `sampleSize` itself, and the generated script, had already
    /// silently moved to the clamped value (1,000,000). SwiftUI's
    /// `TextField(value:format:)` only re-reads its bound value into its
    /// own on-screen text when the field loses focus; a same-tick
    /// program write to the binding (this `didSet`) doesn't refresh the
    /// visible text while the user is still typing in it. Giving the
    /// field a fresh `.id()` when (and only when) a clamp actually
    /// happens forces SwiftUI to tear down and recreate it, which reads
    /// the corrected value -- without this, in-range typing would also
    /// rebuild the field (and drop focus) on every keystroke.
    private(set) var sampleSizeClampGeneration = 0

    /// `didSet` is Swift's property observer -- a hook that runs after
    /// every write, the closest thing to a Python `@property` setter or
    /// a JS `Object.defineProperty` setter, but without giving up the
    /// plain stored-property syntax. Assigning to the property from
    /// inside its own `didSet` does *not* re-enter `didSet` (observers
    /// aren't recursive in Swift), so the clamp below settles in one
    /// pass instead of looping.
    var sampleSize: Int = 10_000 {
        didSet {
            let clamped = min(
                max(sampleSize, Self.sampleSizeRange.lowerBound),
                Self.sampleSizeRange.upperBound
            )
            if clamped != sampleSize {
                sampleSize = clamped
                sampleSizeClampGeneration += 1
            }
            if sampleSize != oldValue { persistSession() }
        }
    }

    /// How the sample spreads across folders (see `FolderBalance`). Off
    /// by default, so a script is the plain random sample unless asked.
    var folderBalance: FolderBalance = .off {
        didSet {
            if folderBalance != oldValue { persistSession() }
        }
    }

    /// How the requested sample compares with the matches -- whether the
    /// script will fill it. `nil` until a count has come back; while a
    /// newer count runs, it describes the previous one.
    var sampleForecast: SampleForecast? {
        matchingCount.map { SampleForecast(matching: $0, requested: sampleSize) }
    }

    /// Shrinks the sample to exactly the photos that match -- the one-
    /// click answer to a sample that would come up short.
    /// Does nothing while a newer count runs: the count on screen is for
    /// the previous rules then.
    func useAllMatches() {
        guard !isCountingMatches, let matchingCount, matchingCount >= 1 else { return }
        sampleSize = matchingCount
    }

    // The folder audit: per-folder counts for one filter, fetched in the
    // background while folder balance is on. Kept with the filter they
    // were counted for, so a changed filter never shows stale numbers.
    private var folderCounts: (filter: SampleFilter, folders: [FolderPhotoCount])?
    private var folderAuditTask: Task<Void, Never>?
    private var folderAuditFilter: SampleFilter?
    private(set) var isAuditingFolders = false
    private(set) var folderAuditErrorMessage: String?

    /// What the chosen folder balance would do to a sample of the
    /// current filter -- `nil` while it's off, or until the audit for
    /// this filter has finished. Changing the mode or sample size
    /// recomputes it from the same counts, without querying again.
    var folderBalancePreview: FolderBalancePreview? {
        guard folderBalance != .off, let folderCounts, folderCounts.filter == currentFilter else { return nil }
        return FolderBalancePreview(folders: folderCounts.folders, balance: folderBalance, sampleSize: sampleSize)
    }

    /// Everything in the rule builder: the root "Match all/any/none of"
    /// group and its (possibly nested) rules. Starts empty, which
    /// matches the whole catalog.
    ///
    /// Every change is undoable (Edit > Undo, when the window has handed
    /// over its `undoManager`) and saved for the next launch. Undoing
    /// sets `rules` back, which runs this `didSet` again -- and a change
    /// registered while undoing is exactly what `UndoManager` files as
    /// the redo, so redo needs no code of its own.
    var rules = RuleGroupDraft() {
        didSet {
            guard rules != oldValue else { return }
            if let undoManager, !isAdoptingSession {
                let isUndoOrRedo = undoManager.isUndoing || undoManager.isRedoing
                if isUndoOrRedo || textEditingDepth == 0 {
                    registerRulesUndo(restoring: oldValue)
                }
                // An undo mid-edit moves the edit's starting point, or
                // ending the edit would register a step that undoes it.
                if isUndoOrRedo && textEditingDepth > 0 { rulesBeforeTextEdit = rules }
            }
            // A session swapped in on open isn't an edit to take back
            // (the check above), nor worth saving again.
            persistSession()
        }
    }

    /// The window's undo stack, handed over by `ContentView` once the
    /// window is up. `@ObservationIgnored`: no view draws from it, so
    /// setting it shouldn't re-render anything.
    @ObservationIgnored var undoManager: UndoManager?

    private func registerRulesUndo(restoring previous: RuleGroupDraft) {
        undoManager?.registerUndo(withTarget: self) { model in
            // Undo runs on the main thread, where this model lives;
            // `assumeIsolated` states that to the compiler rather than
            // hopping threads.
            MainActor.assumeIsolated { model.rules = previous }
        }
        undoManager?.setActionName("Rule Change")
    }

    // MARK: - Text fields and undo

    // While a rule's text field is being edited, AppKit's field editor
    // keeps its own typing undo on the same stack, and ⌘Z undoes typing
    // in the field, as in any Mac app. Registering each debounced commit
    // as well put every edit on the stack twice, so ⌘Z bounced between
    // old and new text (seen on screen, 2026-09-25). Instead the model
    // stays out of the way while a field is focused and, when editing
    // ends, registers the whole edit as one step.
    @ObservationIgnored private var textEditingDepth = 0
    @ObservationIgnored private var rulesBeforeTextEdit: RuleGroupDraft?

    /// A rule's text field gained focus.
    func beginTextEditing() {
        if textEditingDepth == 0 { rulesBeforeTextEdit = rules }
        textEditingDepth += 1
    }

    /// A rule's text field lost focus, its last text already committed.
    func endTextEditing() {
        guard textEditingDepth > 0 else { return }
        textEditingDepth -= 1
        guard textEditingDepth == 0, let before = rulesBeforeTextEdit else { return }
        rulesBeforeTextEdit = nil
        if before != rules, !isAdoptingSession { registerRulesUndo(restoring: before) }
    }

    /// Derives the domain filter from the rules being edited -- pure, no
    /// catalog access, trivially testable without a real file. Category
    /// selections are expanded to whole branches against `propTree`
    /// (see `CategoryBranch`).
    var currentFilter: SampleFilter {
        SampleFilter(root: rules.domainGroup(resolvingCategoriesIn: propTree))
    }

    /// The generated `.psc` source for the current filter/size -- pure,
    /// recomputed on every read. SwiftUI's diffing means a view only
    /// actually re-renders when this (or whatever it reads) changes, so
    /// there's no need to cache it by hand.
    var generatedScript: String {
        RandomSampleScriptGenerator.generate(sampleSize: sampleSize, filter: currentFilter, folderBalance: folderBalance)
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
                propTree = try await opened.listPropTree()
                catalogLabels = .loading
                do {
                    catalogLabels = .loaded(try await opened.listLabels())
                } catch {
                    catalogLabels = .failed(error.localizedDescription)
                }
                catalogBookmarks = .loading
                do {
                    catalogBookmarks = .loaded(try await opened.listBookmarks())
                } catch {
                    catalogBookmarks = .failed(error.localizedDescription)
                }
                catalog = opened
                catalogPath = path
                catalogStore.savePath(path)
                adoptSession(for: path)
                folderCounts = nil
                refreshMatchingCount()
                refreshFolderAudit()
                loadFileTypes(from: opened)
            } catch {
                catalog = nil
                catalogPath = nil
                propTree = []
                matchingCount = nil
                errorMessage = "Couldn't open catalog: \(error.localizedDescription)"
            }
        }
    }

    /// Lists file types without holding up the catalog open: it scans
    /// every photo (~4s on the real catalog). Cancels a previous load, so
    /// switching catalogs can't have the old catalog's list arrive late
    /// and overwrite the new one -- the same guard `refreshMatchingCount`
    /// uses.
    private func loadFileTypes(from catalog: PhotoSupremeCatalog) {
        fileTypesTask?.cancel()
        catalogFileTypes = .loading
        fileTypesTask = Task {
            do {
                let types = try await catalog.listFileTypes()
                guard !Task.isCancelled else { return }
                catalogFileTypes = .loaded(types)
            } catch {
                guard !Task.isCancelled else { return }
                catalogFileTypes = .failed(error.localizedDescription)
            }
        }
    }

    /// Called once when the app's root view first appears (see
    /// `ContentView`'s `.task`). If a catalog was opened successfully in
    /// a previous launch and its path is still on record, tries to open
    /// it again automatically -- same success/failure handling as a
    /// manual `openCatalog` call, so a moved/deleted/unmounted file
    /// falls back to the picker with an explanatory error rather than
    /// failing silently or getting stuck. Deliberately does *not* clear
    /// the saved path on failure: the file might just be on a
    /// disconnected external volume, worth trying again next launch
    /// rather than forgetting it after one miss.
    func attemptAutoOpenRecentCatalog() {
        guard catalogPath == nil else { return }
        guard let path = catalogStore.loadPath() else { return }
        openCatalog(at: path)
    }

    // MARK: - The session saved between launches

    /// Which catalog the rules on screen were built against -- the path
    /// they're saved under. Separate from `catalogPath` because it only
    /// changes once `adoptSession` has decided what to do with the rules.
    private var rulesCatalogPath: String?

    /// Set while `adoptSession` swaps the rules in, so that swap is
    /// neither undoable nor saved -- saving would overwrite the last
    /// catalog's session with an empty one just for having looked at
    /// another catalog.
    private var isAdoptingSession = false

    /// Called once a catalog has opened. Rules hold keyword picks by the
    /// catalog's own GUIDs, which mean nothing in another catalog, so
    /// opening a different catalog never keeps the old rules: it puts
    /// back that catalog's saved session if there is one, and otherwise
    /// starts empty. Only after the open succeeds -- restoring earlier
    /// would leave a catalog's rules on screen when it failed to open,
    /// ready to be saved against whichever catalog was opened next.
    /// Undo history goes too: undoing into another catalog's rules would
    /// bring the same problem back.
    private func adoptSession(for path: String) {
        guard rulesCatalogPath != path else { return }
        isAdoptingSession = true
        defer { isAdoptingSession = false }
        if let session = SavedSession.decode(catalogStore.loadSession()), session.catalogPath == path {
            rules = session.rules
            sampleSize = session.sampleSize
            folderBalance = session.folderBalance
        } else if rulesCatalogPath != nil {
            rules = RuleGroupDraft()
        }
        rulesCatalogPath = path
        // The old catalog's edits, so Undo can't bring its rules back.
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Saves what's being built, against the catalog it was built for.
    /// Nothing is saved before a catalog is open: a session is only
    /// worth restoring for the catalog it was built on.
    private func persistSession() {
        guard !isAdoptingSession, let rulesCatalogPath else { return }
        let session = SavedSession(
            catalogPath: rulesCatalogPath, rules: rules, sampleSize: sampleSize, folderBalance: folderBalance)
        catalogStore.saveSession(session.encoded())
    }

    // MARK: - Copying the script

    /// Goes up by one on every copy, so the Copy button can flash
    /// "Copied" however the copy was made (button or Edit menu).
    private(set) var copyCount = 0

    /// Puts the current script on `clipboard`. Not gated on the count
    /// like saving: pasting into Script Studio is itself the review step.
    func copyScript(to clipboard: any ClipboardWriting) {
        clipboard.write(generatedScript)
        copyCount += 1
    }

    // MARK: - Saving the script to a file

    /// Saving waits for the pre-flight count: "never let a script be
    /// generated for a filter the user hasn't seen validated against real
    /// data" (PRODUCT.md), and a file is the artifact that outlives this
    /// session. (Copy isn't gated the same way -- pasting into Script
    /// Studio is itself the review step.) A count of 0 still saves: a
    /// rule like "pending deletion" is expected to match nothing between
    /// runs of the tool that sets it, and the window already says the
    /// sample will be empty.
    var canSaveScript: Bool {
        catalog != nil && !isCountingMatches && matchingCount != nil
    }

    /// The file the on-screen script was last saved to -- but only while
    /// the script still matches it. Derived, not stored: editing a rule
    /// or the sample size hides it, and undoing the edit brings it back,
    /// with no bookkeeping to forget.
    var lastSavedScriptURL: URL? {
        guard let lastSave, lastSave.filter == currentFilter, lastSave.sampleSize == sampleSize,
            lastSave.folderBalance == folderBalance
        else { return nil }
        return lastSave.url
    }

    /// Asks `chooser` where to save (starting in `directory`), then
    /// writes the current script there in `.psc` format. Cancelling does
    /// nothing. The write is atomic -- to a temporary file, then renamed
    /// into place -- so a failure can't leave a half-written script
    /// behind, or damage the file being replaced.
    func saveScript(using chooser: any ScriptDestinationChoosing, startingIn directory: URL?) async {
        guard canSaveScript else { return }
        guard
            let destination = await chooser.chooseDestination(
                suggestedFileName: PSCFile.suggestedFileName, startingIn: directory)
        else { return }

        let filter = currentFilter
        let size = sampleSize
        let balance = folderBalance
        let script = RandomSampleScriptGenerator.generate(sampleSize: size, filter: filter, folderBalance: balance)
        do {
            try PSCFile.encode(script).write(to: destination, options: .atomic)
            lastSave = SavedScript(url: destination, filter: filter, sampleSize: size, folderBalance: balance)
            saveErrorMessage = nil
        } catch {
            lastSave = nil
            saveErrorMessage = "Couldn't save the script: \(error.localizedDescription)"
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

    /// Counts matching photos per folder for the folder balance preview,
    /// in the background -- a full scan, seconds on the real catalog.
    /// Called by the view when the filter or the folder balance changes.
    /// Does nothing while folder balance is off (and stops an audit in
    /// progress), when the counts for this filter are already in hand,
    /// or when they're already being fetched. Otherwise cancels any
    /// older audit and starts one, with the same "only an uncancelled
    /// task writes" guard as `refreshMatchingCount`.
    func refreshFolderAudit() {
        guard folderBalance != .off, let catalog else {
            folderAuditTask?.cancel()
            folderAuditFilter = nil
            isAuditingFolders = false
            return
        }
        let filter = currentFilter
        if folderCounts?.filter == filter { return }
        if isAuditingFolders && folderAuditFilter == filter { return }

        folderAuditTask?.cancel()
        folderAuditFilter = filter
        isAuditingFolders = true
        folderAuditErrorMessage = nil
        folderAuditTask = Task {
            do {
                let folders = try await catalog.folderPhotoCounts(for: filter)
                guard !Task.isCancelled else { return }
                folderCounts = (filter, folders)
            } catch {
                guard !Task.isCancelled else { return }
                folderCounts = nil
                folderAuditErrorMessage = "Couldn't check folders: \(error.localizedDescription)"
            }
            folderAuditFilter = nil
            isAuditingFolders = false
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
    func injectCatalogForTesting(_ catalog: any SampleBuilderCatalog, propTree: [CatalogPropNode] = []) {
        self.catalog = catalog
        self.catalogPath = "test"
        self.rulesCatalogPath = "test"
        self.propTree = propTree
    }

    /// Test seam: awaits whatever `refreshMatchingCount()` call is
    /// currently in flight, so a test can wait for it to actually finish
    /// instead of guessing how long to sleep.
    func waitForPendingMatchCountForTesting() async {
        await matchCountTask?.value
    }

    /// Test seam: awaits the folder audit, if one is running.
    func waitForPendingFolderAuditForTesting() async {
        await folderAuditTask?.value
    }

    /// Test seam: awaits the background file-type listing, if one is
    /// running.
    func waitForPendingFileTypesForTesting() async {
        await fileTypesTask?.value
    }

    /// Test seam: awaits whatever `openCatalog(at:)` call is currently
    /// in flight.
    func waitForPendingCatalogOpenForTesting() async {
        await openCatalogTask?.value
    }
}
