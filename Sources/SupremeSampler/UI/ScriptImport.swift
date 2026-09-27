import Foundation

/// A script read from disk, turned into rules the rule builder can edit,
/// with whatever the user should hear about before they replace the
/// rules on screen. Pure: the model reads the file and applies this.
///
/// Keyword rules are the one place the catalog matters. A script holds a
/// keyword rule as the GUID list it expanded to when it was saved; the
/// rule builder holds picks (a keyword stands for its whole branch). The
/// picks are the keywords in the list whose parent isn't also in it.
/// Checked by expanding the picks again against today's tree: if that
/// doesn't give the script's SQL back (keywords added, moved or deleted
/// since), `keywordsResolveDifferently` says so.
struct ScriptImport: Equatable {
    let url: URL
    let script: ReadScript
    let rules: RuleGroupDraft
    /// Picked keywords the open catalog doesn't have.
    let missingKeywordCount: Int
    /// The rules, expanded against the open catalog, don't match the
    /// same keywords the script does.
    let keywordsResolveDifferently: Bool

    var sampleSize: Int { script.sampleSize }
    var folderBalance: FolderBalance { script.folderBalance }

    /// Whether to ask before opening: something in the file won't come
    /// back exactly as it is.
    var needsConfirmation: Bool {
        !script.isExactlyAsGenerated || missingKeywordCount > 0 || keywordsResolveDifferently
    }

    init(url: URL, script: ReadScript, tree: [CatalogPropNode]) {
        self.url = url
        self.script = script

        var parents: [String: String] = [:]
        func index(_ node: CatalogPropNode) {
            for child in node.children {
                parents[child.guid] = node.guid
                index(child)
            }
        }
        tree.forEach(index)
        let known = Set(CatalogPropNode.nameIndex(tree).keys)

        let rules = RuleGroupDraft(importing: script.filter.root, parents: parents)
        self.rules = rules
        let picked = Self.pickedGUIDs(in: rules)
        missingKeywordCount = picked.subtracting(known).count
        keywordsResolveDifferently =
            SQLPredicateText.render(SampleFilter(root: rules.domainGroup(resolvingCategoriesIn: tree)))
            != SQLPredicateText.render(script.filter)
    }

    /// One sentence per thing that won't come back exactly, for the alert
    /// that asks before opening.
    var notices: [String] {
        var notices: [String] = []
        let unreadable = script.unreadableClauses
        if !unreadable.isEmpty {
            let quoted = unreadable.prefix(3).map { "“" + Self.shortened($0) + "”" }.joined(separator: ", ")
            let more = unreadable.count > 3 ? " and \(unreadable.count - 3) more" : ""
            notices.append(
                "\(Self.count(unreadable.count, "condition")) in its SQL couldn't be read and will be left out: "
                    + quoted + more + ".")
        }
        // A changed line is both removed and added; count it once.
        let edited = max(script.fileOnlyLines.count, script.generatedOnlyLines.count)
        if unreadable.isEmpty && edited > 0 {
            let first = script.fileOnlyLines.first.map { " (first at line \($0.number))" } ?? ""
            notices.append(
                "\(Self.count(edited, "line")) \(edited == 1 ? "differs" : "differ") from what Supreme Sampler writes\(first). "
                    + "Saving over the file will replace them.")
        }
        if missingKeywordCount > 0 {
            notices.append(
                "\(Self.count(missingKeywordCount, "picked keyword")) \(missingKeywordCount == 1 ? "isn't" : "aren't") in the open catalog.")
        }
        if keywordsResolveDifferently {
            notices.append(
                "Keywords have been added, moved or removed since it was saved, so its keyword rules now match different keywords.")
        }
        return notices
    }

    /// The alert's button for opening anyway.
    var confirmTitle: String {
        let unreadable = script.unreadableClauses.count
        guard unreadable > 0 else { return "Open Rules" }
        let recovered = Self.ruleCount(script.filter.root)
        return "Recover \(Self.count(recovered, "Rule"))"
    }

    private static func ruleCount(_ group: RuleGroup) -> Int {
        group.rules.reduce(0) { total, rule in
            if case .group(let nested) = rule { return total + ruleCount(nested) }
            return total + 1
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// SQL can be thousands of characters; the alert shows the start.
    private static func shortened(_ text: String) -> String {
        text.count <= 80 ? text : String(text.prefix(77)) + "…"
    }

    private static func pickedGUIDs(in group: RuleGroupDraft) -> Set<String> {
        group.rules.reduce(into: Set<String>()) { picked, rule in
            switch rule.content {
            case .keyword(let keyword) where keyword.operator.picksKeywords: picked.formUnion(keyword.selectedGUIDs)
            case .group(let nested): picked.formUnion(pickedGUIDs(in: nested))
            default: break
            }
        }
    }
}

extension RuleGroupDraft {
    /// The rows that would build `group`. `parents` maps each keyword GUID
    /// to its parent's, for turning keyword lists back into picks.
    init(importing group: RuleGroup, parents: [String: String]) {
        self.init(match: group.match, rules: group.rules.map { RuleDraft(importing: $0, parents: parents) })
    }
}

extension RuleDraft {
    init(importing rule: FilterRule, parents: [String: String]) {
        switch rule {
        case .rating(let rating):
            let (comparison, value) = Self.comparison(rating)
            self.init(.rating(RatingRuleDraft(comparison: comparison, value: value)))
        case .category(let category):
            let op: KeywordOperator
            switch category.mode {
            case .any: op = .isAnyOf
            case .all: op = .isAllOf
            case .none: op = .isNoneOf
            }
            // "All of" keeps one test per branch; "any"/"none" have one
            // list for all of them. Either way, a pick is a listed keyword
            // whose parent isn't listed with it.
            let picks = category.branches.reduce(into: Set<String>()) { picks, branch in
                let listed = Set(branch.propGUIDs)
                picks.formUnion(listed.filter { parents[$0].map(listed.contains) != true })
            }
            self.init(.keyword(KeywordRuleDraft(operator: op, selectedGUIDs: picks)))
        case .keywordPath(let keywordPath):
            self.init(.keyword(KeywordRuleDraft(operator: Self.keywordOperator(keywordPath), text: keywordPath.text)))
        case .keywordCount(let count):
            // Zero and "at least one" are the Keyword field's own tests.
            if count == .isEmpty {
                self.init(.keyword(KeywordRuleDraft(operator: .isEmpty)))
            } else if count == .isNotEmpty {
                self.init(.keyword(KeywordRuleDraft(operator: .isNotEmpty)))
            } else {
                let (comparison, value) = Self.comparison(count)
                self.init(.keywordCount(KeywordCountRuleDraft(comparison: comparison, value: value)))
            }
        case .path(let path):
            let op = PathOperator.allCases.first { $0.kind == path.kind && $0.isNegated == path.negated } ?? .contains
            self.init(.path(PathRuleDraft(operator: op, text: path.text)))
        case .label(let label):
            self.init(.label(LabelRuleDraft(mode: label.mode, selectedLabels: Set(label.labels))))
        case .fileType(let fileType):
            self.init(.fileType(FileTypeRuleDraft(mode: fileType.mode, selectedTypes: Set(fileType.extensions))))
        case .bookmark(let bookmark):
            self.init(
                .bookmark(BookmarkRuleDraft(mode: bookmark.mode, selectedValues: Set(bookmark.values.map(String.init)))))
        case .pendingDeletion(let isPending):
            self.init(.pendingDeletion(PendingDeletionRuleDraft(isPending: isPending)))
        case .group(let group):
            self.init(.group(RuleGroupDraft(importing: group, parents: parents)))
        }
    }

    private static func comparison(_ rating: RatingFilter) -> (NumberComparisonKind, Int) {
        switch rating {
        case .exactly(let n): return (.exactly, n)
        case .atLeast(let n): return (.atLeast, n)
        case .atMost(let n): return (.atMost, n)
        case .isNot(let n): return (.isNot, n)
        }
    }

    private static func comparison(_ count: KeywordCountFilter) -> (NumberComparisonKind, Int) {
        switch count {
        case .exactly(let n): return (.exactly, n)
        case .atLeast(let n): return (.atLeast, n)
        case .atMost(let n): return (.atMost, n)
        case .isNot(let n): return (.isNot, n)
        }
    }

    private static func keywordOperator(_ filter: KeywordPathFilter) -> KeywordOperator {
        switch (filter.kind, filter.negated) {
        case (.contains, false): return .contains
        case (.contains, true): return .doesNotContain
        case (.hasPart, false): return .hasPart
        case (.hasPart, true): return .hasNoPart
        case (.startsWith, false): return .startsWith
        case (.startsWith, true): return .doesNotStartWith
        case (.endsWith, false): return .endsWith
        case (.endsWith, true): return .doesNotEndWith
        }
    }
}

// The alert File > Open Script… shows, worded here so tests can read it.
extension SampleBuilderModel.ScriptOpenPrompt {
    var title: String {
        switch self {
        case .confirm(let opening):
            let name = opening.url.lastPathComponent
            return opening.script.isExactlyAsGenerated
                ? "“\(name)” doesn't match this catalog's keywords"
                : "“\(name)” was changed outside \(AppName.current)"
        case .cannotOpen(let fileName, _):
            return "Can't open “\(fileName)”"
        }
    }

    var message: String {
        switch self {
        case .confirm(let opening):
            return (opening.notices + ["Open its rules anyway? The script file isn't changed until you save."])
                .joined(separator: "\n\n")
        case .cannotOpen(_, let reason):
            return reason
        }
    }
}
