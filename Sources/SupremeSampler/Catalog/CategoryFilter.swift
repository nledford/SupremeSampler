import Foundation

/// How a set of category/keyword prop GUIDs must relate to a photo's
/// assigned props (rows in `idCatalogItemDefinition`; see
/// `docs/relationships.md`, "How a photo has a category or keyword").
///
/// - `any`: the photo has at least one of the given props.
/// - `all`: the photo has every one of the given props.
/// - `none`: the photo has none of the given props.
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

/// A constraint on which categories/keywords a photo must (or must not)
/// have. `propGUIDs` are `idProp.GUID` values -- a category, a keyword,
/// or any other node in Photo Supreme's prop tree are all just rows in
/// the same table (see `docs/schema.md`, "idProp: keyword/category
/// tree"); this type doesn't distinguish between them. Like
/// `RatingFilter`, it carries no SQL of its own.
struct CategoryFilter: Equatable {
    let propGUIDs: [String]
    let mode: CategoryMatchMode
}
