import Foundation

/// A constraint on a photo's bookmark value (`idCatalogItem.idBookmark`,
/// stored as REAL: 2.0).
///
/// Photo Supreme gives these numbers no names of its own; the meanings
/// come from the earlier lusia tool, which sets them (see
/// `~/Projects/rust/lusia`, `src/domain/mod.rs`,
/// `BookmarkState`). A NULL bookmark counts as 0, "none".
struct BookmarkFilter: Equatable {
    let values: [Int]
    let mode: ValueMatchMode

    /// lusia's names for the values it uses; anything else is shown by
    /// number.
    static let lusiaNames: [Int: String] = [
        0: "None",
        2: "Curated",
        3: "Random uncurated",
        4: "Uncurated",
        5: "Hidden",
    ]

    static func displayName(for value: Int) -> String {
        lusiaNames[value] ?? "Bookmark \(value)"
    }
}
