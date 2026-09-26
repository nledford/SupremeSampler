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
        var scanner = Scanner(source: source)
        return scanner.run()
    }

    /// One pass over the source, emitting one token per run.
    ///
    /// A `struct` with `mutating` methods rather than one long function
    /// with nested closures: the cursor and the pending plain-text start
    /// are the only state, and each token kind's scan is then a small
    /// function of its own. (A Swift `struct` is a value type -- like a
    /// Rust struct, not a JS/Python class -- so `mutating` is how a
    /// method says it changes the receiver.)
    private struct Scanner {
        let source: String
        /// Walks Unicode scalars (code points). Their indices are also
        /// valid indices into `source`, so each token slices the original
        /// string directly. Swift strings can't be indexed by integer
        /// offset (like Rust's `str`, but stricter): positions are opaque
        /// `String.Index` values, advanced with `index(after:)`.
        let scalars: String.UnicodeScalarView
        var i: String.Index
        /// Where the current run of plain text began, if one is open.
        var plainStart: String.Index?
        var tokens: [PascalToken] = []

        init(source: String) {
            self.source = source
            self.scalars = source.unicodeScalars
            self.i = source.unicodeScalars.startIndex
        }

        mutating func run() -> [PascalToken] {
            while i < scalars.endIndex {
                let start = i
                switch tokenStart(at: i) {
                case .lineComment:
                    scanLineComment()
                    emit(.comment, from: start)
                case .braceComment:
                    skip(past: "}")
                    emit(.comment, from: start)
                case .parenComment:
                    i = scalars.index(i, offsetBy: 2)
                    skip(past: "*)")
                    emit(.comment, from: start)
                case .string:
                    scanString()
                    emit(.string, from: start)
                case .number:
                    scanNumber()
                    emit(.number, from: start)
                case .identifier:
                    scanIdentifier(from: start)
                case .plain:
                    if plainStart == nil { plainStart = start }
                    i = scalars.index(after: i)
                }
            }
            if let plain = plainStart {
                tokens.append(PascalToken(kind: .plain, text: source[plain...]))
            }
            return tokens
        }

        /// What the run starting at `index` is, decided by its first
        /// scalar (and, for the two-character openers, the one after).
        private enum TokenStart {
            case lineComment, braceComment, parenComment, string, number, identifier, plain
        }

        private func tokenStart(at index: String.Index) -> TokenStart {
            let c = scalars[index]
            if c == "/" && peek(1, from: index) == "/" { return .lineComment }
            if c == "{" { return .braceComment }
            if c == "(" && peek(1, from: index) == "*" { return .parenComment }
            if c == "'" { return .string }
            if isDigit(c) { return .number }
            if isIdentifierStart(c) { return .identifier }
            return .plain
        }

        /// The scalar `offset` past `index`, or `nil` at or past the end.
        private func peek(_ offset: Int, from index: String.Index) -> Unicode.Scalar? {
            guard let j = scalars.index(index, offsetBy: offset, limitedBy: scalars.endIndex),
                  j < scalars.endIndex else { return nil }
            return scalars[j]
        }

        /// Advances `i` to just past `terminator`, or to the end of the
        /// source if it never appears.
        private mutating func skip(past terminator: String) {
            let rest = source[i...]
            i = rest.range(of: terminator)?.upperBound ?? source.endIndex
        }

        private mutating func emit(_ kind: PascalToken.Kind, from start: String.Index) {
            if let plain = plainStart {
                tokens.append(PascalToken(kind: .plain, text: source[plain..<start]))
                plainStart = nil
            }
            tokens.append(PascalToken(kind: kind, text: source[start..<i]))
        }

        /// `//` up to, not including, the line break.
        private mutating func scanLineComment() {
            while i < scalars.endIndex && scalars[i] != "\n" { i = scalars.index(after: i) }
        }

        /// `'` to just past the closing quote, or the end of the line. A
        /// doubled quote is an escaped quote, inside the string.
        private mutating func scanString() {
            i = scalars.index(after: i)
            while i < scalars.endIndex && scalars[i] != "\n" {
                if scalars[i] == "'" {
                    if peek(1, from: i) == "'" {
                        i = scalars.index(i, offsetBy: 2)
                        continue
                    }
                    i = scalars.index(after: i)
                    break
                }
                i = scalars.index(after: i)
            }
        }

        /// Digits, plus a fractional part when a `.` is followed by
        /// another digit.
        private mutating func scanNumber() {
            while i < scalars.endIndex && isDigit(scalars[i]) { i = scalars.index(after: i) }
            if peek(0, from: i) == ".", let next = peek(1, from: i), isDigit(next) {
                i = scalars.index(after: i)
                while i < scalars.endIndex && isDigit(scalars[i]) { i = scalars.index(after: i) }
            }
        }

        /// A whole identifier at once, so `AEnd` or `ROWID2` never yields
        /// a keyword or number from its middle.
        private mutating func scanIdentifier(from start: String.Index) {
            while i < scalars.endIndex && isIdentifierPart(scalars[i]) { i = scalars.index(after: i) }
            if keywords.contains(source[start..<i].lowercased()) {
                emit(.keyword, from: start)
            } else if plainStart == nil {
                plainStart = start
            }
        }
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
