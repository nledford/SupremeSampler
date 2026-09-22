import Foundation

/// The catalog operations `SampleBuilderModel` depends on -- a narrow
/// "port" (in the hexagonal-architecture sense: the app-facing
/// boundary, as opposed to `PhotoSupremeCatalog`, the concrete
/// "adapter" that actually speaks SQLite) rather than a concrete
/// dependency on `PhotoSupremeCatalog` itself.
///
/// The payoff: tests can substitute a fake conforming to this protocol
/// instead of opening a real SQLite file, which matters most for
/// timing-sensitive behavior (see `SampleBuilderModelTests`'
/// stale-request test) that would be impractical to provoke reliably
/// against a real, fast query -- a fake can be given an artificial delay
/// on demand; a real file mostly can't.
protocol SampleBuilderCatalog: Sendable {
    func listPropTree() async throws -> [CatalogPropNode]
    func matchingItemCount(for filter: SampleFilter) async throws -> Int
}

extension PhotoSupremeCatalog: SampleBuilderCatalog {}
