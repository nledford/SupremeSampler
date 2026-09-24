import Foundation

/// Helpers for SQL `LIKE ... ESCAPE '\'` patterns built from user text.
/// A caseless `enum` is Swift's idiom for a namespace of static functions
/// -- like a Rust module, or a Python module of plain functions -- since
/// it can't be instantiated.
enum LikePattern {
    /// `text` with `\`, `%` and `_` escaped, so a `LIKE` pattern built
    /// from it (with `ESCAPE '\'`) matches it literally. `_` matters most:
    /// real file and keyword names are full of it, and unescaped it
    /// matches any one character.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
