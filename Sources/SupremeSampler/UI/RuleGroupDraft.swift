import Foundation

// The rule builder's editable state -- deliberately separate from the
// domain filter (`SampleFilter`/`RuleGroup`). The domain types say what
// a filter *means*; these say what the controls on screen are bound to:
// a picker's comparison plus a stepper's value instead of a
// `RatingFilter` with a payload, the tree's raw selection instead of
// resolved branches, and a stable `id` per rule so SwiftUI can keep
// each row's identity across edits (the same job a React `key` prop
// does). `domainGroup(resolvingCategoriesIn:)` converts one to the
// other. All of these are structs (value types), so an edit anywhere in
// the tree is a plain mutation of a copy, like editing a Rust struct
// you own -- no shared references to keep in sync.

/// A rating rule as the controls see it: "Rating [comparison] [value]".
struct RatingRuleDraft: Equatable {
    var comparison: RatingComparisonKind = .atLeast
    var value: Int = 3

    var domainFilter: RatingFilter {
        switch comparison {
        case .exactly: return .exactly(value)
        case .atLeast: return .atLeast(value)
        case .atMost: return .atMost(value)
        case .isNot: return .isNot(value)
        }
    }
}

/// The keyword rule's operator picker. Two families share one picker,
/// as Lightroom's "Keywords" field does: the first three test keywords
/// picked from the tree (each with its whole branch); the rest test the
/// text of keyword paths (`KeywordPathFilter`). Flat, one plain value per
/// choice, for the same reason as `PathOperator`.
enum KeywordOperator: String, CaseIterable, Identifiable, Hashable {
    case isAnyOf = "is any of"
    case isAllOf = "is all of"
    case isNoneOf = "is none of"
    case contains = "contains"
    case doesNotContain = "does not contain"
    case hasPart = "has a part named"
    case hasNoPart = "has no part named"
    case startsWith = "starts with"
    case doesNotStartWith = "does not start with"
    case endsWith = "ends with"
    case doesNotEndWith = "does not end with"

    var id: String { rawValue }

    /// `true` for the operators that test keywords picked from the tree,
    /// `false` for the ones that test path text.
    var picksKeywords: Bool {
        switch self {
        case .isAnyOf, .isAllOf, .isNoneOf: return true
        default: return false
        }
    }
}

/// A keyword rule as the controls see it: an operator plus both kinds of
/// value -- the tree's raw selection (not yet expanded to branches) and
/// path text. Only the one the operator uses counts; the other is kept so
/// switching operators back and forth doesn't lose what was entered.
struct KeywordRuleDraft: Equatable {
    var `operator`: KeywordOperator = .isAnyOf
    var selectedGUIDs: Set<String> = []
    var text: String = ""

    func domainRule(resolvingCategoriesIn tree: [CatalogPropNode]) -> FilterRule {
        let branches = { CategoryBranch.resolve(selectedGUIDs: selectedGUIDs, in: tree) }
        func path(_ kind: KeywordPathMatchKind, negated: Bool = false) -> FilterRule {
            .keywordPath(KeywordPathFilter(kind: kind, text: text, negated: negated))
        }
        switch `operator` {
        case .isAnyOf: return .category(CategoryFilter(branches: branches(), mode: .any))
        case .isAllOf: return .category(CategoryFilter(branches: branches(), mode: .all))
        case .isNoneOf: return .category(CategoryFilter(branches: branches(), mode: .none))
        case .contains: return path(.contains)
        case .doesNotContain: return path(.contains, negated: true)
        case .hasPart: return path(.hasPart)
        case .hasNoPart: return path(.hasPart, negated: true)
        case .startsWith: return path(.startsWith)
        case .doesNotStartWith: return path(.startsWith, negated: true)
        case .endsWith: return path(.endsWith)
        case .doesNotEndWith: return path(.endsWith, negated: true)
        }
    }
}

/// The path rule's operator picker: each match kind, plain or negated,
/// as one flat choice -- a `Picker` binds to one plain value, the same
/// reason `RatingComparisonKind` exists.
enum PathOperator: String, CaseIterable, Identifiable, Hashable {
    case contains = "contains"
    case doesNotContain = "does not contain"
    case startsWith = "starts with"
    case doesNotStartWith = "does not start with"
    case endsWith = "ends with"
    case doesNotEndWith = "does not end with"

    var id: String { rawValue }

    var kind: PathMatchKind {
        switch self {
        case .contains, .doesNotContain: return .contains
        case .startsWith, .doesNotStartWith: return .startsWith
        case .endsWith, .doesNotEndWith: return .endsWith
        }
    }

    var isNegated: Bool {
        switch self {
        case .doesNotContain, .doesNotStartWith, .doesNotEndWith: return true
        case .contains, .startsWith, .endsWith: return false
        }
    }
}

/// A file-path rule as the controls see it: "Path [operator] [text]".
struct PathRuleDraft: Equatable {
    var `operator`: PathOperator = .contains
    var text: String = ""
}

/// A bookmark rule as the controls see it: a match mode and the values
/// picked from the catalog's list (as the list's strings, "2").
struct BookmarkRuleDraft: Equatable {
    var mode: ValueMatchMode = .any
    var selectedValues: Set<String> = []
}

/// A pending-deletion rule as the controls see it. Defaults to leaving
/// pending photos out -- the likely use in a sampling tool.
struct PendingDeletionRuleDraft: Equatable {
    var isPending = false
}

/// A color-label rule as the controls see it: a match mode and the label
/// values picked from the catalog's list (`""` is "No label").
struct LabelRuleDraft: Equatable {
    var mode: ValueMatchMode = .any
    var selectedLabels: Set<String> = []
}

/// A file-type rule as the controls see it: a match mode and the
/// extensions picked from the catalog's list (`""` is "No extension").
struct FileTypeRuleDraft: Equatable {
    var mode: ValueMatchMode = .any
    var selectedTypes: Set<String> = []
}

/// One row in a group: a rule (see `RuleField`) or a nested group.
struct RuleDraft: Identifiable, Equatable {
    enum Content: Equatable {
        case rating(RatingRuleDraft)
        case keyword(KeywordRuleDraft)
        case path(PathRuleDraft)
        case label(LabelRuleDraft)
        case fileType(FileTypeRuleDraft)
        case bookmark(BookmarkRuleDraft)
        case pendingDeletion(PendingDeletionRuleDraft)
        case group(RuleGroupDraft)
    }

    /// Assigned once, when the rule is created -- never in a view's
    /// `body`, which would give the row a new identity on every render.
    let id: UUID
    var content: Content

    init(_ content: Content) {
        self.id = UUID()
        self.content = content
    }
}

/// The first picker in a rule row -- what the rule tests, Lightroom's
/// "field". Changing it swaps the rule for that field's default.
enum RuleField: String, CaseIterable, Identifiable, Hashable {
    case rating = "Rating"
    case keyword = "Keyword"
    case path = "File path"
    case label = "Color label"
    case fileType = "File type"
    case bookmark = "Bookmark"
    case pendingDeletion = "Pending deletion"

    var id: String { rawValue }

    /// A new rule of this field, with default settings.
    var defaultContent: RuleDraft.Content {
        switch self {
        case .rating: return .rating(RatingRuleDraft())
        case .keyword: return .keyword(KeywordRuleDraft())
        case .path: return .path(PathRuleDraft())
        case .label: return .label(LabelRuleDraft())
        case .fileType: return .fileType(FileTypeRuleDraft())
        case .bookmark: return .bookmark(BookmarkRuleDraft())
        case .pendingDeletion: return .pendingDeletion(PendingDeletionRuleDraft())
        }
    }
}

extension RuleDraft {
    /// The row's field, or `nil` for a nested group.
    var field: RuleField? {
        switch content {
        case .rating: return .rating
        case .keyword: return .keyword
        case .path: return .path
        case .label: return .label
        case .fileType: return .fileType
        case .bookmark: return .bookmark
        case .pendingDeletion: return .pendingDeletion
        case .group: return nil
        }
    }
}

/// A group of rules being edited: "Match [all/any/none] of:" followed by
/// its rules, any of which may itself be a group.
struct RuleGroupDraft: Identifiable, Equatable {
    let id: UUID
    var match: GroupMatch
    var rules: [RuleDraft]

    init(match: GroupMatch = .all, rules: [RuleDraft] = []) {
        self.id = UUID()
        self.match = match
        self.rules = rules
    }

    /// Appends a new rule of `field`, with default settings -- the group
    /// header's "+". `mutating` marks a method that changes a value type
    /// in place -- the Swift spelling of Rust's `&mut self`.
    mutating func add(_ field: RuleField) {
        rules.append(RuleDraft(field.defaultContent))
    }

    /// Appends an empty "all of" group.
    mutating func addGroup() {
        rules.append(RuleDraft(.group(RuleGroupDraft())))
    }

    /// Inserts a new rule of `field` right after this group's rule `id` --
    /// a row's "+". A no-op if `id` isn't one of this group's rules.
    mutating func insertRule(_ field: RuleField, after id: RuleDraft.ID) {
        insert(RuleDraft(field.defaultContent), after: id)
    }

    /// Inserts an empty "all of" group right after this group's rule `id`.
    mutating func insertGroup(after id: RuleDraft.ID) {
        insert(RuleDraft(.group(RuleGroupDraft())), after: id)
    }

    /// Swaps this group's rule `id` for `field`'s default, keeping the
    /// row's place and identity. Keeps its settings if it's already that
    /// field; a no-op for a nested group or an unknown `id`.
    mutating func changeField(ofRule id: RuleDraft.ID, to field: RuleField) {
        guard let index = rules.firstIndex(where: { $0.id == id }),
            let current = rules[index].field, current != field
        else { return }
        rules[index].content = field.defaultContent
    }

    private mutating func insert(_ rule: RuleDraft, after id: RuleDraft.ID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules.insert(rule, at: index + 1)
    }

    /// Removes this group's own rule with `id`; a no-op if it isn't here.
    /// (A nested group's rules are removed through that group.)
    mutating func removeRule(id: RuleDraft.ID) {
        rules.removeAll { $0.id == id }
    }

    /// The domain meaning of what's on screen. Category selections are
    /// expanded to whole branches against `tree` here, so a parent
    /// category always includes its subcategories.
    func domainGroup(resolvingCategoriesIn tree: [CatalogPropNode]) -> RuleGroup {
        RuleGroup(
            match: match,
            rules: rules.map { rule in
                switch rule.content {
                case .rating(let rating):
                    return .rating(rating.domainFilter)
                case .keyword(let keyword):
                    return keyword.domainRule(resolvingCategoriesIn: tree)
                case .path(let path):
                    return .path(PathFilter(kind: path.operator.kind, text: path.text, negated: path.operator.isNegated))
                case .label(let label):
                    // Sorted: the selection is a `Set`, whose order must
                    // not leak into the generated script.
                    return .label(LabelFilter(labels: label.selectedLabels.sorted(), mode: label.mode))
                case .fileType(let fileType):
                    return .fileType(FileTypeFilter(extensions: fileType.selectedTypes.sorted(), mode: fileType.mode))
                case .bookmark(let bookmark):
                    return .bookmark(
                        BookmarkFilter(values: bookmark.selectedValues.compactMap(Int.init).sorted(), mode: bookmark.mode))
                case .pendingDeletion(let deletion):
                    return .pendingDeletion(deletion.isPending)
                case .group(let group):
                    return .group(group.domainGroup(resolvingCategoriesIn: tree))
                }
            }
        )
    }
}
