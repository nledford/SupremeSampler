import Foundation

/// Renders a `SampleFilter` as plain SQL boolean-expression text -- no
/// `WHERE`/`AND` keyword prefix, no bound parameters -- for embedding
/// into a generated `.psc` script's SQL string. Photo Supreme's
/// interpreter builds its `CommandText` by plain string concatenation
/// (see `RandomCatalogSample.psc` and AGENTS.md); it has no bind-
/// parameter API to hand values to safely the way GRDB does, so GUID
/// values are inlined here as SQL string literals instead, each one
/// escaped at the SQL level (see `SQLStringLiteral`).
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
    ///
    /// A top-level "all of" group renders bare (`a AND b`), unchanged
    /// from before groups existed. Every other group renders
    /// self-delimited -- `(a OR b)`, `NOT COALESCE((a OR b), 0)` -- so
    /// the whole predicate can follow `rowid IN (...) AND` in the
    /// generated sampling query without an OR escaping.
    static func render(_ filter: SampleFilter) -> String? {
        guard !filter.isUnconstrained else { return nil }
        return groupClause(filter.root, isRoot: true)
    }

    private static func ruleClause(_ rule: FilterRule) -> String {
        switch rule {
        case .rating(let rating): return ratingClause(rating)
        case .category(let category): return categoryClause(category)
        case .path(let path): return pathClause(path)
        case .label(let label): return labelClause(label)
        case .fileType(let fileType): return fileTypeClause(fileType)
        case .group(let group): return groupClause(group, isRoot: false)
        }
    }

    private static func groupClause(_ group: RuleGroup, isRoot: Bool) -> String {
        guard !group.rules.isEmpty else {
            // Vacuous: "all/none of nothing" is true, "any of nothing" false.
            switch group.match {
            case .any: return "0 = 1"
            case .all, .none: return "1 = 1"
            }
        }

        let clauses = group.rules.map(ruleClause)
        switch group.match {
        case .all:
            let joined = clauses.joined(separator: " AND ")
            return isRoot ? joined : "(" + joined + ")"
        case .any:
            return "(" + clauses.joined(separator: " OR ") + ")"
        case .none:
            // COALESCE turns an undecidable (NULL) result into "didn't
            // match" *before* negating; a plain NOT would leave it NULL,
            // silently excluding the photo from both sides.
            return "NOT COALESCE((" + clauses.joined(separator: " OR ") + "), 0)"
        }
    }

    /// Same shape and reasoning as `PhotoSupremeCatalog.fileTypePredicate`.
    private static func fileTypeClause(_ fileType: FileTypeFilter) -> String {
        guard !fileType.extensions.isEmpty else {
            return fileType.mode == .any ? "0 = 1" : "1 = 1"
        }
        let tests = fileType.extensions.map { ext -> String in
            if ext.isEmpty {
                return "(instr(COALESCE(FileName, ''), '.') = 0 OR COALESCE(FileName, '') LIKE '%.')"
            }
            let pattern = SQLStringLiteral.render(FileTypeFilter.likePattern(forExtension: ext))
            return "COALESCE(FileName, '') LIKE \(pattern) ESCAPE '\\'"
        }
        let anyOf = "(" + tests.joined(separator: " OR ") + ")"
        return fileType.mode == .any ? anyOf : "NOT " + anyOf
    }

    /// Same shape and reasoning as `PhotoSupremeCatalog.labelPredicate`.
    private static func labelClause(_ label: LabelFilter) -> String {
        guard !label.labels.isEmpty else {
            return label.mode == .any ? "0 = 1" : "1 = 1"
        }
        let list = label.labels.map(SQLStringLiteral.render).joined(separator: ", ")
        return "COALESCE(idLabel, '') " + (label.mode == .any ? "IN" : "NOT IN") + " (" + list + ")"
    }

    /// Same shape as `PhotoSupremeCatalog.pathPredicate`.
    private static func pathClause(_ path: PathFilter) -> String {
        (path.negated ? "NOT " : "") + "EXISTS (SELECT 1 FROM idCache_FilePath fp WHERE fp.FilePathGUID = idCatalogItem.PathGUID"
            + " AND (fp.FilePath || idCatalogItem.FileName) LIKE \(SQLStringLiteral.render(path.likePattern))"
            + " ESCAPE '\\')"
    }

    private static func ratingClause(_ rating: RatingFilter) -> String {
        switch rating {
        case .exactly(let value): return "Rating = \(value)"
        case .atLeast(let value): return "Rating >= \(value)"
        case .atMost(let value): return "Rating <= \(value)"
        case .isNot(let value): return "Rating IS NOT \(value)"
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
        let guidList = propGUIDs.map(SQLStringLiteral.render).joined(separator: ", ")
        return "(SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d "
            + "WHERE d.GUID IN (\(guidList)) AND d.CatalogItemGUID IS NOT NULL)"
    }
}
