import Foundation

/// Reads the SQL text `SQLPredicateText` writes back into a `SampleFilter`
/// -- its inverse, for opening a saved script. Pure, like the renderer.
///
/// It reads only the shapes the renderer produces, strictly: anchored
/// prefixes and suffixes, string literals parsed piece by piece, lists
/// split only outside quotes and parentheses. A condition it doesn't
/// recognize -- typically a hand edit -- is returned in
/// `unreadableClauses` and left out of the filter, so the rest can still
/// be recovered. `ScriptReader` then renders what was read and compares
/// it with the file: identical text means the file means exactly these
/// rules, whatever this reader got right or wrong along the way.
///
/// Some different filters render the same text; this picks one, and
/// since they render identically they match the same photos:
///
/// - `1 = 1` (a vacuous rule) reads as an empty "all of" group, what a
///   new group starts as; `0 = 1` as a keyword rule with nothing picked,
///   what a new keyword rule starts as.
/// - A root "all of" holding one "any/none of" group reads as that
///   group at the root.
/// - `(a AND b)` over keyword membership tests reads as one keyword
///   "all of" rule rather than a group of "any of" rules.
/// - A keyword "any/none of" list reads as one branch holding every
///   GUID; `RuleGroupDraft` splits it back into picks against the tree.
enum SQLPredicateReader {
    struct Reading: Equatable {
        var filter: SampleFilter
        /// Conditions that weren't recognized, in the order they appear.
        var unreadableClauses: [String]
    }

    /// The deepest parentheses a predicate may nest. The rule builder's
    /// deepest real trees stay far below it; each level costs the reader
    /// a pass over the text and a stack frame, so thousands of levels (a
    /// few kilobytes of hostile or garbled text) would hang, then crash.
    static let maximumNesting = 128

    /// `nil` (no WHERE clause) is the unfiltered script. Check
    /// `SQLScanner.nesting` against `maximumNesting` first.
    static func read(_ predicate: String?) -> Reading {
        guard let predicate else { return Reading(filter: SampleFilter(), unreadableClauses: []) }
        var unreadable: [String] = []
        let root = rootGroup(predicate, unreadable: &unreadable)
        return Reading(filter: SampleFilter(root: root), unreadableClauses: unreadable)
    }

    // MARK: - Groups

    /// The root "all of" renders bare, `a AND b`; any other root renders
    /// as a self-delimited group, the same as a nested one.
    private static func rootGroup(_ text: String, unreadable: inout [String]) -> RuleGroup {
        let parts = SQLScanner.split(text, on: " AND ") ?? [text]
        var groupUnreadable: [String] = []
        if parts.count == 1, leafRule(text) == nil,
            let group = group(text, unreadable: &groupUnreadable), group.match != .all
        {
            unreadable += groupUnreadable
            return group
        }
        return RuleGroup(match: .all, rules: rules(parts, unreadable: &unreadable))
    }

    // `inout` passes a variable for the callee to change in place, like
    // `&mut Vec<String>` in Rust; the caller writes `&unreadable`.
    private static func rules(_ clauses: [String], unreadable: inout [String]) -> [FilterRule] {
        // `compactMap` drops the `nil`s -- like Rust's `filter_map`.
        clauses.compactMap { clause in
            if let rule = rule(clause, unreadable: &unreadable) { return rule }
            unreadable.append(clause)
            return nil
        }
    }

    private static func rule(_ clause: String, unreadable: inout [String]) -> FilterRule? {
        if let leaf = leafRule(clause) { return leaf }
        return group(clause, unreadable: &unreadable).map(FilterRule.group)
    }

    /// `(a AND b)`, `(a OR b)` or `NOT COALESCE((a OR b), 0)`.
    private static func group(_ clause: String, unreadable: inout [String]) -> RuleGroup? {
        if let inner = clause.strippingAffixes("NOT COALESCE(", ", 0)"), let orInner = SQLScanner.parenthesized(inner),
            let parts = SQLScanner.split(orInner, on: " OR ")
        {
            return RuleGroup(match: .none, rules: rules(parts, unreadable: &unreadable))
        }
        guard let inner = SQLScanner.parenthesized(clause),
            let orParts = SQLScanner.split(inner, on: " OR "),
            let andParts = SQLScanner.split(inner, on: " AND ")
        else { return nil }
        switch (orParts.count > 1, andParts.count > 1) {
        case (true, false): return RuleGroup(match: .any, rules: rules(orParts, unreadable: &unreadable))
        // One rule in parentheses is ambiguous ("all of" or "any of" one
        // rule); both render alike, and a new group starts as "all of".
        case (false, _): return RuleGroup(match: .all, rules: rules(andParts, unreadable: &unreadable))
        case (true, true): return nil
        }
    }

    // MARK: - Rules

    private static func leafRule(_ clause: String) -> FilterRule? {
        switch clause {
        case "1 = 1": return .group(RuleGroup(match: .all, rules: []))
        case "0 = 1": return .category(CategoryFilter(branches: [], mode: .any))
        case "COALESCE(Rating, 0) < 0": return .pendingDeletion(true)
        case "COALESCE(Rating, 0) >= 0": return .pendingDeletion(false)
        default: break
        }
        // Tried in turn; each checks its own prefix first, so at most one
        // can match. `??` is "or else", like Rust's `Option::or_else`.
        return rating(clause) ?? bookmark(clause) ?? label(clause) ?? fileType(clause)
            ?? category(clause) ?? path(clause) ?? keywordPath(clause) ?? keywordCount(clause)
    }

    private static func rating(_ clause: String) -> FilterRule? {
        let comparisons: [(String, (Int) -> RatingFilter)] = [
            ("Rating = ", RatingFilter.exactly), ("Rating >= ", RatingFilter.atLeast),
            ("Rating <= ", RatingFilter.atMost), ("Rating IS NOT ", RatingFilter.isNot),
        ]
        for (prefix, make) in comparisons {
            if let number = clause.strippingAffixes(prefix, ""), let value = Int(number) {
                return .rating(make(value))
            }
        }
        return nil
    }

    /// `IN (...)` or `NOT IN (...)` after `subject`, as a mode and the
    /// list's elements.
    private static func membership(_ clause: String, subject: String) -> (ValueMatchMode, [String])? {
        for (keyword, mode) in [("IN", ValueMatchMode.any), ("NOT IN", ValueMatchMode.none)] {
            if let list = clause.strippingAffixes(subject + " " + keyword + " (", ")"),
                let items = SQLScanner.split(list, on: ", ")
            {
                return (mode, items)
            }
        }
        return nil
    }

    private static func bookmark(_ clause: String) -> FilterRule? {
        guard let (mode, items) = membership(clause, subject: "CAST(COALESCE(idBookmark, 0) AS INTEGER)") else {
            return nil
        }
        let values = items.compactMap { Int($0) }
        guard values.count == items.count else { return nil }
        return .bookmark(BookmarkFilter(values: values, mode: mode))
    }

    private static func label(_ clause: String) -> FilterRule? {
        guard let (mode, items) = membership(clause, subject: "COALESCE(idLabel, '')") else { return nil }
        let labels = items.compactMap(SQLScanner.stringValue)
        guard labels.count == items.count else { return nil }
        return .label(LabelFilter(labels: labels, mode: mode))
    }

    private static let noExtensionTest =
        "(instr(COALESCE(FileName, ''), '.') = 0 OR COALESCE(FileName, '') LIKE '%.')"

    /// `(test OR test)` for "any of", `NOT (...)` for "none of".
    private static func fileType(_ clause: String) -> FilterRule? {
        let negated = clause.hasPrefix("NOT (")
        guard let inner = SQLScanner.parenthesized(negated ? String(clause.dropFirst(4)) : clause),
            let tests = SQLScanner.split(inner, on: " OR ")
        else { return nil }
        var extensions: [String] = []
        for test in tests {
            if test == noExtensionTest {
                extensions.append("")
                continue
            }
            guard let literal = test.strippingAffixes("COALESCE(FileName, '') LIKE ", " ESCAPE '\\'"),
                let pattern = SQLScanner.stringValue(literal),
                let parts = LikePatternParts(pattern), parts.leadingWildcard, !parts.trailingWildcard,
                parts.literal.hasPrefix("."), !parts.literal.dropFirst().contains(".")
            else { return nil }
            extensions.append(String(parts.literal.dropFirst()))
        }
        return .fileType(FileTypeFilter(extensions: extensions, mode: negated ? .none : .any))
    }

    /// The prop GUIDs of one "photo has any of these keywords" test.
    private static func keywordGUIDs(_ test: String, membership: String) -> [String]? {
        guard
            let list = test.strippingAffixes(
                "idCatalogItem.GUID \(membership) (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d WHERE d.GUID IN (",
                ") AND d.CatalogItemGUID IS NOT NULL)"),
            let items = SQLScanner.split(list, on: ", ")
        else { return nil }
        let guids = items.compactMap(SQLScanner.stringValue)
        return guids.count == items.count ? guids : nil
    }

    private static func category(_ clause: String) -> FilterRule? {
        func branch(_ guids: [String]) -> CategoryBranch {
            CategoryBranch(rootGUID: guids.first ?? "", propGUIDs: guids)
        }
        if let guids = keywordGUIDs(clause, membership: "IN") {
            return .category(CategoryFilter(branches: [branch(guids)], mode: .any))
        }
        if let guids = keywordGUIDs(clause, membership: "NOT IN") {
            return .category(CategoryFilter(branches: [branch(guids)], mode: .none))
        }
        // "All of": one membership test per branch.
        guard let inner = SQLScanner.parenthesized(clause), let tests = SQLScanner.split(inner, on: " AND ") else {
            return nil
        }
        let branches = tests.compactMap { keywordGUIDs($0, membership: "IN") }.map(branch)
        guard branches.count == tests.count else { return nil }
        return .category(CategoryFilter(branches: branches, mode: .all))
    }

    private static func path(_ clause: String) -> FilterRule? {
        let negated = clause.hasPrefix("NOT ")
        guard
            let literal = (negated ? String(clause.dropFirst(4)) : clause).strippingAffixes(
                "EXISTS (SELECT 1 FROM idCache_FilePath fp WHERE fp.FilePathGUID = idCatalogItem.PathGUID"
                    + " AND (fp.FilePath || idCatalogItem.FileName) LIKE ",
                " ESCAPE '\\')"),
            let pattern = SQLScanner.stringValue(literal), let parts = LikePatternParts(pattern)
        else { return nil }
        let kind: PathMatchKind
        switch (parts.leadingWildcard, parts.trailingWildcard) {
        case (true, true): kind = .contains
        case (false, true): kind = .startsWith
        case (true, false): kind = .endsWith
        case (false, false): return nil
        }
        return .path(PathFilter(kind: kind, text: parts.literal, negated: negated))
    }

    private static func keywordPath(_ clause: String) -> FilterRule? {
        for (membership, negated) in [("IN", false), ("NOT IN", true)] {
            let prefix =
                "idCatalogItem.GUID \(membership) (SELECT d.CatalogItemGUID FROM idCatalogItemDefinition d"
                + " WHERE d.CatalogItemGUID IS NOT NULL AND d.GUID IN (" + KeywordPathFilter.keywordPathsQuery + " WHERE "
            guard let test = clause.strippingAffixes(prefix, " ESCAPE '\\'))") else { continue }
            let partSubject = KeywordPathFilter(kind: .hasPart, text: "").likeSubject + " LIKE "
            let isPartTest = test.hasPrefix(partSubject)
            guard let literal = test.strippingAffixes(isPartTest ? partSubject : "kp.path LIKE ", ""),
                let pattern = SQLScanner.stringValue(literal), let parts = LikePatternParts(pattern)
            else { return nil }

            let kind: KeywordPathMatchKind
            var text = parts.literal
            switch (isPartTest, parts.leadingWildcard, parts.trailingWildcard) {
            case (true, true, true):
                // `%\\text\\%`: the separators are part of the pattern.
                guard text.count >= 2, text.hasPrefix(KeywordPath.separator), text.hasSuffix(KeywordPath.separator)
                else { return nil }
                text = String(text.dropFirst().dropLast())
                kind = .hasPart
            case (false, true, true): kind = .contains
            case (false, false, true): kind = .startsWith
            case (false, true, false): kind = .endsWith
            default: return nil
            }
            return .keywordPath(KeywordPathFilter(kind: kind, text: text, negated: negated))
        }
        return nil
    }

    private static func keywordCount(_ clause: String) -> FilterRule? {
        guard let having = clause.components(separatedBy: " HAVING ").last?.dropLast() else { return nil }
        let condition = having.strippingAffixes("NOT (", ")") ?? String(having)
        let comparisons: [(String, (Int) -> KeywordCountFilter)] = [
            ("COUNT(DISTINCT d.GUID) = ", KeywordCountFilter.exactly),
            ("COUNT(DISTINCT d.GUID) >= ", KeywordCountFilter.atLeast),
            ("COUNT(DISTINCT d.GUID) <= ", KeywordCountFilter.atMost),
            ("COUNT(DISTINCT d.GUID) <> ", KeywordCountFilter.isNot),
        ]
        for (prefix, make) in comparisons {
            guard let number = condition.strippingAffixes(prefix, ""), let value = Int(number) else { continue }
            // Which of IN/NOT IN and HAVING/HAVING NOT depends on the
            // count, so the one check that holds for every case is
            // rendering it again.
            let filter = make(value)
            return filter.photoGUIDTest == clause ? .keywordCount(filter) : nil
        }
        return nil
    }
}

/// A `LIKE` pattern (written for `ESCAPE '\'`) of the one shape the
/// renderers build: optional `%` at each end around literal text.
/// `nil` for any other shape -- a `_` or `%` wildcard in the middle, or
/// a dangling escape. A pattern of a lone `%` reads as a trailing one.
struct LikePatternParts: Equatable {
    var leadingWildcard: Bool
    var literal: String
    var trailingWildcard: Bool

    init?(_ pattern: String) {
        var scalars = Array(pattern.unicodeScalars)
        trailingWildcard = scalars.last == "%" && !Self.isEscaped(scalars, at: scalars.count - 1)
        if trailingWildcard { scalars.removeLast() }
        leadingWildcard = scalars.first == "%"
        if leadingWildcard { scalars.removeFirst() }

        var text = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                guard index + 1 < scalars.count else { return nil }
                text.append(scalars[index + 1])
                index += 2
            } else if scalar == "%" || scalar == "_" {
                return nil
            } else {
                text.append(scalar)
                index += 1
            }
        }
        literal = String(text)
    }

    /// Whether the character at `index` follows an odd run of `\`s.
    private static func isEscaped(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var backslashes = 0
        var position = index - 1
        while position >= 0 && scalars[position] == "\\" {
            backslashes += 1
            position -= 1
        }
        return backslashes % 2 == 1
    }
}

/// Splitting and unquoting for the SQL text the renderers write.
enum SQLScanner {
    /// `text` split on `separator` wherever it appears outside string
    /// literals and parentheses. `nil` when the parentheses or quotes
    /// don't balance -- never text the renderers write.
    static func split(_ text: String, on separator: String) -> [String]? {
        let chars = Array(text)
        let sep = Array(separator)
        var parts: [String] = []
        var current: [Character] = []
        var depth = 0
        var inString = false
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if inString {
                current.append(char)
                if char == "'" {
                    // `''` is an escaped quote inside a literal.
                    if index + 1 < chars.count && chars[index + 1] == "'" {
                        current.append("'")
                        index += 1
                    } else {
                        inString = false
                    }
                }
                index += 1
                continue
            }
            if depth == 0 && chars[index...].starts(with: sep) {
                parts.append(String(current))
                current = []
                index += sep.count
                continue
            }
            switch char {
            case "'": inString = true
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth < 0 { return nil }
            default: break
            }
            current.append(char)
            index += 1
        }
        guard depth == 0, !inString else { return nil }
        parts.append(String(current))
        return parts
    }

    /// How deeply `text`'s parentheses nest, outside string literals. One
    /// pass, no recursion, so it's safe on any input.
    static func nesting(_ text: String) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        for char in text {
            if char == "'" {
                // `''` inside a literal toggles out and straight back in.
                inString.toggle()
            } else if !inString && char == "(" {
                depth += 1
                deepest = max(deepest, depth)
            } else if !inString && char == ")" {
                depth -= 1
            }
        }
        return deepest
    }

    /// The inside of `(...)` when the opening parenthesis is closed by the
    /// very last character -- `(a) OR (b)` is not parenthesized as a whole.
    static func parenthesized(_ text: String) -> String? {
        guard text.hasPrefix("("), text.hasSuffix(")") else { return nil }
        let inner = String(text.dropFirst().dropLast())
        // Balanced inside means the first "(" is the one the last ")" closes.
        guard split(inner, on: "\u{0}") != nil else { return nil }
        return inner
    }

    /// The value of a string expression `SQLStringLiteral` writes: quoted
    /// literals and `char(...)` calls joined with `||`.
    static func stringValue(_ expression: String) -> String? {
        guard let pieces = split(expression, on: " || ") else { return nil }
        var value = String.UnicodeScalarView()
        for piece in pieces {
            if let codes = piece.strippingAffixes("char(", ")") {
                for code in codes.components(separatedBy: ", ") {
                    guard let number = UInt32(code), let scalar = Unicode.Scalar(number) else { return nil }
                    value.append(scalar)
                }
            } else if piece.count >= 2, piece.hasPrefix("'"), piece.hasSuffix("'") {
                let body = piece.dropFirst().dropLast()
                // Every quote inside must be doubled.
                let unescaped = body.replacingOccurrences(of: "''", with: "")
                guard !unescaped.contains("'") else { return nil }
                value.append(contentsOf: body.replacingOccurrences(of: "''", with: "'").unicodeScalars)
            } else {
                return nil
            }
        }
        return String(value)
    }
}

// `extension` adds methods to an existing type, like a Rust trait
// implemented for `str`. `StringProtocol` covers `String` and `Substring`.
extension StringProtocol {
    /// The text between `prefix` and `suffix`, when it has both (and they
    /// don't overlap); otherwise `nil`.
    func strippingAffixes(_ prefix: String, _ suffix: String) -> String? {
        guard count >= prefix.count + suffix.count, hasPrefix(prefix), hasSuffix(suffix) else { return nil }
        return String(dropFirst(prefix.count).dropLast(suffix.count))
    }
}
