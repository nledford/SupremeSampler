import Foundation

/// The text on a rule row's value button: what's picked, briefly, so a
/// one-line row still says what it tests. The full list opens in a
/// popover.
enum ValueSummary {
    static let placeholder = "Choose…"

    /// "Trees", "Trees, Rivers", or "Trees, Rivers +2"; `placeholder` when
    /// nothing is picked.
    static func text(for names: [String], placeholder: String = placeholder) -> String {
        guard !names.isEmpty else { return placeholder }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    /// The names of the picked keywords, in tree order. GUIDs not in the
    /// tree (left over from another catalog) are skipped.
    static func keywordNames(for selectedGUIDs: Set<String>, in tree: [CatalogPropNode]) -> [String] {
        KeywordPath.all(in: tree).filter { selectedGUIDs.contains($0.guid) }.map(\.name)
    }

    /// The summary for a list read from the catalog: its loading state,
    /// or the picked values (sorted, then named by `name`).
    static func text(for values: CatalogValues, picked: Set<String>, name: (String) -> String) -> String {
        switch values {
        case .loading: return "Loading…"
        case .failed: return "Couldn't load"
        case .loaded: return text(for: picked.sorted().map(name))
        }
    }
}
