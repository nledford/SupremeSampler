import Foundation

/// How a keyword's path (see `KeywordPath`) must relate to some text.
enum KeywordPathMatchKind: Equatable, Hashable, CaseIterable {
    /// The text appears anywhere in the path.
    case contains
    /// The text is one or more whole, consecutive parts of the path:
    /// `arm` matches `Nature\Arm` but not `Style\Charm`.
    case hasPart
    /// The path begins with the text -- a literal prefix, so
    /// `Nature\Trees` also matches `Nature\Treestand`.
    case startsWith
    /// The path ends with the text; `\Oak` matches only Oak keywords.
    case endsWith
}

/// A constraint on the paths of the keywords a photo has.
///
/// - Positive: the photo has *some* keyword whose path matches.
/// - `negated`: the photo has *no* keyword whose path matches -- so a
///   photo with no keywords at all counts, as with category "none of".
/// - Empty `text`: the rule is ignored (every photo matches, either way),
///   so a rule that's just been added doesn't empty the sample.
///
/// Matching ignores letter case for A-Z only, like SQLite's `LIKE`, and
/// `%`, `_` and `\` in `text` mean themselves. Keywords under Photo
/// Supreme's built-in `{...}` categories have no path here, so never
/// match. Like `PathFilter`, this carries no SQL of its own beyond the
/// pieces both predicate renderers share.
struct KeywordPathFilter: Equatable {
    let kind: KeywordPathMatchKind
    let text: String
    let negated: Bool

    init(kind: KeywordPathMatchKind, text: String, negated: Bool = false) {
        self.kind = kind
        self.text = text
        self.negated = negated
    }

    /// Whether one path matches, ignoring `negated` and the empty-text
    /// rule (those are about photos, not paths). Compares Unicode scalars,
    /// not Swift `Character`s: `String.contains` treats canonically
    /// equivalent spellings (precomposed vs. combining "é") as equal, and
    /// SQLite's `LIKE` doesn't.
    func matches(keywordPath: String) -> Bool {
        let path = Self.foldedScalars(keywordPath)
        let wanted = Self.foldedScalars(text)
        let separator = Array(KeywordPath.separator.unicodeScalars)
        switch kind {
        case .contains: return Self.contains(path, wanted)
        case .hasPart: return Self.contains(separator + path + separator, separator + wanted + separator)
        case .startsWith: return path.starts(with: wanted)
        case .endsWith: return path.reversed().starts(with: wanted.reversed())
        }
    }

    /// Whether a photo with these keyword paths satisfies the rule.
    func matchesPhoto(keywordPaths: [String]) -> Bool {
        guard !text.isEmpty else { return true }
        let anyMatches = keywordPaths.contains { matches(keywordPath: $0) }
        return negated ? !anyMatches : anyMatches
    }

    /// The keywords among `paths` whose path matches `text` (negation
    /// aside) -- for showing which keywords a rule is about. None for
    /// empty text, which ignores the rule.
    func matchingKeywordPaths(in paths: [KeywordPath]) -> [KeywordPath] {
        guard !text.isEmpty else { return [] }
        return paths.filter { matches(keywordPath: $0.text) }
    }

    /// `text`'s scalars with A-Z lowered and nothing else changed -- the
    /// same case folding SQLite's built-in `LIKE` does.
    private static func foldedScalars(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.map { scalar in
            ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }
    }

    private static func contains(_ haystack: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}

// The SQL pieces both predicate renderers share. None of them carries
// user text except `likePattern`, which has no binding-vs-literal
// difference either (the same reasoning as `PathFilter.likePattern`).
// An `extension` adds members to a type declared elsewhere -- like a
// second Rust `impl` block for the same struct.
extension KeywordPathFilter {
    /// A `WITH RECURSIVE` query yielding `kp(guid, path, depth)` for
    /// every keyword -- the SQL twin of `KeywordPath.all(in:)` over
    /// `PhotoSupremeCatalog.listPropTree()`'s tree: custom categories
    /// only, the same depth cap as `CatalogPropNode.maxDepth`. Ends
    /// ready for a `WHERE` on `kp`, e.g. `<cte> WHERE kp.path LIKE ...`.
    ///
    /// `substr(GUID, 1, 1) <> char(123)` is `GUID NOT LIKE '{%'` (123 is
    /// `{`) spelled without a `{`, which opens a comment in Pascal and
    /// would be the first one inside a generated script's string literal
    /// -- not worth testing Script Studio's flaky comment handling on.
    static let keywordPathsQuery = """
        WITH RECURSIVE kp(guid, path, depth) AS (\
        SELECT GUID, CategoryName, 0 FROM idPropCategory WHERE substr(GUID, 1, 1) <> char(123) \
        UNION ALL \
        SELECT p.GUID, kp.path || '\\' || p.PropName, kp.depth + 1 FROM idProp p JOIN kp ON p.ParentGUID = kp.guid \
        WHERE kp.depth < \(CatalogPropNode.maxDepth)) \
        SELECT kp.guid FROM kp
        """

    /// What the `LIKE` tests: the path itself, or the path with a `\` on
    /// each end for `.hasPart`, so whole parts are `\`-delimited
    /// everywhere, including the first and last.
    var likeSubject: String {
        kind == .hasPart ? "'\\' || kp.path || '\\'" : "kp.path"
    }

    /// The `LIKE` pattern (with `ESCAPE '\'`) for `text`. For `.hasPart`
    /// the surrounding separators are escaped `\`s: `%\\trees\\%`.
    var likePattern: String {
        let escaped = LikePattern.escape(text)
        switch kind {
        case .contains: return "%" + escaped + "%"
        case .hasPart: return "%\\\\" + escaped + "\\\\%"
        case .startsWith: return escaped + "%"
        case .endsWith: return "%" + escaped
        }
    }
}
