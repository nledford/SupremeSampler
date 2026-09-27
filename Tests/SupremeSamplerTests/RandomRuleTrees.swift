import Foundation

@testable import SupremeSampler

/// Seeded random rule trees, shared by the suites that check a property
/// over many filters (`PredicateConsistencyTests`, `ScriptReaderTests`).
/// A case-less `enum` is a namespace, like a Rust module.
enum RandomRuleTrees {

    /// SplitMix64 -- a tiny, fixed-seed random generator, so a failing
    /// tree reproduces on every run. Swift's built-in generator can't be
    /// seeded; conforming to `RandomNumberGenerator` (a protocol, like a
    /// Rust trait) lets it drive the standard `randomElement(using:)`
    /// and `Int.random(in:using:)` APIs, the same way Rust's `rand`
    /// crate takes any `impl Rng`.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func randomRule(depth: Int, using rng: inout SeededGenerator) -> FilterRule {
        switch Int.random(in: 0..<(depth > 0 ? 10 : 9), using: &rng) {
        case 0:
            let value = Int.random(in: 0...5, using: &rng)
            return .rating(
                [RatingFilter.exactly(value), .atLeast(value), .atMost(value), .isNot(value)].randomElement(using: &rng)!)
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
            return .path(
                PathFilter(kind: kind, text: texts.randomElement(using: &rng)!, negated: Bool.random(using: &rng)))
        case 3:
            let pool = ["", "Select", "選択", "Red", "O'Brien", "Missing"]
            let labels = (0..<Int.random(in: 0...3, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            let mode = [ValueMatchMode.any, .none].randomElement(using: &rng)!
            return .label(LabelFilter(labels: labels, mode: mode))
        case 4:
            let pool = ["", "jpg", "png", "mkv", "lr_", "txt"]
            let types = (0..<Int.random(in: 0...3, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            let mode = [ValueMatchMode.any, .none].randomElement(using: &rng)!
            return .fileType(FileTypeFilter(extensions: types, mode: mode))
        case 5:
            let values = (0..<Int.random(in: 0...3, using: &rng)).map { _ in [0, 2, 3, 4, 5, 9].randomElement(using: &rng)! }
            return .bookmark(BookmarkFilter(values: values, mode: [ValueMatchMode.any, .none].randomElement(using: &rng)!))
        case 6:
            return .pendingDeletion(Bool.random(using: &rng))
        case 7:
            let texts = [
                "", "trees", "TREES", "arm", "Nature\\Trees", "\\Oak", "Trees\\Oak", "100%", "%_x", "a_x",
                "Loop\\Again\\Again", "Again", "People", "x", "L31", "L32", "L33", "\\L32", "O'Brien", "été", "Été",
            ]
            let kind = KeywordPathMatchKind.allCases.randomElement(using: &rng)!
            return .keywordPath(
                KeywordPathFilter(kind: kind, text: texts.randomElement(using: &rng)!, negated: Bool.random(using: &rng)))
        case 8:
            let value = Int.random(in: 0...4, using: &rng)
            return .keywordCount(
                [KeywordCountFilter.exactly(value), .atLeast(value), .atMost(value), .isNot(value)]
                    .randomElement(using: &rng)!)
        default:
            return .group(randomGroup(depth: depth - 1, using: &rng))
        }
    }

    static func randomGroup(depth: Int, using rng: inout SeededGenerator) -> RuleGroup {
        let match = [GroupMatch.all, .any, .none].randomElement(using: &rng)!
        let rules = (0..<Int.random(in: 0...3, using: &rng)).map { _ in randomRule(depth: depth, using: &rng) }
        return RuleGroup(match: match, rules: rules)
    }

    /// A random rule-builder state -- rows as the controls hold them --
    /// with keyword picks drawn from `keywordGUIDs`.
    static func randomDraftGroup(depth: Int, keywordGUIDs: [String], using rng: inout SeededGenerator) -> RuleGroupDraft {
        let match = [GroupMatch.all, .any, .none].randomElement(using: &rng)!
        let rules = (0..<Int.random(in: 0...3, using: &rng)).map { _ in
            randomDraftRule(depth: depth, keywordGUIDs: keywordGUIDs, using: &rng)
        }
        return RuleGroupDraft(match: match, rules: rules)
    }

    private static func randomDraftRule(depth: Int, keywordGUIDs: [String], using rng: inout SeededGenerator) -> RuleDraft {
        func picks(_ pool: [String]) -> Set<String> {
            Set((0..<Int.random(in: 0...3, using: &rng)).map { _ in pool.randomElement(using: &rng)! })
        }
        let comparison = NumberComparisonKind.allCases.randomElement(using: &rng)!
        switch Int.random(in: 0..<(depth > 0 ? 10 : 8), using: &rng) {
        case 0:
            return RuleDraft(.rating(RatingRuleDraft(comparison: comparison, value: Int.random(in: 0...5, using: &rng))))
        case 1:
            let op = KeywordOperator.allCases.randomElement(using: &rng)!
            let text = ["", "trees", "Nature\\Pines", "O'Brien", "100%"].randomElement(using: &rng)!
            return RuleDraft(.keyword(KeywordRuleDraft(operator: op, selectedGUIDs: picks(keywordGUIDs), text: text)))
        case 2:
            return RuleDraft(
                .keywordCount(KeywordCountRuleDraft(comparison: comparison, value: Int.random(in: 0...4, using: &rng))))
        case 3:
            let text = ["", "/2019/", "x\\y", ".PNG"].randomElement(using: &rng)!
            return RuleDraft(.path(PathRuleDraft(operator: PathOperator.allCases.randomElement(using: &rng)!, text: text)))
        case 4:
            return RuleDraft(
                .label(LabelRuleDraft(mode: [.any, .none].randomElement(using: &rng)!, selectedLabels: picks(["", "Red", "選択"]))))
        case 5:
            return RuleDraft(
                .fileType(FileTypeRuleDraft(mode: [.any, .none].randomElement(using: &rng)!, selectedTypes: picks(["", "jpg", "png"]))))
        case 6:
            return RuleDraft(
                .bookmark(BookmarkRuleDraft(mode: [.any, .none].randomElement(using: &rng)!, selectedValues: picks(["0", "2", "5"]))))
        case 7:
            return RuleDraft(.pendingDeletion(PendingDeletionRuleDraft(isPending: Bool.random(using: &rng))))
        case 8:
            return RuleDraft(.group(randomDraftGroup(depth: depth - 1, keywordGUIDs: keywordGUIDs, using: &rng)))
        default:
            // A group of nothing but keyword "is any of" rows: its SQL is
            // also a keyword "is all of" rule's, the case the importer has
            // to tell apart (it has turned OR into AND, and asked about
            // rows in unsorted order, before).
            let rows = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                RuleDraft(.keyword(KeywordRuleDraft(operator: .isAnyOf, selectedGUIDs: picks(keywordGUIDs).union([keywordGUIDs.randomElement(using: &rng)!]))))
            }
            return RuleDraft(.group(RuleGroupDraft(match: [.all, .any].randomElement(using: &rng)!, rules: rows)))
        }
    }
}
