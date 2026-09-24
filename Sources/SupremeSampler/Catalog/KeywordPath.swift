import Foundation

/// A keyword's full name: every name from its root category down to it,
/// joined by `\` -- `Nature\Trees\Oak`. The same paths the earlier lusia
/// tool built with a recursive SQL CTE (`src/db/images.rs`), and the same
/// ones `KeywordPathFilter.keywordPathsCTE` builds for a generated script.
struct KeywordPath: Equatable {
    /// Joins a path's names. Not escaped: a name containing `\` makes its
    /// path ambiguous, in lusia's paths and in the script's alike.
    static let separator = "\\"

    let guid: String
    let text: String

    /// A path for every node in `tree`, root categories included,
    /// depth-first in the tree's (name-sorted) order. Pure, so the rule
    /// row can show which keywords a text matches without a query.
    static func all(in tree: [CatalogPropNode]) -> [KeywordPath] {
        func walk(_ node: CatalogPropNode, parentPath: String?) -> [KeywordPath] {
            let text = parentPath.map { $0 + separator + node.name } ?? node.name
            return [KeywordPath(guid: node.guid, text: text)]
                + node.children.flatMap { walk($0, parentPath: text) }
        }
        return tree.flatMap { walk($0, parentPath: nil) }
    }
}
