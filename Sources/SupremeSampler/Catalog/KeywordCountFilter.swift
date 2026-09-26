import Foundation

/// A constraint on how many keywords a photo has: the distinct nodes of
/// the custom keyword trees assigned to it -- the same keywords the
/// Keyword field's tree picks and path tests see, so built-in `{...}`
/// categories and anything past `CatalogPropNode.maxDepth` don't count.
/// A keyword's ancestors aren't added: a photo tagged only
/// `Nature\Trees\Oak` has one keyword.
///
/// "Keyword is empty" is `.exactly(0)`. On the real catalog this is the
/// same set of photos the earlier lusia tool treated as unlabeled (no
/// `idCatalogItemDefinition` row at all): every assignment there was a
/// custom keyword (checked 2026-09-26). Like `RatingFilter`, the cases
/// are the rule's own; unlike a rating, a count is never unknown.
enum KeywordCountFilter: Equatable {
    case exactly(Int)
    case atLeast(Int)
    case atMost(Int)
    case isNot(Int)

    /// The Keyword field's "is empty" and "is not empty".
    static let isEmpty = KeywordCountFilter.exactly(0)
    static let isNotEmpty = KeywordCountFilter.atLeast(1)

    func matches(count: Int) -> Bool {
        switch self {
        case .exactly(let n): return count == n
        case .atLeast(let n): return count >= n
        case .atMost(let n): return count <= n
        case .isNot(let n): return count != n
        }
    }

    /// Whether a photo with no keywords matches. Such a photo has no
    /// assignment rows, so SQL grouped over assignments never sees it;
    /// `photoGUIDTest` reaches it by exclusion when this is true.
    var matchesZero: Bool { matches(count: 0) }
}

// The SQL both predicate renderers share. It holds no user text -- only
// an integer -- so there's no binding-vs-literal difference between them
// (the same reasoning as `KeywordPathFilter.keywordPathsQuery`).
extension KeywordCountFilter {
    /// The SQL comparison on a photo's grouped assignments.
    private var countCondition: String {
        let count = "COUNT(DISTINCT d.GUID)"
        switch self {
        case .exactly(let n): return "\(count) = \(n)"
        case .atLeast(let n): return "\(count) >= \(n)"
        case .atMost(let n): return "\(count) <= \(n)"
        case .isNot(let n): return "\(count) <> \(n)"
        }
    }

    /// A boolean test on `idCatalogItem.GUID`. Uncorrelated, grouped over
    /// the assignment table: ~1.4-3s on the real catalog, where the same
    /// count as a correlated per-photo subquery took ~100s (2026-09-26).
    ///
    /// Photos with keywords are grouped and counted. When zero keywords
    /// fails the rule, the photo must be among those passing (`IN`); when
    /// zero passes, it must not be among those failing (`NOT IN`), which
    /// also lets in every photo with no keywords at all.
    var photoGUIDTest: String {
        let membership = matchesZero ? "NOT IN" : "IN"
        let having = matchesZero ? "NOT (\(countCondition))" : countCondition
        return "idCatalogItem.GUID \(membership) (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d"
            + " WHERE d.CatalogItemGUID IS NOT NULL AND d.GUID IN (" + KeywordPathFilter.keywordPathsQuery + ")"
            + " GROUP BY d.CatalogItemGUID HAVING \(having))"
    }
}
