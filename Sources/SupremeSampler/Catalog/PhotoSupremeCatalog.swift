import Foundation
import GRDB

/// Read-only access to a Photo Supreme SQLite catalog.
///
/// A `struct`, not a `class` -- there's no mutable state to protect
/// identity for, just a handle wrapping a connection pool, so a value
/// type (~ a Rust struct) is the right fit, same reasoning as
/// `CatalogExtent`.
///
/// Wraps a GRDB `DatabasePool`: a pool of reader connections suited to
/// WAL-mode SQLite databases, which is what Photo Supreme's catalog
/// actually is (see `~/Pictures/Photo Supreme/docs`).
/// Photo Supreme may have the file open with pending writes in its own
/// `-wal` file at the same time this reads it -- `DatabasePool` in
/// readonly mode is GRDB's documented way to read a WAL database
/// concurrently with another writer, roughly analogous to opening
/// `file:...?mode=ro` with `sqlite3` directly, which is what we used to
/// benchmark this catalog by hand earlier in this project's history.
///
/// This type must never grow a write method. See AGENTS.md "Safety".
///
/// `Sendable`: safe to use from any thread/task, not just the one that
/// created it -- true here because `DatabasePool` itself is Sendable
/// (it's a connection pool, built for concurrent access) and every
/// other stored property is a value type. This is what lets `async`
/// methods below call `dbPool.read` from a background executor while
/// still being invoked from `@MainActor` code (see `SampleBuilderModel`):
/// the compiler would refuse to compile this type as Sendable at all if
/// that weren't actually safe.
struct PhotoSupremeCatalog: Sendable {
    private let dbPool: DatabasePool

    // Same tuning constants as RandomCatalogSample.psc, and for the same
    // reasons (see that script's comments): a 15% safety margin above
    // the statistically expected hit count when oversampling random
    // rowids; a retry cap so a filter matching almost nothing can't spin
    // forever; a per-attempt ceiling so a very low-density filter (or a
    // heavily curated, mostly-deleted catalog) can't build a
    // pathologically large candidate batch.
    private static let oversampleMargin = 1.15
    private static let maxSampleAttempts = 8
    private static let maxSampleBatchSize = 100_000

    // NOT in RandomCatalogSample.psc (yet) -- found by this Swift port's
    // own test suite, not by anything observed in Photo Supreme itself.
    // The shortfall-proportional batch size shrinks to nearly nothing
    // once only one or two rows are still needed; at high density (most
    // of the remaining candidate space is a match) that's still enough
    // rows to draw, but a *specific* still-needed rowid can plausibly be
    // missed by a batch that small, even across every retry attempt --
    // reproduced reliably (failed ~1% of trials) against a tiny 5-row
    // fixture before this floor existed. A real, large catalog rarely
    // reaches a shortfall this small while density is still this high,
    // which is exactly why it went unnoticed until a small fixture
    // (or, in principle, a very narrow filter with few remaining
    // unsampled matches) made it likely enough to observe.
    private static let minSampleBatchSize = 50

    /// Opens `path` read-only.
    ///
    /// - Throws: `CatalogError.fileNotFound` if nothing exists at `path`
    ///   (checked explicitly up front, rather than letting SQLite's own
    ///   "unable to open database file" surface instead), or a GRDB/
    ///   SQLite error if the file exists but isn't a valid database.
    init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CatalogError.fileNotFound(path: path)
        }

        var config = Configuration()
        config.readonly = true
        dbPool = try DatabasePool(path: path, configuration: config)
    }

    /// Row count and max rowid of `idCatalogItem`, the table random
    /// sampling draws from -- the same extent query
    /// `RandomCatalogSample.psc` runs at the start of every sample, and
    /// the one benchmarked against the real multi-million-row catalog when we
    /// compared `ORDER BY RANDOM()` against random-rowid sampling.
    func catalogItemExtent() async throws -> CatalogExtent {
        // `dbPool.read { ... }` runs the closure on one of the pool's
        // reader connections and hands back whatever it returns -- similar
        // shape to Rust's `pool.get()?.query(...)` with a connection
        // borrowed from a pool, or Python's `with pool.connection() as
        // conn:`, except here it's a closure instead of a context manager.
        //
        // The `async` here is GRDB's own async overload of `read`, not a
        // hand-rolled `Task.detached` wrapper: it hops to a background
        // dispatch queue for the actual SQLite call and suspends the
        // calling task rather than blocking whatever thread called this
        // (in practice, the app's main thread/actor -- see
        // SampleBuilderModel). This is the fix for a real bug: a
        // category matching ~700k photos froze the UI when these calls
        // were synchronous.
        try await dbPool.read { db in try Self.fetchExtent(db) }
    }

    /// Counts photos matching `filter` -- the pre-flight check a script
    /// generator runs before ever writing a `.psc` file, so "this filter
    /// only matches 340 photos" surfaces immediately instead of after
    /// opening Photo Supreme and running a script that comes up short.
    func matchingItemCount(for filter: SampleFilter) async throws -> Int {
        try await dbPool.read { db in try Self.fetchMatchingCount(db, matching: filter) }
    }

    /// Draws up to `count` random, distinct photo GUIDs satisfying
    /// `filter` (unfiltered by default, i.e. the whole catalog). This is
    /// the Swift port of `RandomCatalogSample.psc`'s `RandomItemGUIDs`,
    /// generalized with a filter predicate: draw random rowids in
    /// `[1, maxRowID]`, keep the ones that both exist and satisfy
    /// `filter`, oversampling to cover the miss rate, with a retry loop
    /// topping up any shortfall. See that script and AGENTS.md for why
    /// this beats `ORDER BY RANDOM() LIMIT N` (it does -- 10x, benchmarked
    /// against the real catalog).
    ///
    /// If `count` exceeds how many rows actually match `filter`, returns
    /// every match exactly once rather than looping forever trying to
    /// reach an unreachable count.
    func sampleGUIDs(count: Int, matching filter: SampleFilter = SampleFilter()) async throws -> [String] {
        try await dbPool.read { db in
            let extent = try Self.fetchExtent(db)
            guard extent.maxRowID > 0 else { return [] }

            let matchingCount = try Self.fetchMatchingCount(db, matching: filter)
            let wantedCount = min(count, matchingCount)
            guard wantedCount > 0 else { return [] }

            // Fraction of the rowid space [1, maxRowID] that actually
            // satisfies `filter` -- how a randomly drawn rowid is likely
            // to be both a live row *and* a match. Guaranteed > 0 here:
            // wantedCount > 0 implies matchingCount > 0.
            let density = Double(matchingCount) / Double(extent.maxRowID)
            let predicate = Self.predicate(for: filter)

            // A Set for the same reason Rust would reach for a HashSet or
            // Python a `set()` here: O(1) average-case membership checks
            // to dedupe GUIDs that reappear across separate draws, versus
            // the RandomCatalogSample.psc script's TStringList-sorted-
            // with-dupIgnore workaround (Photo Supreme's interpreter has
            // no hash-set type).
            var seen = Set<String>()
            var guids: [String] = []
            var attempt = 0

            while guids.count < wantedCount && attempt < Self.maxSampleAttempts {
                attempt += 1
                let shortfall = wantedCount - guids.count
                let batchSize = min(
                    max(
                        Int(Double(shortfall) / density * Self.oversampleMargin) + 1,
                        Self.minSampleBatchSize
                    ),
                    Self.maxSampleBatchSize
                )

                // `Int.random(in:)` is Swift's standard-library random
                // number generator (~ Rust's `rand::rng().random_range()`
                // or Python's `random.randint()`) -- no zero-argument
                // workaround needed here, unlike Photo Supreme's script
                // interpreter (see AGENTS.md).
                let candidates = (0..<batchSize).map { _ in Int.random(in: 1...extent.maxRowID) }

                let request: SQLRequest<String> = """
                    SELECT GUID FROM idCatalogItem
                    WHERE rowid IN \(candidates) AND \(predicate)
                    """
                // `for x in seq where condition` is Swift's built-in loop
                // filter -- equivalent to Python's
                // `for x in seq: if condition: ...` or Rust's
                // `for x in seq.iter().filter(|x| condition)`, just
                // spelled as part of the `for` statement instead of a
                // separate call or nested `if`.
                for guid in try request.fetchAll(db) where !seen.contains(guid) {
                    seen.insert(guid)
                    guids.append(guid)
                    if guids.count == wantedCount { break }
                }
            }

            return guids
        }
    }

    /// Lists every category/keyword prop in the catalog, sorted by name
    /// -- the data source for a category picker in the UI. Only 189 rows
    /// in the real catalog (per `docs/schema.md`), so no pagination or
    /// filtering needed here; a plain `idProp` scan, not the richer
    /// `v_PropPath` view (which resolves each prop's full breadcrumb
    /// path and top-level category via `idCache_Prop`) -- a flat,
    /// name-sorted list is enough for picking props to filter by, and
    /// avoids needing to model `idCache_Prop` and its maintenance
    /// triggers just to test this query.
    func listProps() async throws -> [CatalogProp] {
        try await dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT GUID, PropName FROM idProp ORDER BY PropName")
                .map { CatalogProp(guid: $0["GUID"], name: $0["PropName"]) }
        }
    }

    /// Shared by `catalogItemExtent()` and `sampleGUIDs`, both of which
    /// need it. Takes an already-open `Database` (rather than reading
    /// from `dbPool` itself) so `sampleGUIDs` can call this and
    /// `fetchMatchingCount` within the *same* pooled connection instead
    /// of checking out a second one -- GRDB does support nesting a
    /// `dbPool.read` inside another, but doing so ties up two reader
    /// connections for one logical operation for no benefit here.
    private static func fetchExtent(_ db: Database) throws -> CatalogExtent {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*) AS rowCount, MAX(rowid) AS maxRowID FROM idCatalogItem"
        )!

        let rowCount: Int = row["rowCount"]
        // MAX(rowid) over zero rows is SQL NULL, so this column has to be
        // read as an optional (`Int?`, Swift's equivalent of Rust's
        // `Option<i64>` or Python's `Optional[int]`) and defaulted --
        // reading it as a plain `Int` would crash on an empty table.
        let maxRowID: Int? = row["maxRowID"]

        return CatalogExtent(rowCount: rowCount, maxRowID: maxRowID ?? 0)
    }

    private static func fetchMatchingCount(_ db: Database, matching filter: SampleFilter) throws -> Int {
        // `SQLRequest<Int>` + string interpolation here is GRDB's `SQL`
        // mechanism, not raw string concatenation: every `\(...)`
        // interpolation of a value (an Int, an array of GUIDs, or
        // another SQL fragment) is captured as a bound parameter under
        // the hood, the same protection Rust's `sqlx::query!` or a
        // parameterized query in Python's `sqlite3` module gives you --
        // values interpolated this way can't become SQL syntax, unlike
        // plain `"... WHERE x = \(value)"` string building.
        let request: SQLRequest<Int> = "SELECT COUNT(*) FROM idCatalogItem WHERE \(predicate(for: filter))"
        return try request.fetchOne(db) ?? 0
    }

    /// Builds the combined WHERE-clause fragment for `filter`. `static`
    /// and `private` because this is pure SQL-generation with no need
    /// for `self` -- closer to a free function in Rust/Python than to an
    /// instance method, just namespaced under the type instead of the
    /// module.
    private static func predicate(for filter: SampleFilter) -> SQL {
        var literal: SQL = "1 = 1"

        if let rating = filter.rating {
            literal = "\(literal) AND \(ratingPredicate(rating))"
        }
        if let category = filter.category {
            literal = "\(literal) AND \(categoryPredicate(category))"
        }
        return literal
    }

    private static func ratingPredicate(_ rating: RatingFilter) -> SQL {
        switch rating {
        case .exactly(let value):
            return "Rating = \(value)"
        case .atLeast(let value):
            return "Rating >= \(value)"
        case .atMost(let value):
            return "Rating <= \(value)"
        }
    }

    /// `idCatalogItemDefinition` is the many-to-many join table between
    /// photos and props (categories/keywords); see `docs/relationships.md`.
    /// Each mode below is a correlated subquery against it, correlated on
    /// `idCatalogItem.GUID` -- the outer table is referenced by its bare
    /// name rather than an alias, which SQLite allows as long as the
    /// outer FROM clause doesn't itself introduce an alias.
    private static func categoryPredicate(_ category: CategoryFilter) -> SQL {
        guard !category.propGUIDs.isEmpty else {
            // Vacuous cases: "has any of zero categories" can never be
            // true; "has all of zero categories" and "has none of zero
            // categories" are trivially true for every photo. Handled
            // explicitly so an empty selection in the rule-builder UI
            // (e.g. before the user has picked any category) produces a
            // sensible count rather than a SQL syntax error from an empty
            // `IN ()`.
            switch category.mode {
            case .any: return "0 = 1"
            case .all, .none: return "1 = 1"
            }
        }

        switch category.mode {
        case .any:
            return """
                EXISTS (
                    SELECT 1 FROM idCatalogItemDefinition d
                    WHERE d.CatalogItemGUID = idCatalogItem.GUID
                      AND d.GUID IN \(category.propGUIDs)
                )
                """
        case .none:
            return """
                NOT EXISTS (
                    SELECT 1 FROM idCatalogItemDefinition d
                    WHERE d.CatalogItemGUID = idCatalogItem.GUID
                      AND d.GUID IN \(category.propGUIDs)
                )
                """
        case .all:
            return """
                (SELECT COUNT(DISTINCT d.GUID) FROM idCatalogItemDefinition d
                 WHERE d.CatalogItemGUID = idCatalogItem.GUID
                   AND d.GUID IN \(category.propGUIDs)) = \(category.propGUIDs.count)
                """
        }
    }
}
