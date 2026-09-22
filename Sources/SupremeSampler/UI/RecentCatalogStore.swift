import Foundation

/// Persists "which catalog file was last opened successfully", across
/// app launches. A narrow protocol "port" -- same reasoning as
/// `SampleBuilderCatalog`: `SampleBuilderModel` depends on this
/// abstraction, not on `UserDefaults` directly, so a test can substitute
/// an in-memory fake instead of touching real (or even a real-but-
/// isolated) OS-level storage for the common case, and the one test that
/// *does* want to verify the real `UserDefaults`-backed implementation
/// can do so directly and in isolation (see
/// `UserDefaultsRecentCatalogStoreTests`).
protocol RecentCatalogStore: Sendable {
    func loadPath() -> String?
    func savePath(_ path: String?)
}

/// The real implementation, backed by `UserDefaults`. A `struct`, not a
/// `class`: it has no identity of its own to protect, just a handle to
/// wherever `UserDefaults` actually keeps its data -- same reasoning as
/// `PhotoSupremeCatalog` being a struct around a `DatabasePool`.
struct UserDefaultsRecentCatalogStore: RecentCatalogStore {
    private static let key = "recentCatalogPath"

    private let defaults: UserDefaults

    /// Defaults to `.standard` for real use; tests pass an isolated
    /// suite (see `UserDefaultsRecentCatalogStoreTests`) instead of
    /// touching the user's actual saved preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPath() -> String? {
        defaults.string(forKey: Self.key)
    }

    func savePath(_ path: String?) {
        // `UserDefaults.set(nil, forKey:)` does NOT remove the key the
        // way you might expect from a dictionary -- it's documented to
        // do nothing for a nil object value, so clearing a saved path
        // needs `removeObject(forKey:)` explicitly instead.
        if let path {
            defaults.set(path, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
