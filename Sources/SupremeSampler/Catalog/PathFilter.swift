import Foundation

/// How a photo's file path must relate to some text.
enum PathMatchKind: Equatable, Hashable, CaseIterable {
    case startsWith
    case endsWith
    case contains
}

/// A constraint on a photo's full file path: its folder -- absolute,
/// volume mount included, e.g. `/Volumes/Photos/library/photos/Travel/2019/`
/// -- followed by its file name, the same full path the earlier lusia
/// tool built (see `docs/queries.md`, "Full path for a photo").
///
/// Matching ignores letter case for A-Z only, the way SQLite's `LIKE`
/// does; other letters must match exactly. `text` is literal: `%`, `_`
/// and `\` mean themselves, not wildcards. Empty text matches every path.
/// `negated` turns "contains" into "does not contain", and so on.
struct PathFilter: Equatable {
    let kind: PathMatchKind
    let text: String
    let negated: Bool

    init(kind: PathMatchKind, text: String, negated: Bool = false) {
        self.kind = kind
        self.text = text
        self.negated = negated
    }

    /// The SQL `LIKE` pattern for this filter, to be used with
    /// `ESCAPE '\'`. Shared by both predicate renderers: it's the one
    /// piece with no binding-vs-literal difference between them.
    var likePattern: String {
        let escaped = LikePattern.escape(text)
        switch kind {
        case .startsWith: return escaped + "%"
        case .endsWith: return "%" + escaped
        case .contains: return "%" + escaped + "%"
        }
    }
}
