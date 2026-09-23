import Foundation

/// A constraint on `idCatalogItem.Rating` (0 = unrated; see
/// `~/Pictures/Photo Supreme/docs/schema.md`).
///
/// Deliberately just these three comparisons for now (YAGNI) -- matches
/// what Lightroom's own rating rule offers ("is" / "is greater than or
/// equal to" / "is less than or equal to"). This type carries no SQL
/// knowledge of its own: turning it into a WHERE-clause fragment is
/// `PhotoSupremeCatalog`'s job (the repository/infrastructure layer),
/// not this one's -- keeps the domain model persistence-ignorant, the
/// same reasoning a Rust crate would use to keep a `domain` module free
/// of `rusqlite` imports.
enum RatingFilter: Equatable {
    case exactly(Int)
    case atLeast(Int)
    case atMost(Int)
    /// Any rating but this one -- including an unknown (NULL) rating,
    /// which is "not 5" as much as 0 is. The only comparison an unknown
    /// rating satisfies.
    case isNot(Int)
}
