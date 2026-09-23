import Foundation

/// The SQL a generated script runs to draw a folder-balanced sample (see
/// `FolderBalance`) -- one statement, so the Pascal side stays a plain
/// "open a dataset, collect the GUIDs" loop and every interpreter quirk
/// in AGENTS.md stays out of the picture.
///
/// It relies on SQLite features newer than the plain sampler's: window
/// functions (3.25), `AS MATERIALIZED` (3.35) and `sqrt` (a math
/// function, compiled in only when SQLITE_ENABLE_MATH_FUNCTIONS is set).
/// Photo Supreme's bundled `libsqlite3.0.dylib` is 3.35.5 with math
/// functions enabled (read from the library's version and compile-option
/// strings, 2026-09-23).
///
/// How it draws, step by step (each step a CTE):
/// 1. `Folders`: every folder with matching photos, its weight, and a
///    random sort key.
/// 2. `Draw`: the wanted count, and one random offset in [0, 1).
/// 3. `Running`: folders in random order with a running total of weight.
/// 4. `Quotas`: systematic sampling -- lay the folders end to end on a
///    line of length `Wanted`, each as long as its share, and put a mark
///    at `Offset`, `Offset + 1`, `Offset + 2`, ... A folder gets one
///    photo per mark inside it: the floor or ceiling of its share, and a
///    folder with share 0.3 is picked with probability exactly 0.3.
/// 5. The outer query numbers each picked folder's matching photos in
///    random order and keeps the first `Quota` of them.
///
/// A folder with fewer matching photos than its quota gives all it has,
/// so the result can come up short; the script tops that up with a plain
/// random draw.
///
/// `MATERIALIZED` makes SQLite compute each CTE once. Without it,
/// SQLite may inline a CTE into every place it is used, and each copy
/// would call `random()` afresh -- a folder's sort key or the offset
/// could differ between two references to it.
enum FolderBalanceSQL {
    /// The query as two halves around the wanted count, so the script
    /// can splice its `ACount` parameter in between (`'...' +
    /// IntToStr(ACount) + '...'`).
    static func sampleParts(predicate: String?, balance: FolderBalance) -> (beforeCount: String, afterCount: String) {
        let filterWhere = predicate.map { " WHERE " + $0 } ?? ""
        let filterAnd = predicate.map { " AND " + $0 } ?? ""
        let before =
            "WITH Folders AS MATERIALIZED (SELECT PathGUID AS FolderGUID, \(weight(balance, photoCount: "COUNT(*)")) AS Weight, "
            + "random() AS SortKey FROM idCatalogItem\(filterWhere) GROUP BY PathGUID), "
            + "Draw AS MATERIALIZED (SELECT "
        let after =
            " AS Wanted, random() / 18446744073709551616.0 + 0.5 AS Offset), "
            + "Running AS MATERIALIZED (SELECT FolderGUID, Weight, "
            + "SUM(Weight) OVER (ORDER BY SortKey, FolderGUID ROWS UNBOUNDED PRECEDING) AS UpTo, "
            + "SUM(Weight) OVER () AS Total FROM Folders), "
            + "Quotas AS MATERIALIZED (SELECT FolderGUID, "
            + "CAST(UpTo * Wanted / Total + Offset AS INTEGER) - CAST((UpTo - Weight) * Wanted / Total + Offset AS INTEGER) AS Quota "
            + "FROM Running, Draw) "
            + "SELECT GUID FROM (SELECT idCatalogItem.GUID AS GUID, Quotas.Quota AS Quota, "
            + "ROW_NUMBER() OVER (PARTITION BY idCatalogItem.PathGUID ORDER BY random()) AS Pick "
            + "FROM Quotas JOIN idCatalogItem ON idCatalogItem.PathGUID = Quotas.FolderGUID "
            + "WHERE Quotas.Quota > 0\(filterAnd)) WHERE Pick <= Quota"
        return (before, after)
    }

    /// The whole query for a fixed count -- what the script's text
    /// becomes once `ACount` is known.
    static func sample(predicate: String?, balance: FolderBalance, wantedCount: Int) -> String {
        let parts = sampleParts(predicate: predicate, balance: balance)
        return parts.beforeCount + String(wantedCount) + parts.afterCount
    }

    /// `FolderBalance.weight` as SQL over the photo-count expression
    /// `photoCount`. Always REAL: an integer weight would make the
    /// `UpTo * Wanted / Total` division above an integer division.
    /// (`CAST(... AS INTEGER)` there is a floor, since nothing is
    /// negative -- SQLite's `floor` is itself a math function.)
    static func weight(_ balance: FolderBalance, photoCount: String) -> String {
        switch balance {
        case .off: return "CAST(\(photoCount) AS REAL)"
        case .balanced: return "sqrt(\(photoCount))"
        case .equal: return "1.0"
        }
    }
}
