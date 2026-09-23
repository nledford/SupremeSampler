import GRDB
import XCTest

@testable import SupremeSampler

/// Specifies the folder-balanced sampling query a generated script runs.
/// Each test runs the real SQL text against a small in-memory fixture --
/// the same thing Script Studio would do -- rather than checking the
/// text's shape, since what matters is which photos come back.
///
/// The fixture's four folders hold 100, 25, 4 and 1 photos. Under
/// "Balanced" their weights are 10, 5, 2 and 1 (sum 18), so a sample of
/// 18 should take 10, 5, 2 and 1 photos from them exactly: the query
/// uses systematic sampling, which gives each folder the floor or the
/// ceiling of its expected share, never more or less.
final class FolderBalanceSQLTests: XCTestCase {
    private static let folderSizes = ["big/": 100, "mid/": 25, "small/": 4, "tiny/": 1]

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE idCatalogItem (
                        GUID TEXT PRIMARY KEY, Rating INTEGER, PathGUID TEXT, FileName TEXT,
                        idLabel TEXT, idBookmark REAL
                    )
                    """)
            try db.execute(sql: "CREATE INDEX idx_fk_idCatalogItem1 ON idCatalogItem(PathGUID)")
            try db.execute(sql: "CREATE TABLE idCache_FilePath (FilePathGUID TEXT, FilePath TEXT)")
            try db.execute(sql: "CREATE TABLE idCatalogItemDefinition (GUID TEXT, CatalogItemGUID TEXT)")
            for (folder, size) in Self.folderSizes {
                try db.execute(
                    sql: "INSERT INTO idCache_FilePath VALUES (?, ?)", arguments: [folder, "/Volumes/Test/" + folder])
                for index in 0..<size {
                    // Odd-numbered photos are rated 1, the rest 0, so a
                    // rating rule halves every folder but "tiny/".
                    try db.execute(
                        sql: "INSERT INTO idCatalogItem VALUES (?, ?, ?, ?, '', 0)",
                        arguments: ["\(folder)\(index)", index % 2, folder, "IMG_\(index).jpg"])
                }
            }
        }
    }

    /// Runs the query and returns how many photos came from each folder,
    /// checking along the way that no photo came back twice.
    private func sampleByFolder(
        _ balance: FolderBalance, wanting count: Int, filter: SampleFilter = SampleFilter(),
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Int] {
        let sql = FolderBalanceSQL.sample(predicate: SQLPredicateText.render(filter), balance: balance, wantedCount: count)
        let guids = try dbQueue.read { try String.fetchAll($0, sql: sql) }
        XCTAssertEqual(Set(guids).count, guids.count, "a photo came back twice", file: file, line: line)
        return guids.reduce(into: [:]) { counts, guid in
            let folder = String(guid.prefix { $0 != "/" }) + "/"
            counts[folder, default: 0] += 1
        }
    }

    func test_givenBalanced_whenSamplingTheSumOfTheWeights_thenEachFolderGivesExactlyItsWeight() throws {
        for _ in 0..<25 {
            XCTAssertEqual(try sampleByFolder(.balanced, wanting: 18), ["big/": 10, "mid/": 5, "small/": 2, "tiny/": 1])
        }
    }

    func test_givenBalanced_whenSamplingAnyCount_thenEachFolderGivesTheFloorOrCeilingOfItsShare() throws {
        let weights = Self.folderSizes.mapValues { FolderBalance.balanced.weight(photoCount: $0) }
        let total = weights.values.reduce(0, +)
        for _ in 0..<25 {
            let counts = try sampleByFolder(.balanced, wanting: 11)
            XCTAssertEqual(counts.values.reduce(0, +), 11)
            for (folder, weight) in weights {
                let share = 11 * weight / total
                XCTAssertTrue(
                    (Int(share.rounded(.down))...Int(share.rounded(.up))).contains(counts[folder, default: 0]),
                    "\(folder) gave \(counts[folder, default: 0]) for a share of \(share)")
            }
        }
    }

    func test_givenEqual_whenSamplingFewerPhotosThanFolders_thenNoFolderGivesMoreThanOne() throws {
        for _ in 0..<25 {
            let counts = try sampleByFolder(.equal, wanting: 3)
            XCTAssertEqual(counts.count, 3)
            XCTAssertEqual(Set(counts.values), [1])
        }
    }

    func test_givenEqual_whenSamplingOnePhotoManyTimes_thenEveryFolderIsAboutEquallyLikely() throws {
        // 400 draws over 4 folders: about 100 each. The bounds are far
        // outside chance (a binomial's standard deviation here is ~9),
        // while "Off" would give "tiny/" about 3.
        var tally: [String: Int] = [:]
        for _ in 0..<400 {
            for (folder, count) in try sampleByFolder(.equal, wanting: 1) {
                tally[folder, default: 0] += count
            }
        }
        for folder in Self.folderSizes.keys {
            XCTAssertTrue((60...140).contains(tally[folder, default: 0]), "\(folder) drawn \(tally[folder, default: 0]) times")
        }
    }

    func test_givenAFilter_whenSampling_thenOnlyMatchingPhotosComeBackAndFoldersAreSizedByMatches() throws {
        // Rated-1 photos: 50, 12, 2 and 0 per folder -- "tiny/" drops out.
        let filter = SampleFilter(rating: .exactly(1))
        let guids = try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: FolderBalanceSQL.sample(predicate: SQLPredicateText.render(filter), balance: .equal, wantedCount: 3))
        }
        XCTAssertEqual(guids.count, 3)
        let ratings = try dbQueue.read { db in
            try Int.fetchAll(db, sql: "SELECT Rating FROM idCatalogItem WHERE GUID IN (\(guids.map { "'\($0)'" }.joined(separator: ",")))")
        }
        XCTAssertEqual(ratings, [1, 1, 1])
        XCTAssertFalse(guids.contains { $0.hasPrefix("tiny/") })
    }

    func test_givenAPathFilter_whenSampling_thenItsCorrelatedSubqueryStillResolves() throws {
        // The path rule refers to `idCatalogItem.PathGUID` and
        // `idCatalogItem.FileName` from inside its own subquery, so the
        // sampling query must keep the table unaliased.
        let filter = SampleFilter(root: RuleGroup(match: .all, rules: [.path(PathFilter(kind: .contains, text: "/mid/IMG_"))]))
        let counts = try sampleByFolder(.balanced, wanting: 5, filter: filter)
        XCTAssertEqual(counts, ["mid/": 5])
    }

    func test_givenMoreWantedThanAFolderHolds_whenSampling_thenTheFolderGivesAllItHasAndNoMore() throws {
        // Equal shares of 40 are 10 per folder, but "small/" and "tiny/"
        // hold 4 and 1. The query caps them; the script tops up the gap.
        let counts = try sampleByFolder(.equal, wanting: 40)
        XCTAssertEqual(counts, ["big/": 10, "mid/": 10, "small/": 4, "tiny/": 1])
    }

    func test_givenNoMatches_whenSampling_thenNothingComesBack() throws {
        XCTAssertEqual(try sampleByFolder(.balanced, wanting: 10, filter: SampleFilter(rating: .exactly(5))), [:])
    }

    func test_givenEachMode_whenSQLiteEvaluatesItsWeight_thenItAgreesWithTheDomainWeight() throws {
        for balance in FolderBalance.allCases {
            for photos in [1, 4, 25, 9_987] {
                let sqlWeight = try dbQueue.read { db in
                    try Double.fetchOne(
                        db, sql: "SELECT \(FolderBalanceSQL.weight(balance, photoCount: "c")) FROM (SELECT \(photos) AS c)")
                }
                XCTAssertEqual(sqlWeight!, balance.weight(photoCount: photos), accuracy: 1e-9, "\(balance), \(photos) photos")
            }
        }
    }
}
