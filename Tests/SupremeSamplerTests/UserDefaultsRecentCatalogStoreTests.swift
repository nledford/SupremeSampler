import XCTest

@testable import SupremeSampler

final class UserDefaultsRecentCatalogStoreTests: XCTestCase {
    // A private, isolated UserDefaults suite per test -- never
    // `UserDefaults.standard`, which would both pollute the real app's
    // saved state and risk a leftover value from a previous real run
    // making a test flaky. Same idea as Python's `tempfile` or Rust's
    // `tempfile::NamedTempFile` for a file, just for UserDefaults'
    // key-value store instead.
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "UserDefaultsRecentCatalogStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_givenNothingSaved_whenLoading_thenReturnsNil() {
        let store = UserDefaultsRecentCatalogStore(defaults: defaults)
        XCTAssertNil(store.loadPath())
    }

    func test_givenPathSaved_whenLoading_thenReturnsThatPath() {
        let store = UserDefaultsRecentCatalogStore(defaults: defaults)

        store.savePath("/Users/someone/Pictures/Photo Supreme/catalog.cat.db")

        XCTAssertEqual(store.loadPath(), "/Users/someone/Pictures/Photo Supreme/catalog.cat.db")
    }

    func test_givenPathSaved_whenSavingNil_thenClearsIt() {
        let store = UserDefaultsRecentCatalogStore(defaults: defaults)
        store.savePath("/some/path.cat.db")

        store.savePath(nil)

        XCTAssertNil(store.loadPath())
    }

    func test_givenPathSaved_whenSavingADifferentPath_thenOverwritesIt() {
        let store = UserDefaultsRecentCatalogStore(defaults: defaults)
        store.savePath("/first/path.cat.db")

        store.savePath("/second/path.cat.db")

        XCTAssertEqual(store.loadPath(), "/second/path.cat.db")
    }
}

extension UserDefaultsRecentCatalogStoreTests {
    func test_givenASessionSaved_whenLoading_thenReturnsTheSameBytesAndNilClearsThem() {
        let store = UserDefaultsRecentCatalogStore(defaults: defaults)
        XCTAssertNil(store.loadSession())

        store.saveSession(Data("{}".utf8))
        XCTAssertEqual(store.loadSession(), Data("{}".utf8))

        store.saveSession(nil)
        XCTAssertNil(store.loadSession())
    }
}
