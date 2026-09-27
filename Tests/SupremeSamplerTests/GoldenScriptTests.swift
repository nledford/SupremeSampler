import XCTest

@testable import SupremeSampler

/// Format 1, frozen: scripts saved by this version of the app, vendored
/// in `Fixtures/Format1/`, must keep reading back exactly, with the
/// settings below. Every other reading test generates its script with
/// today's generator, so on its own a change to the output (a header
/// line, the SQL shape) would pass them all while every script saved
/// earlier started opening as "hand-edited". If this fails, the output
/// changed: that's a new `ScriptFormat` (see its doc comment), not a
/// fixture to regenerate.
///
/// The keyword GUIDs are made up: the repository is public.
final class GoldenScriptTests: XCTestCase {
    struct Golden {
        let file: String
        let sampleSize: Int
        let folderBalance: FolderBalance
        let filter: SampleFilter
    }

    /// Every kind of rule, nested groups of each kind, and text needing
    /// every escape the generator uses.
    static let everyRule = SampleFilter(
        root: RuleGroup(
            match: .all,
            rules: [
                .pendingDeletion(false),
                .bookmark(BookmarkFilter(values: [5], mode: .none)),
                .rating(.atLeast(3)),
                .group(
                    RuleGroup(
                        match: .any,
                        rules: [
                            .category(
                                CategoryFilter(
                                    branches: [
                                        CategoryBranch(rootGUID: "KW-NATURE", propGUIDs: ["KW-NATURE", "KW-OAKS", "KW-PINES"])
                                    ], mode: .any)),
                            .category(CategoryFilter(propGUIDs: ["KW-CITY", "KW-PARKS"], mode: .all)),
                            .keywordPath(KeywordPathFilter(kind: .hasPart, text: "Été\\Oak", negated: false)),
                        ])),
                .group(
                    RuleGroup(
                        match: .none,
                        rules: [
                            .category(CategoryFilter(propGUIDs: ["KW-PRIVATE"], mode: .none)),
                            .path(PathFilter(kind: .contains, text: "100%_x\\y'{z}", negated: false)),
                            .keywordCount(.exactly(0)),
                        ])),
                .label(LabelFilter(labels: ["", "O'Brien", "選択"], mode: .any)),
                .fileType(FileTypeFilter(extensions: ["", "jpg", "lr_"], mode: .none)),
                .keywordCount(.atMost(4)),
                .rating(.isNot(1)),
                .path(PathFilter(kind: .endsWith, text: ".png", negated: true)),
                .keywordPath(KeywordPathFilter(kind: .startsWith, text: "Nature\\", negated: true)),
            ]))

    /// The operators `everyRule` doesn't use, so every operator's SQL is
    /// frozen too, not just every field's.
    static let everyOtherOperator = SampleFilter(
        root: RuleGroup(
            match: .all,
            rules: [
                .pendingDeletion(true),
                .rating(.atMost(2)),
                .rating(.exactly(4)),
                .keywordCount(.atLeast(2)),
                .keywordCount(.isNot(3)),
                .keywordCount(.exactly(1)),
                .path(PathFilter(kind: .startsWith, text: "/Volumes/Test/", negated: false)),
                .path(PathFilter(kind: .contains, text: "draft", negated: true)),
                .path(PathFilter(kind: .startsWith, text: "/tmp/", negated: true)),
                .path(PathFilter(kind: .endsWith, text: ".jpg", negated: false)),
                .keywordPath(KeywordPathFilter(kind: .contains, text: "tree", negated: false)),
                .keywordPath(KeywordPathFilter(kind: .contains, text: "tree", negated: true)),
                .keywordPath(KeywordPathFilter(kind: .endsWith, text: "\\Oak", negated: false)),
                .keywordPath(KeywordPathFilter(kind: .endsWith, text: "\\Oak", negated: true)),
                .keywordPath(KeywordPathFilter(kind: .hasPart, text: "Oak", negated: true)),
                .keywordPath(KeywordPathFilter(kind: .startsWith, text: "Nature", negated: false)),
                .keywordPath(KeywordPathFilter(kind: .contains, text: "", negated: false)),
                .label(LabelFilter(labels: ["Red"], mode: .none)),
                .label(LabelFilter(labels: [], mode: .any)),
                .fileType(FileTypeFilter(extensions: ["png", "webp"], mode: .any)),
                .bookmark(BookmarkFilter(values: [2, 3], mode: .any)),
                .category(
                    CategoryFilter(
                        branches: [
                            CategoryBranch(rootGUID: "KW-OAKS", propGUIDs: ["KW-OAKS", "KW-RED-OAKS"]),
                            CategoryBranch(rootGUID: "KW-PINES", propGUIDs: ["KW-PINES"]),
                        ], mode: .all)),
                .group(RuleGroup(match: .any, rules: [])),
                .group(RuleGroup(match: .none, rules: [.rating(.atLeast(5))])),
            ]))

    static let cases = [
        Golden(file: "EveryRuleOff.psc", sampleSize: 2_500, folderBalance: .off, filter: everyRule),
        Golden(file: "EveryRuleBalanced.psc", sampleSize: 1_000, folderBalance: .balanced, filter: everyRule),
        Golden(
            file: "AnyOfRootEqual.psc", sampleSize: 50, folderBalance: .equal,
            filter: SampleFilter(
                root: RuleGroup(match: .any, rules: [.rating(.exactly(5)), .keywordCount(.isNotEmpty)]))),
        Golden(file: "EveryOtherOperator.psc", sampleSize: 400, folderBalance: .off, filter: everyOtherOperator),
        // Saved before scripts were stamped with their format.
        Golden(file: "UnstampedUnfiltered.psc", sampleSize: 10_000, folderBalance: .off, filter: SampleFilter()),
    ]

    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Format1", isDirectory: true)

    func test_givenFormatOneScriptsSavedEarlier_whenRead_thenEachReadsBackExactlyWithItsSettings() throws {
        for golden in Self.cases {
            let text = try String(contentsOf: Self.folder.appendingPathComponent(golden.file), encoding: .utf8)

            guard case .read(let result) = ScriptReader.read(text) else {
                XCTFail("\(golden.file) should read")
                continue
            }
            XCTAssertTrue(
                result.isExactlyAsGenerated,
                "\(golden.file): today's format-1 output differs from the frozen file -- "
                    + "\(result.fileOnlyLines.prefix(3)) vs \(result.generatedOnlyLines.prefix(3))")
            XCTAssertEqual(result.formatVersion, 1, golden.file)
            XCTAssertEqual(result.sampleSize, golden.sampleSize, golden.file)
            XCTAssertEqual(result.folderBalance, golden.folderBalance, golden.file)
            XCTAssertEqual(
                SQLPredicateText.render(result.filter), SQLPredicateText.render(golden.filter), golden.file)
        }
    }

    func test_givenTheUnstampedFixture_thenItReallyHasNoStamp() throws {
        let text = try String(
            contentsOf: Self.folder.appendingPathComponent("UnstampedUnfiltered.psc"), encoding: .utf8)
        XCTAssertFalse(text.contains(ScriptFormats.stampPrefix))
    }
}
