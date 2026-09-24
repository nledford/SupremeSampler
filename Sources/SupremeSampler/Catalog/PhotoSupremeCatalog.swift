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

    /// Lists the full category/keyword tree -- the data source for a
    /// hierarchical category picker in the UI. Fetches `idPropCategory`
    /// (the roots) and `idProp` (everything else, each linked to its
    /// parent via `ParentGUID`) as two flat queries, then builds the
    /// tree in pure Swift via `CatalogPropNode.buildTree` -- see that
    /// function's doc comment for why (ported from a recursive SQL CTE
    /// in an earlier Rust tool, deliberately not kept as SQL recursion
    /// here). Only ~189 `idProp` rows in the real catalog (per
    /// `docs/schema.md`), so fetching everything flat and building the
    /// tree in memory is cheap; no pagination needed.
    ///
    /// Excludes `idPropCategory` rows whose GUID uses the brace-wrapped
    /// `{XXXXXXXX-XXXX-...}` form (Photo Supreme's own built-in
    /// categories) rather than the plain 32-char hex form every user-
    /// created category/prop uses -- confirmed against the real catalog
    /// and by the user directly that the built-ins are deliberately
    /// unused here, the same filter an earlier Rust tool applied for the
    /// same reason.
    func listPropTree() async throws -> [CatalogPropNode] {
        try await dbPool.read { db in
            let categories = try Row.fetchAll(
                db,
                sql: """
                    SELECT GUID, CategoryName FROM idPropCategory
                    WHERE GUID NOT LIKE '{%'
                    """
            ).map { (guid: $0["GUID"] as String, name: $0["CategoryName"] as String) }

            // `ParentGUID` is documented as always present for a real
            // idProp row (docs/schema.md: every prop's parent is either
            // another prop or an idPropCategory) -- read as `String?`
            // and skip via `compactMap` rather than trap on an
            // unexpected NULL, the same defensive stance taken for
            // `MAX(rowid)` elsewhere in this type.
            let props = try Row.fetchAll(db, sql: "SELECT GUID, ParentGUID, PropName FROM idProp")
                .compactMap { row -> (guid: String, parentGUID: String, name: String)? in
                    guard let parentGUID = row["ParentGUID"] as String? else { return nil }
                    return (guid: row["GUID"], parentGUID: parentGUID, name: row["PropName"])
                }

            return CatalogPropNode.buildTree(categories: categories, props: props)
        }
    }

    /// How many photos matching `filter` each folder holds, with the
    /// folder's path -- the audit behind the folder balance preview
    /// (`FolderBalancePreview`). Folders with no matches are left out.
    /// Counts first and joins the path cache after, so the predicate
    /// only ever sees `idCatalogItem` (the cache also has a `GUID`
    /// column). A full scan, like the match count: seconds on the real
    /// catalog, so the model runs it in the background.
    func folderPhotoCounts(for filter: SampleFilter) async throws -> [FolderPhotoCount] {
        try await dbPool.read { db in
            let request: SQLRequest<Row> = """
                SELECT fp.FilePath AS path, c.photos AS photos
                FROM (
                    SELECT PathGUID, COUNT(*) AS photos FROM idCatalogItem
                    WHERE \(Self.predicate(for: filter))
                    GROUP BY PathGUID
                ) c
                LEFT JOIN idCache_FilePath fp ON fp.FilePathGUID = c.PathGUID
                """
            return try request.fetchAll(db).map { FolderPhotoCount(path: $0["path"], photos: $0["photos"]) }
        }
    }

    /// Every distinct color label with its photo count, most common first
    /// (ties by value), NULL folded into `""` ("no label"). Uses the
    /// `idLabel` index; ~0.2s on the real catalog.
    func listLabels() async throws -> [ValueCount] {
        try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT COALESCE(idLabel, '') AS label, COUNT(*) AS photos
                    FROM idCatalogItem
                    GROUP BY label
                    ORDER BY photos DESC, label
                    """
            ).map { ValueCount(value: $0["label"], count: $0["photos"]) }
        }
    }

    /// Every bookmark value in use with its photo count, in value order
    /// (they're states, not a popularity list), NULL counted as 0. Uses
    /// the `idBookmark` index.
    func listBookmarks() async throws -> [ValueCount] {
        try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT CAST(COALESCE(idBookmark, 0) AS INTEGER) AS bookmark, COUNT(*) AS photos
                    FROM idCatalogItem
                    GROUP BY bookmark
                    ORDER BY bookmark
                    """
            ).map { ValueCount(value: String($0["bookmark"] as Int), count: $0["photos"]) }
        }
    }

    /// Every distinct file type (see `FileTypeFilter`) with its photo
    /// count, most common first. `rtrim(name, <name with dots removed>)`
    /// strips everything after the last dot -- SQLite has no "last index
    /// of" -- so the extension is what follows. Scans every photo: ~4s on
    /// the real catalog, which is why the model loads this in the
    /// background.
    func listFileTypes() async throws -> [ValueCount] {
        try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT CASE WHEN instr(name, '.') = 0 THEN ''
                                ELSE lower(substr(name, length(rtrim(name, replace(name, '.', ''))) + 1))
                           END AS ext,
                           COUNT(*) AS photos
                    FROM (SELECT COALESCE(FileName, '') AS name FROM idCatalogItem)
                    GROUP BY ext
                    ORDER BY photos DESC, ext
                    """
            ).map { ValueCount(value: $0["ext"], count: $0["photos"]) }
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
    ///
    /// Mirrors `SQLPredicateText.render` rule for rule (same grouping,
    /// same COALESCE under "none of") -- see that type for the reasoning;
    /// `PredicateConsistencyTests` checks both against the same rules.
    private static func predicate(for filter: SampleFilter) -> SQL {
        groupPredicate(filter.root)
    }

    private static func rulePredicate(_ rule: FilterRule) -> SQL {
        switch rule {
        case .rating(let rating): return ratingPredicate(rating)
        case .category(let category): return categoryPredicate(category)
        case .path(let path): return pathPredicate(path)
        case .keywordPath(let keywordPath): return keywordPathPredicate(keywordPath)
        case .label(let label): return labelPredicate(label)
        case .fileType(let fileType): return fileTypePredicate(fileType)
        case .bookmark(let bookmark): return bookmarkPredicate(bookmark)
        // COALESCE: an unknown rating isn't pending deletion.
        case .pendingDeletion(let isPending): return isPending ? "COALESCE(Rating, 0) < 0" : "COALESCE(Rating, 0) >= 0"
        case .group(let group): return groupPredicate(group)
        }
    }

    /// Always parenthesized here, even at the root: unlike the script
    /// text, this SQL is never read by a person, so there's no reason to
    /// special-case the top level.
    private static func groupPredicate(_ group: RuleGroup) -> SQL {
        guard !group.rules.isEmpty else {
            switch group.match {
            case .any: return "0 = 1"
            case .all, .none: return "1 = 1"
            }
        }

        let predicates = group.rules.map(rulePredicate)
        switch group.match {
        case .all: return "(\(predicates.joined(separator: " AND ")))"
        case .any: return "(\(predicates.joined(separator: " OR ")))"
        case .none: return "NOT COALESCE((\(predicates.joined(separator: " OR "))), 0)"
        }
    }

    /// `CAST(COALESCE(idBookmark, 0) AS INTEGER)`: the column is REAL
    /// (2.0) and may be NULL, which counts as 0, "none" -- so "none of
    /// Hidden" keeps photos with no bookmark at all.
    private static func bookmarkPredicate(_ bookmark: BookmarkFilter) -> SQL {
        guard !bookmark.values.isEmpty else {
            return bookmark.mode == .any ? "0 = 1" : "1 = 1"
        }
        switch bookmark.mode {
        case .any: return "CAST(COALESCE(idBookmark, 0) AS INTEGER) IN \(bookmark.values)"
        case .none: return "CAST(COALESCE(idBookmark, 0) AS INTEGER) NOT IN \(bookmark.values)"
        }
    }

    /// Each extension is an ends-with match on the file name ("%.jpg"),
    /// which is exactly "the last extension is jpg"; "" (no extension)
    /// is a name with no dot or ending in one. `COALESCE(FileName, '')`
    /// keeps the test from ever being NULL, so "none of" can simply
    /// negate it. `LIKE` ignores A-Z case, as extensions need.
    private static func fileTypePredicate(_ fileType: FileTypeFilter) -> SQL {
        guard !fileType.extensions.isEmpty else {
            return fileType.mode == .any ? "0 = 1" : "1 = 1"
        }
        let tests = fileType.extensions.map { ext -> SQL in
            if ext.isEmpty {
                return "(instr(COALESCE(FileName, ''), '.') = 0 OR COALESCE(FileName, '') LIKE '%.')"
            }
            return "COALESCE(FileName, '') LIKE \(FileTypeFilter.likePattern(forExtension: ext)) ESCAPE '\\'"
        }
        let anyOf: SQL = "(\(tests.joined(separator: " OR ")))"
        return fileType.mode == .any ? anyOf : "NOT \(anyOf)"
    }

    /// `COALESCE(idLabel, '')` treats a NULL label as "no label" (`""`),
    /// which also keeps "none of" from dropping unlabeled photos:
    /// `NULL NOT IN (...)` is NULL, not true. An empty pick is vacuous,
    /// like an empty category list.
    private static func labelPredicate(_ label: LabelFilter) -> SQL {
        guard !label.labels.isEmpty else {
            return label.mode == .any ? "0 = 1" : "1 = 1"
        }
        switch label.mode {
        case .any: return "COALESCE(idLabel, '') IN \(label.labels)"
        case .none: return "COALESCE(idLabel, '') NOT IN \(label.labels)"
        }
    }

    /// The photo's full path is its folder (`idCache_FilePath.FilePath`,
    /// absolute with a trailing slash) joined to its `FileName`, the same
    /// expression the earlier lusia tool's views used. Correlated per
    /// photo -- about 2s over the real catalog's millions of photos (measured
    /// 2026-09-23). Matching only the folder would be ~100x faster via an
    /// uncorrelated subquery, but would miss text that spans the folder
    /// and file name ("2019/IMG_"). `ESCAPE '\'` makes `%` and `_` in
    /// the user's text literal (see `PathFilter.likePattern`).
    private static func pathPredicate(_ path: PathFilter) -> SQL {
        // EXISTS is never NULL, so negating it is a plain NOT.
        let negation: SQL = path.negated ? "NOT " : ""
        return """
        \(negation)EXISTS (
            SELECT 1 FROM idCache_FilePath fp
            WHERE fp.FilePathGUID = idCatalogItem.PathGUID
              AND (fp.FilePath || idCatalogItem.FileName) LIKE \(path.likePattern) ESCAPE '\\'
        )
        """
    }

    /// Photos with (or, negated, without) a keyword whose path matches.
    /// Uncorrelated like `photosWithAnyPropSubquery`, so it's driven from
    /// the assignment table's index; the path query itself runs once and
    /// is tiny (189 keywords on the real catalog, 2026-09-24). Empty text
    /// is always true, both ways -- see `KeywordPathFilter`.
    private static func keywordPathPredicate(_ keywordPath: KeywordPathFilter) -> SQL {
        guard !keywordPath.text.isEmpty else { return "1 = 1" }
        let membership: SQL = keywordPath.negated ? "NOT IN" : "IN"
        return """
        idCatalogItem.GUID \(membership) (
            SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d
            WHERE d.CatalogItemGUID IS NOT NULL
              AND d.GUID IN (
                \(sql: KeywordPathFilter.keywordPathsQuery)
                WHERE \(sql: keywordPath.likeSubject) LIKE \(keywordPath.likePattern) ESCAPE '\\'
              )
        )
        """
    }

    private static func ratingPredicate(_ rating: RatingFilter) -> SQL {
        switch rating {
        case .exactly(let value):
            return "Rating = \(value)"
        case .atLeast(let value):
            return "Rating >= \(value)"
        case .atMost(let value):
            return "Rating <= \(value)"
        case .isNot(let value):
            // `IS NOT` is SQLite's NULL-safe "not equal": NULL IS NOT 5 is
            // true, where NULL <> 5 would be NULL (no match).
            return "Rating IS NOT \(value)"
        }
    }

    /// `idCatalogItemDefinition` is the many-to-many join table between
    /// photos and props (categories/keywords); see `docs/relationships.md`.
    /// Each mode below tests the photo's GUID for membership in the set
    /// of photos carrying some prop from a list.
    private static func categoryPredicate(_ category: CategoryFilter) -> SQL {
        guard !category.branches.isEmpty else {
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
            return "idCatalogItem.GUID IN \(photosWithAnyPropSubquery(category.allPropGUIDs))"
        case .none:
            return "idCatalogItem.GUID NOT IN \(photosWithAnyPropSubquery(category.allPropGUIDs))"
        case .all:
            // One membership test per branch: the photo needs *some*
            // keyword from each selected branch, not every keyword within
            // a branch. `SQL` values join like strings but stay
            // parameterized.
            let perBranch = category.branches.map { branch -> SQL in
                "idCatalogItem.GUID IN \(photosWithAnyPropSubquery(branch.propGUIDs))"
            }
            return "(\(perBranch.joined(separator: " AND ")))"
        }
    }

    /// The GUIDs of photos carrying any of `propGUIDs`.
    ///
    /// Deliberately an uncorrelated `IN (SELECT ...)` rather than a
    /// correlated `EXISTS (... WHERE d.CatalogItemGUID = idCatalogItem.GUID)`.
    /// The correlated form scans all millions of photos and probes the index
    /// once per photo per GUID, so its cost grows with the list length --
    /// which a whole branch makes long. Measured on the real catalog
    /// (2026-09-23) with multi-keyword lists: 15.7s -> 0.23s and 10.6s ->
    /// 1.1s, same counts. This form is driven from
    /// `idCatalogItemDefinition`'s index on `GUID` instead.
    ///
    /// `IS NOT NULL` because the real schema doesn't declare
    /// `CatalogItemGUID` NOT NULL, and a single NULL in a `NOT IN` list
    /// makes the test unknown for every row -- "none of" would silently
    /// match nothing.
    private static func photosWithAnyPropSubquery(_ propGUIDs: [String]) -> SQL {
        """
        (
            SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d
            WHERE d.GUID IN \(propGUIDs)
              AND d.CatalogItemGUID IS NOT NULL
        )
        """
    }
}
