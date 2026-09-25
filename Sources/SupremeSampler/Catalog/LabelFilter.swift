import Foundation

/// Whether a photo's single value (its color label, its file type) must
/// be one of a set of values or none of them. There's no "all of": a
/// photo has only one label and one file type.
enum ValueMatchMode: Equatable, Hashable, Codable {
    case any
    case none
}

/// A constraint on a photo's color label (`idCatalogItem.idLabel`).
///
/// Labels are free text in the catalog, not a fixed set of colors: the
/// real one holds values imported from other apps and languages
/// ("Select", "選択", "$$$/Bridge/Preferences/Label/Red=Select", ...),
/// so a filter names the exact stored values rather than guessing which
/// ones mean the same thing. `""` means "no label", which also covers a
/// NULL `idLabel`.
struct LabelFilter: Equatable {
    let labels: [String]
    let mode: ValueMatchMode
}

/// One distinct value found in the catalog, with how many photos have it
/// -- what a picker lists (labels today, file types next).
struct ValueCount: Equatable, Hashable, Identifiable {
    let value: String
    let count: Int

    var id: String { value }
}
