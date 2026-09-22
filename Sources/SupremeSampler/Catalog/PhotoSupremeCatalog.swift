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
struct PhotoSupremeCatalog {
    private let dbPool: DatabasePool

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
    func catalogItemExtent() throws -> CatalogExtent {
        // `dbPool.read { ... }` runs the closure on one of the pool's
        // reader connections and hands back whatever it returns -- similar
        // shape to Rust's `pool.get()?.query(...)` with a connection
        // borrowed from a pool, or Python's `with pool.connection() as
        // conn:`, except here it's a closure instead of a context manager.
        try dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS rowCount, MAX(rowid) AS maxRowID FROM idCatalogItem"
            )!

            let rowCount: Int = row["rowCount"]
            // MAX(rowid) over zero rows is SQL NULL, so this column has
            // to be read as an optional (`Int?`, Swift's equivalent of
            // Rust's `Option<i64>` or Python's `Optional[int]`) and
            // defaulted -- reading it as a plain `Int` would crash on an
            // empty table.
            let maxRowID: Int? = row["maxRowID"]

            return CatalogExtent(rowCount: rowCount, maxRowID: maxRowID ?? 0)
        }
    }

    /// Counts photos matching `filter` -- the pre-flight check a script
    /// generator runs before ever writing a `.psc` file, so "this filter
    /// only matches 340 photos" surfaces immediately instead of after
    /// opening Photo Supreme and running a script that comes up short.
    func matchingItemCount(for filter: SampleFilter) throws -> Int {
        try dbPool.read { db in
            // `SQLRequest<Int>` + string interpolation here is GRDB's
            // `SQL` mechanism, not raw string concatenation: every
            // `\(...)` interpolation of a value (an Int, an array of
            // GUIDs, or another SQL fragment) is captured as a
            // bound parameter under the hood, the same protection Rust's
            // `sqlx::query!` or a parameterized query in Python's `sqlite3`
            // module gives you -- values interpolated this way can't
            // become SQL syntax, unlike plain `"... WHERE x = \(value)"`
            // string building.
            let request: SQLRequest<Int> = "SELECT COUNT(*) FROM idCatalogItem WHERE \(Self.predicate(for: filter))"
            return try request.fetchOne(db) ?? 0
        }
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
