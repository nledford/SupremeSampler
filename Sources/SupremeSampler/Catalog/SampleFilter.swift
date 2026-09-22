import Foundation

/// The full set of constraints for a random sample. Every non-nil field
/// must match -- AND semantics between dimensions, the same default as
/// Lightroom's Smart Collection "Match all of the following rules".
/// `nil` means "no constraint on this dimension"; `SampleFilter()` with
/// every field nil matches the whole catalog.
struct SampleFilter: Equatable {
    var rating: RatingFilter?
    var category: CategoryFilter?

    init(rating: RatingFilter? = nil, category: CategoryFilter? = nil) {
        self.rating = rating
        self.category = category
    }
}
