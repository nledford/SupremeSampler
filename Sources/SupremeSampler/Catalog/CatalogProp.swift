import Foundation

/// A category/keyword node from Photo Supreme's prop tree (`idProp`;
/// see `docs/schema.md`, "idProp: keyword/category tree"). This is the
/// data a category picker in the UI lists from -- the alternative to
/// asking someone to type a 32-char hex GUID by hand.
///
/// `Identifiable` and `Hashable` here are protocols SwiftUI's list/
/// selection views expect (~ needing a key/equality function to hand a
/// React list `key` prop, or to put values in a Rust/Python/TS
/// `HashSet`/`Set`) -- conforming just means "this type knows how to
/// identify and compare itself," which `guid` already does uniquely.
struct CatalogProp: Equatable, Hashable, Identifiable {
    let guid: String
    let name: String

    var id: String { guid }
}
