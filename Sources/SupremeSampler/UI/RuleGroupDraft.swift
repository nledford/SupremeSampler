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
        }
    }
}

/// A category rule as the controls see it: a match mode and whatever
/// nodes are selected in the tree (not yet expanded to subcategories).
struct CategoryRuleDraft: Equatable {
    var mode: CategoryMatchMode = .any
    var selectedGUIDs: Set<String> = []
}

/// A file-path rule as the controls see it: "Path [starts with / ends
/// with / contains] [text]".
struct PathRuleDraft: Equatable {
    var kind: PathMatchKind = .contains
    var text: String = ""
}

/// A color-label rule as the controls see it: a match mode and the label
/// values picked from the catalog's list (`""` is "No label").
struct LabelRuleDraft: Equatable {
    var mode: ValueMatchMode = .any
    var selectedLabels: Set<String> = []
}

/// One row in a group: a rating, category, path, or label rule, or a
/// nested group.
struct RuleDraft: Identifiable, Equatable {
    enum Content: Equatable {
        case rating(RatingRuleDraft)
        case category(CategoryRuleDraft)
        case path(PathRuleDraft)
        case label(LabelRuleDraft)
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

/// What the "Add" menu can create.
enum NewRuleKind {
    case rating
    case category
    case path
    case label
    case group
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

    /// Appends a new rule with default settings. `mutating` marks a
    /// method that changes a value type in place -- the Swift spelling
    /// of Rust's `&mut self`.
    mutating func add(_ kind: NewRuleKind) {
        switch kind {
        case .rating: rules.append(RuleDraft(.rating(RatingRuleDraft())))
        case .category: rules.append(RuleDraft(.category(CategoryRuleDraft())))
        case .path: rules.append(RuleDraft(.path(PathRuleDraft())))
        case .label: rules.append(RuleDraft(.label(LabelRuleDraft())))
        case .group: rules.append(RuleDraft(.group(RuleGroupDraft())))
        }
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
                case .category(let category):
                    return .category(
                        CategoryFilter(
                            branches: CategoryBranch.resolve(selectedGUIDs: category.selectedGUIDs, in: tree),
                            mode: category.mode
                        ))
                case .path(let path):
                    return .path(PathFilter(kind: path.kind, text: path.text))
                case .label(let label):
                    // Sorted: the selection is a `Set`, whose order must
                    // not leak into the generated script.
                    return .label(LabelFilter(labels: label.selectedLabels.sorted(), mode: label.mode))
                case .group(let group):
                    return .group(group.domainGroup(resolvingCategoriesIn: tree))
                }
            }
        )
    }
}
