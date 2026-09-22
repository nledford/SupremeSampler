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
}
