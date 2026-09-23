import Foundation

/// How a group combines its rules -- Lightroom Smart Collection's
/// "Match all / any / none of the following rules". "None of" is how
/// photos are excluded: a nested "none of" group inside an "all of"
/// group means "...and not these".
///
/// A rule that can't be decided for a photo (e.g. a NULL rating) counts
/// as *not matching*, including underneath "none of" -- so an unrated
/// photo is never silently dropped from both a rule and its negation.
enum GroupMatch: Equatable, Hashable {
    case all
    case any
    case none
}

/// One rule in a filter. A rule can itself be a whole group, which is
/// what makes the filter a tree -- like a Rust `enum` with a variant
/// holding a `Vec` of the same enum. (No `indirect` keyword is needed
/// here, since the nesting goes through an array, already heap-backed.)
enum FilterRule: Equatable {
    case rating(RatingFilter)
    case category(CategoryFilter)
    case path(PathFilter)
    case label(LabelFilter)
    case group(RuleGroup)
}

/// A match mode applied to a list of rules. An empty group matches
/// vacuously: every photo for "all of" and "none of", no photo for
/// "any of".
struct RuleGroup: Equatable {
    var match: GroupMatch
    var rules: [FilterRule]
}

/// The full set of constraints for a random sample: a single root group.
/// Like `RatingFilter`/`CategoryFilter`, it carries no SQL of its own --
/// `PhotoSupremeCatalog` and `SQLPredicateText` each render it.
struct SampleFilter: Equatable {
    var root: RuleGroup

    init(root: RuleGroup) {
        self.root = root
    }

    /// A flat "all of" filter: the shape the rule builder produces today,
    /// and the only shape that existed before groups. `nil` omits that
    /// rule; `SampleFilter()` with both nil matches the whole catalog.
    init(rating: RatingFilter? = nil, category: CategoryFilter? = nil) {
        var rules: [FilterRule] = []
        if let rating { rules.append(.rating(rating)) }
        if let category { rules.append(.category(category)) }
        self.init(root: RuleGroup(match: .all, rules: rules))
    }

    /// True only for "all of nothing" -- the one filter that needs no
    /// WHERE clause at all. ("None of nothing" also matches everything,
    /// but renders a harmless `1 = 1`; not worth a special case.)
    var isUnconstrained: Bool {
        root.match == .all && root.rules.isEmpty
    }
}
