import GRDB
import XCTest

@testable import SupremeSampler

/// `SQLPredicateText` (plain-text SQL, for generated `.psc` scripts) and
/// `PhotoSupremeCatalog`'s private predicate builder (GRDB-parameterized
/// SQL, for live queries) are two independent implementations of the
/// same filtering rules -- see `SQLPredicateText`'s doc comment for why
/// they're kept separate rather than unified. Swift's exhaustive
/// `switch` catches one class of drift between them for free (a new
/// `RatingFilter`/`CategoryMatchMode` case left unhandled in either file
/// is a compile error), but not a *semantic* change to an existing case
/// made in one file and not the other.
///
/// This file closes that gap empirically: for a range of filters, it
/// runs `SQLPredicateText`'s rendered SQL as a raw query against a
/// fixture -- the same thing a generated script would do -- and asserts
/// the resulting count matches `PhotoSupremeCatalog.matchingItemCount`
/// exactly. If the two implementations ever disagree about which rows a
/// filter matches, this fails; nothing else in the test suite would
/// catch that, since `SQLPredicateTextTests` and `PhotoSupremeCatalogTests`
/// each only check their own implementation in isolation.
final class PredicateConsistencyTests: XCTestCase {
    private var fixturePath: String!

    override func setUpWithError() throws {
        fixturePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: fixturePath)
    }

    private struct FixtureItem {
        let guid: String
        let rating: Int?
        let propGUIDs: [String]
        var path: String? = nil
        var label: String? = ""

        /// Full file path: folder (with trailing slash) plus file name.
        var fullPath: String { path ?? "/Volumes/Test/photos/\(guid).jpg" }
    }

    private func makeFixture(_ items: [FixtureItem]) throws {
        let dbQueue = try DatabaseQueue(path: fixturePath)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(
                sql: """
                    CREATE TABLE idCatalogItem (
                        GUID TEXT PRIMARY KEY,
                        Rating INTEGER,
                        PathGUID TEXT,
                        FileName TEXT,
                        idLabel TEXT
                    )
                    """)
            // The real catalog's absolute folder paths (trailing slash,
            // volume mount included), keyed by the photo's PathGUID.
            try db.execute(sql: "CREATE TABLE idCache_FilePath (FilePathGUID TEXT, FilePath TEXT)")
            try db.execute(
                sql: """
                    CREATE TABLE idCatalogItemDefinition (
                        GUID TEXT,
                        CatalogItemGUID TEXT,
                        PRIMARY KEY (GUID, CatalogItemGUID)
                    )
                    """)
            // Nullable columns plus one NULL-photo row, matching what the
            // real schema permits: guards both renderers against the
            // `NOT IN` + NULL trap.
            try db.execute(
                sql: "INSERT INTO idCatalogItemDefinition (GUID, CatalogItemGUID) VALUES ('catA', NULL)")
            for item in items {
                let fullPath = item.fullPath
                let slash = fullPath.lastIndex(of: "/")!
                let folder = String(fullPath[...slash])
                let fileName = String(fullPath[fullPath.index(after: slash)...])
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idCache_FilePath WHERE FilePathGUID = ?", arguments: [folder]) == 0 {
                    try db.execute(
                        sql: "INSERT INTO idCache_FilePath (FilePathGUID, FilePath) VALUES (?, ?)",
                        arguments: [folder, folder])
                }
                try db.execute(
                    sql: "INSERT INTO idCatalogItem (GUID, Rating, PathGUID, FileName, idLabel) VALUES (?, ?, ?, ?, ?)",
                    arguments: [item.guid, item.rating, folder, fileName, item.label]
                )
                for propGUID in item.propGUIDs {
                    try db.execute(
                        sql: "INSERT INTO idCatalogItemDefinition (GUID, CatalogItemGUID) VALUES (?, ?)",
                        arguments: [propGUID, item.guid]
                    )
                }
            }
        }
    }

    /// Runs `SQLPredicateText.render(filter)` as a raw query, the same
    /// way `RandomSampleScriptGenerator`'s output would when pasted into
    /// Photo Supreme -- deliberately bypassing GRDB's parameter binding
    /// to exercise the literal-SQL path for real, not just call the
    /// renderer and inspect the string.
    private func rawTextMatchingCount(_ filter: SampleFilter) throws -> Int {
        let dbQueue = try DatabaseQueue(path: fixturePath, configuration: {
            var config = Configuration()
            config.readonly = true
            return config
        }())
        let predicate = SQLPredicateText.render(filter) ?? "1 = 1"
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM idCatalogItem WHERE \(predicate)") ?? 0
        }
    }

    func test_givenVariousFilters_whenComparingBothImplementations_thenCountsAgree() async throws {
        try makeFixture([
            FixtureItem(guid: "none-r0", rating: 0, propGUIDs: []),
            FixtureItem(guid: "a-r2", rating: 2, propGUIDs: ["catA"]),
            FixtureItem(guid: "ab-r3", rating: 3, propGUIDs: ["catA", "catB"]),
            FixtureItem(guid: "abc-r5", rating: 5, propGUIDs: ["catA", "catB", "catC"]),
            FixtureItem(guid: "b-r5", rating: 5, propGUIDs: ["catB"]),
            // Tagged only with child keywords of the branches below.
            FixtureItem(guid: "a1-r1", rating: 1, propGUIDs: ["catA-child"]),
            FixtureItem(guid: "a1-b1-r4", rating: 4, propGUIDs: ["catA-child", "catB-child"]),
        ])
        let branchA = CategoryBranch(rootGUID: "catA", propGUIDs: ["catA", "catA-child"])
        let branchB = CategoryBranch(rootGUID: "catB", propGUIDs: ["catB", "catB-child"])
        let catalog = try PhotoSupremeCatalog(path: fixturePath)

        let filters: [SampleFilter] = [
            SampleFilter(),
            SampleFilter(rating: .exactly(5)),
            SampleFilter(rating: .atLeast(3)),
            SampleFilter(rating: .atMost(2)),
            SampleFilter(category: CategoryFilter(propGUIDs: ["catA"], mode: .any)),
            SampleFilter(category: CategoryFilter(propGUIDs: ["catA", "catB"], mode: .all)),
            SampleFilter(category: CategoryFilter(propGUIDs: ["catA"], mode: .none)),
            SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .any)),
            SampleFilter(category: CategoryFilter(propGUIDs: [], mode: .all)),
            SampleFilter(
                rating: .atLeast(3),
                category: CategoryFilter(propGUIDs: ["catB"], mode: .any)
            ),
            SampleFilter(category: CategoryFilter(branches: [branchA], mode: .any)),
            SampleFilter(category: CategoryFilter(branches: [branchA, branchB], mode: .any)),
            SampleFilter(category: CategoryFilter(branches: [branchA, branchB], mode: .all)),
            SampleFilter(category: CategoryFilter(branches: [branchA], mode: .none)),
            SampleFilter(rating: .atLeast(2), category: CategoryFilter(branches: [branchA, branchB], mode: .all)),
        ]

        for filter in filters {
            let viaGRDB = try await catalog.matchingItemCount(for: filter)
            let viaRawText = try rawTextMatchingCount(filter)
            XCTAssertEqual(
                viaGRDB, viaRawText,
                "PhotoSupremeCatalog and SQLPredicateText disagree for filter \(filter)")
        }
    }

    // MARK: - Randomized rule trees

    /// SplitMix64 -- a tiny, fixed-seed random generator, so a failing
    /// tree reproduces on every run. Swift's built-in generator can't be
    /// seeded; conforming to `RandomNumberGenerator` (a protocol, like a
    /// Rust trait) lets it drive the standard `randomElement(using:)`
    /// and `Int.random(in:using:)` APIs, the same way Rust's `rand`
    /// crate takes any `impl Rng`.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func randomRule(depth: Int, using rng: inout SeededGenerator) -> FilterRule {
        switch Int.random(in: 0..<(depth > 0 ? 5 : 4), using: &rng) {
        case 0:
            let value = Int.random(in: 0...5, using: &rng)
            return .rating([RatingFilter.exactly(value), .atLeast(value), .atMost(value)].randomElement(using: &rng)!)
        case 1:
            let guids = ["catA", "catB", "catC", "catA-child", "catB-child"]
            let branches = (0..<Int.random(in: 0...2, using: &rng)).map { _ -> CategoryBranch in
                let root = guids.randomElement(using: &rng)!
                return CategoryBranch(rootGUID: root, propGUIDs: [root, root + "-child"].sorted())
            }
            let mode = [CategoryMatchMode.any, .all, .none].randomElement(using: &rng)!
            return .category(CategoryFilter(branches: branches, mode: mode))
        case 2:
            let texts = ["", "/2019/", "/travel/", "2019/IMG_", "LE_O", "100%", "Lil’", ".PNG", "/Volumes/Test/", "x\\y"]
            let kind = [PathMatchKind.startsWith, .endsWith, .contains].randomElement(using: &rng)!
            return .path(PathFilter(kind: kind, text: texts.randomElement(using: &rng)!))
        case 3:
            let pool = ["", "Select", "選択", "Red", "O'Brien", "Missing"]
            let labels = (0..<Int.random(in: 0...3, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            let mode = [ValueMatchMode.any, .none].randomElement(using: &rng)!
            return .label(LabelFilter(labels: labels, mode: mode))
        default:
            return .group(randomGroup(depth: depth - 1, using: &rng))
        }
    }

    private func randomGroup(depth: Int, using rng: inout SeededGenerator) -> RuleGroup {
        let match = [GroupMatch.all, .any, .none].randomElement(using: &rng)!
        let rules = (0..<Int.random(in: 0...3, using: &rng)).map { _ in randomRule(depth: depth, using: &rng) }
        return RuleGroup(match: match, rules: rules)
    }

    /// The rules stated directly, in memory, with no SQL at all -- the
    /// reference both SQL renderers are checked against. A rule that
    /// can't be decided (a NULL rating) counts as not matching.
    private func oracleMatches(_ rule: FilterRule, _ item: FixtureItem) -> Bool {
        switch rule {
        case .rating(let rating):
            guard let value = item.rating else { return false }
            switch rating {
            case .exactly(let target): return value == target
            case .atLeast(let target): return value >= target
            case .atMost(let target): return value <= target
            }
        case .category(let category):
            let tags = Set(item.propGUIDs)
            let touches = { (branch: CategoryBranch) in !tags.isDisjoint(with: branch.propGUIDs) }
            switch category.mode {
            case .any: return category.branches.contains(where: touches)
            case .all: return category.branches.allSatisfy(touches)
            case .none: return !category.branches.contains(where: touches)
            }
        case .path(let path):
            // SQLite's LIKE folds case for A-Z only; so does this.
            let fullPath = asciiLowercased(item.fullPath)
            let text = asciiLowercased(path.text)
            switch path.kind {
            case .startsWith: return fullPath.hasPrefix(text)
            case .endsWith: return fullPath.hasSuffix(text)
            case .contains: return text.isEmpty || fullPath.contains(text)
            }
        case .label(let label):
            let value = item.label ?? ""
            switch label.mode {
            case .any: return label.labels.contains(value)
            case .none: return !label.labels.contains(value)
            }
        case .group(let group):
            return oracleMatches(group, item)
        }
    }

    private func asciiLowercased(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
    }

    private func oracleMatches(_ group: RuleGroup, _ item: FixtureItem) -> Bool {
        switch group.match {
        case .all: return group.rules.allSatisfy { oracleMatches($0, item) }
        case .any: return group.rules.contains { oracleMatches($0, item) }
        case .none: return !group.rules.contains { oracleMatches($0, item) }
        }
    }

    func test_givenRandomRuleTrees_whenCountingWithEitherImplementation_thenBothMatchTheReferenceRules() async throws {
        let items = [
            FixtureItem(guid: "none-r0", rating: 0, propGUIDs: []),
            FixtureItem(guid: "null-rating", rating: nil, propGUIDs: ["catA"]),
            FixtureItem(guid: "null-rating-untagged", rating: nil, propGUIDs: []),
            FixtureItem(guid: "a-r2", rating: 2, propGUIDs: ["catA"]),
            FixtureItem(guid: "ab-r3", rating: 3, propGUIDs: ["catA", "catB"]),
            FixtureItem(guid: "abc-r5", rating: 5, propGUIDs: ["catA", "catB", "catC"]),
            FixtureItem(guid: "a1-b1-r4", rating: 4, propGUIDs: ["catA-child", "catB-child"]),
            FixtureItem(guid: "c-r1", rating: 1, propGUIDs: ["catC"]),
            FixtureItem(guid: "trip", rating: 3, propGUIDs: [], path: "/Volumes/Photos/Travel/2019/IMG_1.jpg"),
            FixtureItem(guid: "trip-png", rating: nil, propGUIDs: ["catA"], path: "/Volumes/Photos/travel/2019/scan.PNG"),
            FixtureItem(guid: "under", rating: 5, propGUIDs: [], path: "/Volumes/Photos/E/LE_Photo.jpg"),
            FixtureItem(guid: "no-under", rating: 2, propGUIDs: [], path: "/Volumes/Photos/E/LEXPhoto.jpg"),
            FixtureItem(guid: "pct", rating: 0, propGUIDs: ["catB"], path: "/Volumes/Photos/100% crop/a.jpg"),
            FixtureItem(guid: "curly", rating: 4, propGUIDs: [], path: "/Volumes/Photos/Lil’ Dress/b.jpg"),
            FixtureItem(guid: "backslash", rating: 1, propGUIDs: [], path: "/Volumes/Photos/x\\y/c.jpg"),
            FixtureItem(guid: "sel", rating: 3, propGUIDs: ["catA"], label: "Select"),
            FixtureItem(guid: "sel-ja", rating: nil, propGUIDs: [], label: "選択"),
            FixtureItem(guid: "red-null-path", rating: 2, propGUIDs: ["catB"], label: "Red"),
            FixtureItem(guid: "quote", rating: 0, propGUIDs: [], label: "O'Brien"),
            FixtureItem(guid: "null-label", rating: 5, propGUIDs: [], label: nil),
        ]
        try makeFixture(items)
        let catalog = try PhotoSupremeCatalog(path: fixturePath)
        var rng = SeededGenerator(state: 20_260_923)

        for trial in 0..<500 {
            let filter = SampleFilter(root: randomGroup(depth: 3, using: &rng))
            let viaGRDB = try await catalog.matchingItemCount(for: filter)
            let viaRawText = try rawTextMatchingCount(filter)
            let expected = items.filter { oracleMatches(filter.root, $0) }.count
            XCTAssertEqual(viaGRDB, expected, "trial \(trial): PhotoSupremeCatalog is wrong for \(filter)")
            XCTAssertEqual(viaRawText, expected, "trial \(trial): SQLPredicateText is wrong for \(filter)")
        }
    }
}
