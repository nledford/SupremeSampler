import Foundation

/// Renders a `SampleFilter` as plain SQL boolean-expression text -- no
/// `WHERE`/`AND` keyword prefix, no bound parameters -- for embedding
/// into a generated `.psc` script's SQL string. Photo Supreme's
/// interpreter builds its `CommandText` by plain string concatenation
/// (see `RandomCatalogSample.psc` and AGENTS.md); it has no bind-
/// parameter API to hand values to safely the way GRDB does, so GUID
/// values are inlined here as SQL string literals instead, each one
/// escaped at the SQL level (see `sqlStringLiteral` below).
///
/// This deliberately duplicates the *shape* of
/// `PhotoSupremeCatalog`'s private `predicate`/`ratingPredicate`/
/// `categoryPredicate` (same three rating comparisons, same three
/// category match modes, same vacuous-empty-list handling) but targets
/// a plain `String` instead of GRDB's `SQL` type. Kept as a separate
/// implementation rather than factored into one shared renderer: the
/// two have genuinely different safety models, not just a different
/// return type. `PhotoSupremeCatalog` executes its query live against a
/// real connection and gets real parameter binding from GRDB; this one
/// has to produce a self-contained literal SQL string for a standalone
/// script that will run with no query-building support of its own, days
/// or months after generation, against a catalog that's had rows
/// deleted since. Unifying them into one generic renderer would trade a
/// small amount of duplication for a shared abstraction that has to
/// serve two different consumers with different constraints -- judged
/// not worth it here, but worth a second opinion (see the review notes
/// for this change).
enum SQLPredicateText {
    /// `nil` when `filter` is unconstrained (no WHERE clause needed at
    /// all); otherwise the combined boolean expression, e.g.
    /// `"Rating >= 3"` or `"Rating >= 3 AND idCatalogItem.GUID IN (...)"`.
    static func render(_ filter: SampleFilter) -> String? {
        var clauses: [String] = []
        if let rating = filter.rating {
            clauses.append(ratingClause(rating))
        }
        if let category = filter.category {
            clauses.append(categoryClause(category))
        }
        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " AND ")
    }

    private static func ratingClause(_ rating: RatingFilter) -> String {
        switch rating {
        case .exactly(let value): return "Rating = \(value)"
        case .atLeast(let value): return "Rating >= \(value)"
        case .atMost(let value): return "Rating <= \(value)"
        }
    }

    private static func categoryClause(_ category: CategoryFilter) -> String {
        guard !category.branches.isEmpty else {
            // Same vacuous-case reasoning as PhotoSupremeCatalog's
            // categoryPredicate: "has any of zero categories" can never
            // be true; "has all/none of zero categories" is trivially
            // true for every photo.
            switch category.mode {
            case .any: return "0 = 1"
            case .all, .none: return "1 = 1"
            }
        }

        switch category.mode {
        case .any:
            return "idCatalogItem.GUID IN " + photosWithAnyPropSubquery(category.allPropGUIDs)
        case .none:
            return "idCatalogItem.GUID NOT IN " + photosWithAnyPropSubquery(category.allPropGUIDs)
        case .all:
            // One membership test per branch: the photo needs *some*
            // keyword from each branch, not every keyword within a branch.
            let perBranch = category.branches.map {
                "idCatalogItem.GUID IN " + photosWithAnyPropSubquery($0.propGUIDs)
            }
            return "(" + perBranch.joined(separator: " AND ") + ")"
        }
    }

    /// Same shape, and same reasons (index-driven, NULL-safe `NOT IN`),
    /// as `PhotoSupremeCatalog.photosWithAnyPropSubquery`.
    private static func photosWithAnyPropSubquery(_ propGUIDs: [String]) -> String {
        let guidList = propGUIDs.map(sqlStringLiteral).joined(separator: ", ")
        return "(SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d "
            + "WHERE d.GUID IN (\(guidList)) AND d.CatalogItemGUID IS NOT NULL)"
    }

    /// SQL-level string-literal escaping for one GUID value -- distinct
    /// from, and applied *before*, `PascalStringLiteral`'s escaping when
    /// this text later gets embedded in a `.psc` file by
    /// `RandomSampleScriptGenerator`. The generated script contains a
    /// SQL string nested inside a Pascal string, so each layer needs its
    /// own quote-doubling pass, applied from the inside out. SQL and
    /// Pascal both happen to escape `'` the same way (by doubling it),
    /// which is why this looks identical to `PascalStringLiteral.escape`
    /// -- that's a coincidence of the two languages agreeing, not a
    /// reason to share one implementation between two different escaping
    /// *concerns*.
    private static func sqlStringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
