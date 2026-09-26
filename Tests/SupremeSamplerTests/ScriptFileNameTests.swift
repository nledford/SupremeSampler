import XCTest

@testable import SupremeSampler

/// Specifies the file name the save panel suggests for a script: `Random`
/// plus a short PascalCase phrase per rule, so a folder of saved scripts
/// reads as a list of what each one samples. It's only a suggestion --
/// the save panel lets the user change it.
final class ScriptFileNameTests: XCTestCase {
    /// Keyword names by GUID, as the catalog's keyword tree provides them.
    private let names = ["oak": "Oak", "pines": "Pines", "ete": "Été", "ja": "選択", "trees": "Trees"]

    private func name(_ rules: [FilterRule], match: GroupMatch = .all, balance: FolderBalance = .off) -> String {
        ScriptFileName.suggest(
            for: SampleFilter(root: RuleGroup(match: match, rules: rules)), folderBalance: balance,
            keywordName: { self.names[$0] })
    }

    private func picks(_ guids: [String], _ mode: CategoryMatchMode) -> FilterRule {
        .category(CategoryFilter(branches: guids.map { CategoryBranch(rootGUID: $0, propGUIDs: [$0]) }, mode: mode))
    }

    /// The two rules every script is expected to carry.
    private let background: [FilterRule] = [
        .pendingDeletion(false), .bookmark(BookmarkFilter(values: [5], mode: .none)),
    ]

    // MARK: - The examples agreed on

    func test_givenTheAgreedExamples_whenSuggestingANameForEach_thenEachReadsAsItsRules() {
        let examples: [(rules: [FilterRule], balance: FolderBalance, expected: String)] = [
            ([.keywordCount(.isEmpty)], .off, "RandomNoKeywords.psc"),
            ([.keywordCount(.isNotEmpty)], .off, "RandomWithKeywords.psc"),
            ([.keywordCount(.atLeast(2))], .off, "RandomKeywords2Plus.psc"),
            ([.keywordCount(.atMost(1))], .off, "RandomKeywords1OrLess.psc"),
            ([.rating(.atLeast(3))], .off, "RandomRated3Plus.psc"),
            ([.rating(.exactly(0))], .off, "RandomUnrated.psc"),
            ([picks(["oak", "pines"], .any)], .off, "RandomOakOrPines.psc"),
            ([picks(["oak", "pines"], .all)], .off, "RandomOakAndPines.psc"),
            ([picks(["oak"], .none)], .off, "RandomNoOak.psc"),
            ([.keywordPath(KeywordPathFilter(kind: .hasPart, text: "Trees"))], .off, "RandomTrees.psc"),
            ([.bookmark(BookmarkFilter(values: [2], mode: .any))], .off, "RandomCurated.psc"),
            ([.label(LabelFilter(labels: ["Red"], mode: .any))], .off, "RandomLabelRed.psc"),
            ([.fileType(FileTypeFilter(extensions: ["mkv"], mode: .none))], .off, "RandomNoMkv.psc"),
            ([.rating(.atLeast(3)), .keywordCount(.isEmpty)], .balanced, "RandomRated3PlusNoKeywordsBalanced.psc"),
            (
                [.group(RuleGroup(match: .any, rules: [picks(["oak"], .any), picks(["pines"], .any)])), .rating(.atLeast(4))],
                .off, "RandomOakOrPinesRated4Plus.psc"
            ),
        ]
        for example in examples {
            XCTAssertEqual(name(example.rules, balance: example.balance), example.expected, "\(example.rules)")
        }
    }

    // MARK: - Background rules and the plain name

    func test_givenOnlyTheBackgroundRules_whenSuggesting_thenItIsThePlainName() {
        XCTAssertEqual(name(background), PSCFile.suggestedFileName)
        XCTAssertEqual(name([]), PSCFile.suggestedFileName)
    }

    func test_givenBackgroundRulesBesideOthers_whenSuggesting_thenOnlyTheOthersAreNamed() {
        XCTAssertEqual(name(background + [.keywordCount(.isEmpty)]), "RandomNoKeywords.psc")
    }

    /// Only at the top of an "all of" group are they background; anywhere
    /// else they change what the script samples, so they're named.
    func test_givenBackgroundRulesInsideAGroup_whenSuggesting_thenTheyAreNamed() {
        XCTAssertEqual(name([.pendingDeletion(true)]), "RandomPendingDeletion.psc")
        XCTAssertEqual(
            name([.group(RuleGroup(match: .any, rules: [.pendingDeletion(false), .rating(.atLeast(5))]))]),
            "RandomNotPendingDeletionOrRated5Plus.psc")
        XCTAssertEqual(name([.bookmark(BookmarkFilter(values: [5, 2], mode: .none))]), "RandomNotCuratedOrHidden.psc")
    }

    /// The reference script the generator's tests compare against must
    /// never be the default, so a save can't overwrite it by accident.
    func test_givenAnyRules_whenSuggesting_thenItIsNeverTheReferenceScriptsName() {
        XCTAssertNotEqual(name([]), "RandomCatalogSample.psc")
        XCTAssertNotEqual(
            name([.keywordPath(KeywordPathFilter(kind: .contains, text: "catalog sample"))]), "RandomCatalogSample.psc")
    }

    // MARK: - Folder balance

    func test_givenEachFolderBalance_whenSuggesting_thenItIsASuffix() {
        XCTAssertEqual(name([.rating(.atLeast(3))], balance: .equal), "RandomRated3PlusEqualFolders.psc")
        XCTAssertEqual(name([], balance: .balanced), "RandomBalanced.psc")
    }

    // MARK: - Each kind of rule

    func test_givenEachComparison_whenNamingRatingsAndCounts_thenEachHasItsOwnWording() {
        XCTAssertEqual(name([.rating(.exactly(4))]), "RandomRated4.psc")
        XCTAssertEqual(name([.rating(.atMost(2))]), "RandomRated2OrLess.psc")
        XCTAssertEqual(name([.rating(.isNot(0))]), "RandomNotRated0.psc")
        XCTAssertEqual(name([.keywordCount(.exactly(3))]), "RandomKeywords3.psc")
        XCTAssertEqual(name([.keywordCount(.isNot(2))]), "RandomKeywordsNot2.psc")
    }

    func test_givenPathAndKeywordText_whenNaming_thenTheTextBecomesPascalCaseWords() {
        XCTAssertEqual(name([.path(PathFilter(kind: .contains, text: "/2019/travel/", negated: false))]), "RandomPath2019Travel.psc")
        XCTAssertEqual(name([.path(PathFilter(kind: .startsWith, text: "/Volumes/X", negated: true))]), "RandomNotPathVolumesX.psc")
        XCTAssertEqual(
            name([.keywordPath(KeywordPathFilter(kind: .startsWith, text: "Nature\\Trees", negated: true))]),
            "RandomNoNatureTrees.psc")
    }

    func test_givenValueLists_whenNaming_thenValuesJoinWithOr() {
        XCTAssertEqual(name([.label(LabelFilter(labels: ["Red", "Select"], mode: .any))]), "RandomLabelRedOrSelect.psc")
        XCTAssertEqual(name([.label(LabelFilter(labels: [""], mode: .any))]), "RandomNoLabel.psc")
        XCTAssertEqual(name([.label(LabelFilter(labels: ["Red"], mode: .none))]), "RandomNotLabelRed.psc")
        XCTAssertEqual(name([.fileType(FileTypeFilter(extensions: ["jpg", "png"], mode: .any))]), "RandomJpgOrPng.psc")
        XCTAssertEqual(name([.bookmark(BookmarkFilter(values: [3], mode: .any))]), "RandomRandomUncurated.psc")
    }

    /// Rules that don't narrow anything (no text, nothing picked) add
    /// nothing to the name.
    func test_givenRulesThatAreStillEmpty_whenSuggesting_thenTheyAreLeftOut() {
        XCTAssertEqual(
            name([
                .path(PathFilter(kind: .contains, text: "", negated: false)),
                .keywordPath(KeywordPathFilter(kind: .contains, text: "")),
                picks([], .any), .rating(.atLeast(1)),
            ]),
            "RandomRated1Plus.psc")
    }

    func test_givenNestedGroups_whenNaming_thenAnyJoinsWithOrAndNoneSaysNo() {
        XCTAssertEqual(
            name([.group(RuleGroup(match: .none, rules: [picks(["oak"], .any), .rating(.exactly(0))]))]),
            "RandomNoOakOrUnrated.psc")
        XCTAssertEqual(name([.rating(.atLeast(3)), .keywordCount(.isEmpty)], match: .any), "RandomRated3PlusOrNoKeywords.psc")
    }

    // MARK: - Characters and length

    /// ASCII only, like the scripts themselves: accents fold ("Été" is
    /// "Ete"), and anything else with no ASCII form is dropped.
    func test_givenNonASCIINames_whenNaming_thenAccentsFoldAndTheRestIsDropped() {
        XCTAssertEqual(name([picks(["ete"], .any)]), "RandomEte.psc")
        XCTAssertEqual(name([picks(["ja"], .any), .rating(.atLeast(2))]), "RandomRated2Plus.psc")
        XCTAssertEqual(name([.label(LabelFilter(labels: ["O'Brien"], mode: .any))]), "RandomLabelOBrien.psc")
    }

    func test_givenAnUnknownKeyword_whenNaming_thenItIsCalledKeyword() {
        XCTAssertEqual(name([picks(["gone"], .any)]), "RandomKeyword.psc")
    }

    func test_givenManyRules_whenTheNameGetsLong_thenItStopsWithEtc() {
        let rules: [FilterRule] = [
            .rating(.atLeast(3)), .keywordCount(.atLeast(2)), picks(["oak", "pines"], .all),
            .label(LabelFilter(labels: ["Select"], mode: .any)), .fileType(FileTypeFilter(extensions: ["jpg"], mode: .any)),
            .path(PathFilter(kind: .contains, text: "/travel/", negated: false)),
            .bookmark(BookmarkFilter(values: [2], mode: .any)),
        ]
        let suggested = name(rules)

        XCTAssertTrue(suggested.hasPrefix("RandomRated3PlusKeywords2Plus"), suggested)
        XCTAssertTrue(suggested.hasSuffix("Etc.psc"), suggested)
        XCTAssertLessThanOrEqual(suggested.count, ScriptFileName.softLimit + "Random".count + "Etc.psc".count)
    }

    /// macOS allows at most 255 bytes in a file name; a suggestion past
    /// that can't be saved at all. Every shape of filter stays within the
    /// soft limit plus `Etc` and the longest suffix -- not only an "all
    /// of" root's list of rules (adversarial review, 2026-09-26: 424- and
    /// 538-byte names from an "any of" root and a long keyword pick).
    func test_givenFiltersOfEveryShape_whenTheNameWouldBeLong_thenItIsCappedAndEndsWithEtc() {
        let manyPaths = (1...25).map { FilterRule.keywordPath(KeywordPathFilter(kind: .hasPart, text: "Keyword Number \($0)")) }
        let longNames = Dictionary(uniqueKeysWithValues: (1...30).map { ("k\($0)", "Landscape Photo \($0)") })
        let manyPicks = FilterRule.category(
            CategoryFilter(branches: longNames.keys.sorted().map { CategoryBranch(rootGUID: $0, propGUIDs: [$0]) }, mode: .any))
        let cases: [(RuleGroup, String)] = [
            (RuleGroup(match: .any, rules: manyPaths), "an any-of root"),
            (RuleGroup(match: .none, rules: manyPaths), "a none-of root"),
            (RuleGroup(match: .all, rules: [manyPicks]), "one long rule"),
            (RuleGroup(match: .all, rules: [.group(RuleGroup(match: .any, rules: manyPaths))]), "a nested group"),
        ]
        let bound = "Random".count + ScriptFileName.softLimit + "Etc".count + "EqualFolders".count + ".psc".count
        for (root, shape) in cases {
            let suggested = ScriptFileName.suggest(
                for: SampleFilter(root: root), folderBalance: .equal, keywordName: { longNames[$0] })

            XCTAssertLessThanOrEqual(suggested.utf8.count, bound, "\(shape): \(suggested)")
            XCTAssertTrue(suggested.hasSuffix("EtcEqualFolders.psc"), "\(shape): \(suggested)")
        }
    }

    /// Cut at the start of a word, so the name doesn't end mid-word.
    func test_givenALongName_whenCapped_thenItIsCutWhereAWordBegins() {
        let rules = (1...25).map { FilterRule.keywordPath(KeywordPathFilter(kind: .hasPart, text: "Keyword Number \($0)")) }
        let suggested = name(rules, match: .any)

        let uncut = (1...25).map { "KeywordNumber\($0)" }.joined(separator: "Or")
        let kept = String(suggested.dropFirst("Random".count).dropLast("Etc.psc".count))

        XCTAssertTrue(uncut.hasPrefix(kept), suggested)
        let next = uncut[uncut.index(uncut.startIndex, offsetBy: kept.count)]
        XCTAssertTrue(next.isUppercase, "cut mid-word before \(next): \(suggested)")
    }

    /// The scripts folder's volume ignores case, so any spelling of the
    /// reference script's name is the reference script.
    func test_givenTextSpellingTheReferenceNameInAnyCase_whenSuggesting_thenItIsNeverTheReferenceScript() {
        let spellings: [FilterRule] = [
            .keywordPath(KeywordPathFilter(kind: .contains, text: "CATALOG SAMPLE")),
            .keywordPath(KeywordPathFilter(kind: .contains, text: "catalogsample")),
            .fileType(FileTypeFilter(extensions: ["catalogsample"], mode: .any)),
        ]
        for rule in spellings {
            let suggested = name([rule])
            XCTAssertNotEqual(
                suggested.lowercased(), "randomcatalogsample.psc", "\(rule) suggested \(suggested)")
        }
    }

    func test_givenAnyName_whenSuggested_thenItIsSafeAsAFileName() {
        let suggested = name([.path(PathFilter(kind: .contains, text: "a/b:c*d?\"e<f>|g", negated: false))])
        XCTAssertTrue(suggested.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }, suggested)
    }
}
