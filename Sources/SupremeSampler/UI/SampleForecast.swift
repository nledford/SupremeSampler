import Foundation

/// What the script will actually pick, given how many photos match and
/// how many were asked for. The script can't return more photos than
/// match, so a sample bigger than the match count comes up short -- and
/// does so silently in Script Studio, which is why the window says so
/// first (PRODUCT.md: the count shown and the photos picked must agree).
struct SampleForecast: Equatable {
    let matching: Int
    let requested: Int

    enum Kind: Equatable {
        /// Enough photos match to fill the sample.
        case full
        /// Some match, but fewer than requested: the script picks them all.
        case short
        /// Nothing matches: the script picks nothing.
        case empty
    }

    var kind: Kind {
        if matching == 0 { return .empty }
        return matching < requested ? .short : .full
    }

    /// How many photos the script will return.
    var expectedSize: Int { min(matching, requested) }
}
