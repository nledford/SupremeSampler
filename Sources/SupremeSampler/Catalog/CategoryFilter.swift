import Foundation

/// How a set of selected category branches must relate to a photo's
/// assigned props (rows in `idCatalogItemDefinition`; see
/// `docs/relationships.md`, "How a photo has a category or keyword").
///
/// - `any`: the photo has at least one prop from any selected branch.
/// - `all`: the photo has at least one prop from *every* selected branch.
/// - `none`: the photo has no prop from any selected branch.
///
/// `Hashable` (in addition to `Equatable`) so SwiftUI's `Picker` can use
/// cases of this enum directly as selection tags -- Picker's selection
/// binding requires `Hashable`, the same requirement Rust's `HashMap`
/// key or a JS `Map` key would have.
enum CategoryMatchMode: Equatable, Hashable {
    case any
    case all
    case none
}

/// One selected node in the category tree together with everything
/// beneath it. Selecting "Pines" in the picker means "Pines or any of its
/// subcategories", so a photo tagged only "Tall Pines" counts. That
/// matters on the real catalog: photos are almost never tagged with a
/// parent keyword directly, and never with a top-level category.
///
/// `propGUIDs` always contains `rootGUID` itself and is sorted, so equal
/// selections produce equal values (and identical generated scripts).
struct CategoryBranch: Equatable {
    let rootGUID: String
    let propGUIDs: [String]

    /// Turns the picker's selected node GUIDs into one branch per
    /// selection, sorted by root GUID. A GUID not found in `tree` (e.g.
    /// left over from a different catalog) becomes a single-keyword
    /// branch rather than being dropped silently.
    static func resolve(selectedGUIDs: Set<String>, in tree: [CatalogPropNode]) -> [CategoryBranch] {
        var nodesByGUID: [String: CatalogPropNode] = [:]
        func index(_ node: CatalogPropNode) {
            nodesByGUID[node.guid] = node
            node.children.forEach(index)
        }
        tree.forEach(index)

        return selectedGUIDs.sorted().map { guid in
            let propGUIDs = nodesByGUID[guid]?.subtreeGUIDs ?? [guid]
            return CategoryBranch(rootGUID: guid, propGUIDs: propGUIDs.sorted())
        }
    }
}

/// A constraint on which categories/keywords a photo must (or must not)
/// have. Prop GUIDs are `idProp.GUID` values -- a category, a keyword,
/// or any other node in Photo Supreme's prop tree are all just rows in
/// the same table (see `docs/schema.md`, "idProp: keyword/category
/// tree"); this type doesn't distinguish between them. Like
/// `RatingFilter`, it carries no SQL of its own.
struct CategoryFilter: Equatable {
    let branches: [CategoryBranch]
    let mode: CategoryMatchMode

    init(branches: [CategoryBranch], mode: CategoryMatchMode) {
        self.branches = branches
        self.mode = mode
    }

    /// Each GUID as its own branch with no descendants -- for callers
    /// that already have exact keyword GUIDs rather than a tree
    /// selection. The rule builder always goes through
    /// `CategoryBranch.resolve` instead, so subcategories are included.
    init(propGUIDs: [String], mode: CategoryMatchMode) {
        self.init(
            branches: propGUIDs.map { CategoryBranch(rootGUID: $0, propGUIDs: [$0]) },
            mode: mode
        )
    }

    /// Every prop GUID across all branches, deduplicated and sorted --
    /// what `any`/`none` test against, since for those modes it makes no
    /// difference which branch a keyword came from.
    var allPropGUIDs: [String] {
        Array(Set(branches.flatMap(\.propGUIDs))).sorted()
    }
}
