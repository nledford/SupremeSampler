import GRDB
import XCTest

@testable import SupremeSampler

/// Regression: running the test suite used to overwrite the real app's
/// remembered catalog path with a deleted temp fixture, so the next
/// launch fell back to the picker. The test bundle runs inside the app
/// process and shares its `UserDefaults` domain, and most tests built
/// `SampleBuilderModel()` -- which silently defaulted to the real,
/// `UserDefaults`-backed store. That default no longer exists; this
/// guards the `forTesting()` helper every test now uses.
@MainActor
final class SavedCatalogPathIsolationTests: XCTestCase {
    private static let savedPathKey = "recentCatalogPath"
    private static let savedSessionKey = "recentSession"

    private var fixturePath: String!
    private var realSavedPathBefore: String?
    private var realSavedSessionBefore: Data?

    override func setUpWithError() throws {
        realSavedPathBefore = UserDefaults.standard.string(forKey: Self.savedPathKey)
        realSavedSessionBefore = UserDefaults.standard.data(forKey: Self.savedSessionKey)

        fixturePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let dbQueue = try DatabaseQueue(path: fixturePath)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "CREATE TABLE idCatalogItem (GUID TEXT PRIMARY KEY, Rating INTEGER)")
            try db.execute(sql: "CREATE TABLE idCatalogItemDefinition (GUID TEXT, CatalogItemGUID TEXT)")
            try db.execute(sql: "CREATE TABLE idProp (GUID TEXT PRIMARY KEY, ParentGUID TEXT, PropName TEXT)")
            try db.execute(sql: "CREATE TABLE idPropCategory (GUID TEXT PRIMARY KEY, CategoryName TEXT)")
        }
    }

    override func tearDownWithError() throws {
        // If this test ever fails, put the user's real value back rather
        // than leaving the damage it detected.
        if let realSavedPathBefore {
            UserDefaults.standard.set(realSavedPathBefore, forKey: Self.savedPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedPathKey)
        }
        if let realSavedSessionBefore {
            UserDefaults.standard.set(realSavedSessionBefore, forKey: Self.savedSessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedSessionKey)
        }
        try? FileManager.default.removeItem(atPath: fixturePath)
    }

    func test_givenAModelBuiltTheWayTestsBuildIt_whenACatalogOpensSuccessfully_thenTheRealAppsSavedPathIsUntouched() async {
        let model = SampleBuilderModel.forTesting()

        model.openCatalog(at: fixturePath)
        await model.waitForPendingCatalogOpenForTesting()

        XCTAssertEqual(model.catalogPath, fixturePath, "precondition: the open must succeed to reach savePath")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.savedPathKey), realSavedPathBefore)
    }

    func test_givenAModelBuiltTheWayTestsBuildIt_whenEditingRulesOnAnOpenCatalog_thenTheRealAppsSavedSessionIsUntouched() async {
        let model = SampleBuilderModel.forTesting()
        model.openCatalog(at: fixturePath)
        await model.waitForPendingCatalogOpenForTesting()

        model.rules.add(.rating)
        model.sampleSize = 42

        XCTAssertEqual(UserDefaults.standard.data(forKey: Self.savedSessionKey), realSavedSessionBefore)
    }
}
