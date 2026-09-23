@testable import SupremeSampler

extension SampleBuilderModel {
    /// How tests build a model: with an in-memory saved-path store, never
    /// the real one (see `SavedCatalogPathIsolationTests`). A test that
    /// cares about the store's contents passes its own.
    static func forTesting(
        catalogStore: any RecentCatalogStore = InMemoryRecentCatalogStore()
    ) -> SampleBuilderModel {
        SampleBuilderModel(catalogStore: catalogStore)
    }
}
