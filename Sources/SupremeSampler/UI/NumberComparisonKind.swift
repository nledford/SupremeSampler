import Foundation

/// The comparison in a numeric rule row: "Rating [comparison] [n stars]"
/// or "Keyword count [comparison] [n keywords]".
///
/// A separate, UI-facing type from `RatingFilter`/`KeywordCountFilter` on
/// purpose: their cases each carry an `Int` (`.atLeast(4)`), but
/// SwiftUI's `Picker` needs a plain value to bind its selection to --
/// closer to an HTML `<select>`'s options needing a flat list of
/// strings/values, not a Rust-style enum-with-payload. This type
/// captures only the *shape* of the choice; each rule's draft combines
/// it with a separate stored value to build the real filter.
enum NumberComparisonKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case exactly = "is"
    case atLeast = "is at least"
    case atMost = "is at most"
    case isNot = "is not"

    // Saved by case name, not by `rawValue` (the menu label): renaming a
    // label must not make saved sessions unreadable (see `CaseNameCoding`).
    init(from decoder: Decoder) throws { self = try CaseNameCoding.decode(Self.self, from: decoder) }
    func encode(to encoder: Encoder) throws { try CaseNameCoding.encode(self, to: encoder) }

    var id: String { rawValue }
}
