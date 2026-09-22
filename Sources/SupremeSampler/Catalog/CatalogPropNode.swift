import Foundation

/// One node in Photo Supreme's category/keyword tree: either a top-level
/// category (from `idPropCategory`) or a nested prop (from `idProp`,
/// linked to its parent via `ParentGUID`) -- see `docs/schema.md` and
/// `docs/relationships.md`. `children` is always present (possibly
/// empty), not optional -- `childrenOrNil` below is the SwiftUI-facing
/// adapter for the one place that specifically wants `nil` instead of
/// an empty array.
struct CatalogPropNode: Equatable, Hashable, Identifiable {
    let guid: String
    let name: String
    let children: [CatalogPropNode]

    var id: String { guid }

    /// SwiftUI's `List(_:children:)`/`OutlineGroup` use `nil` vs.
    /// non-`nil` (not empty-vs-nonempty) to decide whether a row gets a
    /// disclosure triangle at all -- a leaf with `children: []` still
    /// needs to report `nil` here, or it would render with an always-
    /// empty, uselessly clickable expand arrow. This is the Swift
    /// equivalent of a tree-view library wanting `Option<Vec<Child>>`
    /// rather than `Vec<Child>` to distinguish "no children" from
    /// "not expandable" -- Rust would model the same distinction with
    /// `Option`, just spelled differently.
    var childrenOrNil: [CatalogPropNode]? {
        children.isEmpty ? nil : children
    }

    /// Builds the tree from two flat inputs -- no database access, no
    /// recursive SQL, fully synchronous and pure, which is what makes it
    /// trivially unit-testable with synthetic data. Ported from a
    /// `WITH RECURSIVE` SQL CTE in an earlier Rust tool
    /// (`~/Projects/rust/lusia`) into an equivalent
    /// in-memory tree build -- same idea (walk `idProp.ParentGUID` up to
    /// an `idPropCategory` root), different mechanism (Swift dictionary
    /// grouping instead of SQL recursion), chosen so this can be tested
    /// without modeling recursive-CTE behavior in a SQLite fixture.
    ///
    /// `categories` are the tree's roots; `props` are every other node,
    /// each identified by its own GUID and its parent's GUID (which may
    /// be a category's GUID or another prop's). A prop whose parent
    /// chain doesn't reach one of `categories` (orphaned data) is
    /// silently dropped, not surfaced at the top level -- the same
    /// behavior the recursive CTE this was ported from would have (a
    /// row whose `ParentGUID` never joins back to a root just never
    /// appears in the result).
    static func buildTree(
        categories: [(guid: String, name: String)],
        props: [(guid: String, parentGUID: String, name: String)]
    ) -> [CatalogPropNode] {
        var childrenByParentGUID: [String: [(guid: String, name: String)]] = [:]
        for prop in props {
            childrenByParentGUID[prop.parentGUID, default: []].append((prop.guid, prop.name))
        }

        func buildNode(guid: String, name: String) -> CatalogPropNode {
            let children = (childrenByParentGUID[guid] ?? [])
                .sorted { $0.name < $1.name }
                .map { buildNode(guid: $0.guid, name: $0.name) }
            return CatalogPropNode(guid: guid, name: name, children: children)
        }

        return categories
            .sorted { $0.name < $1.name }
            .map { buildNode(guid: $0.guid, name: $0.name) }
    }
}
