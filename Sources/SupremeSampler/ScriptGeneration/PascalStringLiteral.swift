import Foundation

/// Renders a Swift `String` as a Photo Supreme (Object Pascal) string
/// literal: wrapped in single quotes, with any embedded single quote
/// doubled to escape it -- Pascal's equivalent of backslash-escaping a
/// quote in a Rust/TS/Python string literal, just using `''` instead of
/// `\'`.
///
/// A case-less `enum` here is Swift's idiom for a pure namespace of
/// static functions with no instances -- unlike `RatingFilter`, there's
/// no sum-type meaning to this `enum`; it exists only so `escape` has
/// somewhere to live without being a free function floating at file
/// scope. Closest Rust/Python/TS equivalent is a plain function in a
/// module, or a Rust type with only associated functions and no fields.
enum PascalStringLiteral {
    static func escape(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
