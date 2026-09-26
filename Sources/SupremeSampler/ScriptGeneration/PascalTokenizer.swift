import Foundation

/// One run of `.psc` source, for the script preview's syntax highlighting.
/// `text` is a `Substring`: a view into the original string that shares
/// its storage, like a Rust `&str` slice rather than an owned copy.
struct PascalToken: Equatable {
    enum Kind: Equatable { case keyword, comment, string, number, plain }
    let kind: Kind
    let text: Substring
}

/// Splits Object Pascal source into keywords, comments, string literals,
/// numbers and plain text. Built for the scripts this app generates -- a
/// preview, not a compiler: it knows the lexical rules that decide where
/// a comment or string starts and ends, and leaves everything else plain.
///
/// Lossless: the tokens' text, joined, is always exactly the input, so
/// the highlighted preview is the script that gets saved. Unterminated
/// comments run to the end of the source and unterminated strings to the
/// end of the line, rather than failing.
enum PascalTokenizer {
    /// Delphi's reserved words, plus the `True`/`False`/`nil` literals.
    /// Pascal is case-insensitive, so lookups are lowercased. `Set` is
    /// Swift's hash set (Rust `HashSet`, JS `Set`).
    static let keywords: Set<String> = [
        "and", "array", "as", "begin", "case", "class", "const", "constructor",
        "destructor", "div", "do", "downto", "else", "end", "except", "exports",
        "file", "finalization", "finally", "for", "function", "goto", "if",
        "implementation", "in", "inherited", "initialization", "interface", "is",
        "label", "library", "mod", "nil", "not", "object", "of", "or", "out",
        "packed", "procedure", "program", "property", "raise", "record", "repeat",
        "set", "shl", "shr", "string", "then", "threadvar", "to", "try", "type",
        "unit", "until", "uses", "var", "while", "with", "xor",
        "true", "false",
    ]

    static func tokenize(_ source: String) -> [PascalToken] {
        // Walks Unicode scalars (code points). Their indices are also valid
        // indices into `source`, so each token slices the original string
        // directly. Swift strings can't be indexed by integer offset (like
        // Rust's `str`, but stricter): positions are opaque `String.Index`
        // values, advanced with `index(after:)`.
        let scalars = source.unicodeScalars
        var tokens: [PascalToken] = []
        var plainStart: String.Index?
        var i = scalars.startIndex

        func peek(_ offset: Int) -> Unicode.Scalar? {
            guard let j = scalars.index(i, offsetBy: offset, limitedBy: scalars.endIndex),
                  j < scalars.endIndex else { return nil }
            return scalars[j]
        }

        /// Advances `i` to just past `terminator`, or to the end of the
        /// source if it never appears.
        func skip(past terminator: String) {
            let rest = source[i...]
            i = rest.range(of: terminator)?.upperBound ?? source.endIndex
        }

        func emit(_ kind: PascalToken.Kind, from start: String.Index) {
            if let plain = plainStart {
                tokens.append(PascalToken(kind: .plain, text: source[plain..<start]))
                plainStart = nil
            }
            tokens.append(PascalToken(kind: kind, text: source[start..<i]))
        }

        while i < scalars.endIndex {
            let start = i
            let c = scalars[i]

            if c == "/" && peek(1) == "/" {
                // Line comment: up to, not including, the line break.
                while i < scalars.endIndex && scalars[i] != "\n" { i = scalars.index(after: i) }
                emit(.comment, from: start)
            } else if c == "{" {
                skip(past: "}")
                emit(.comment, from: start)
            } else if c == "(" && peek(1) == "*" {
                i = scalars.index(i, offsetBy: 2)
                skip(past: "*)")
                emit(.comment, from: start)
            } else if c == "'" {
                // A doubled quote is an escaped quote, inside the string.
                i = scalars.index(after: i)
                while i < scalars.endIndex && scalars[i] != "\n" {
                    if scalars[i] == "'" {
                        if peek(1) == "'" {
                            i = scalars.index(i, offsetBy: 2)
                            continue
                        }
                        i = scalars.index(after: i)
                        break
                    }
                    i = scalars.index(after: i)
                }
                emit(.string, from: start)
            } else if isDigit(c) {
                while i < scalars.endIndex && isDigit(scalars[i]) { i = scalars.index(after: i) }
                if let dot = peek(0), dot == ".", let next = peek(1), isDigit(next) {
                    i = scalars.index(after: i)
                    while i < scalars.endIndex && isDigit(scalars[i]) { i = scalars.index(after: i) }
                }
                emit(.number, from: start)
            } else if isIdentifierStart(c) {
                // A whole identifier at once, so `AEnd` or `ROWID2` never
                // yields a keyword or number from its middle.
                while i < scalars.endIndex && isIdentifierPart(scalars[i]) { i = scalars.index(after: i) }
                if keywords.contains(source[start..<i].lowercased()) {
                    emit(.keyword, from: start)
                } else if plainStart == nil {
                    plainStart = start
                }
            } else {
                if plainStart == nil { plainStart = start }
                i = scalars.index(after: i)
            }
        }
        if let plain = plainStart {
            tokens.append(PascalToken(kind: .plain, text: source[plain...]))
        }
        return tokens
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(c)
    }

    private static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c) || c == "_"
    }

    private static func isIdentifierPart(_ c: Unicode.Scalar) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }
}
