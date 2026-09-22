import Foundation

/// Row count and max rowid of a table, used to size random-rowid sampling
/// batches (see RandomCatalogSample.psc and AGENTS.md for why this
/// specific pair of numbers matters).
///
/// A plain value type with no identity -- like a Rust struct deriving
/// `PartialEq`, or a Python `@dataclass(frozen=True)`. `Equatable` here
/// is a protocol (~ a Rust trait) that lets `==` compare two instances
/// field-by-field; conforming just requires the struct to say so, Swift
/// synthesizes the comparison automatically for structs whose members
/// are all themselves `Equatable`.
struct CatalogExtent: Equatable {
    let rowCount: Int
    let maxRowID: Int
}
