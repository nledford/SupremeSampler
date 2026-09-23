import Foundation

/// Renders a text value as a SQLite string expression made of printable
/// ASCII only, for the SQL inside a generated script. Printable ASCII
/// runs become ordinary quoted literals (`'` doubled, SQL's escape);
/// anything else -- non-ASCII like "選択" or "’", or control characters
/// -- becomes `char(code, ...)`, SQLite's built-in function that makes a
/// string from Unicode code points. Pieces are joined with `||`, SQL's
/// string concatenation (like `+` on strings in JS/Python).
///
/// Why: it's unknown how Script Studio decodes a `.psc` file with no
/// byte-order mark, and a Delphi-lineage tool may assume the system code
/// page, turning raw UTF-8 "選択" into text that silently matches
/// nothing. ASCII bytes mean the same thing under any of those readings.
///
/// This is SQL-level quoting only; `PascalStringLiteral` wraps the whole
/// SQL text again when it's embedded in the script.
enum SQLStringLiteral {
    static func render(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }

        var pieces: [String] = []
        var asciiRun = ""
        var codePoints: [UInt32] = []

        func flushASCII() {
            guard !asciiRun.isEmpty else { return }
            pieces.append("'" + asciiRun.replacingOccurrences(of: "'", with: "''") + "'")
            asciiRun = ""
        }
        func flushCodePoints() {
            guard !codePoints.isEmpty else { return }
            pieces.append("char(" + codePoints.map(String.init).joined(separator: ", ") + ")")
            codePoints = []
        }

        // `unicodeScalars` walks code points, like Rust's `str::chars()`;
        // plain `for c in value` would walk grapheme clusters instead
        // (an emoji plus its modifiers counts as one), which is the
        // wrong unit for `char()`.
        for scalar in value.unicodeScalars {
            if (0x20...0x7E).contains(scalar.value) {
                flushCodePoints()
                asciiRun.unicodeScalars.append(scalar)
            } else {
                flushASCII()
                codePoints.append(scalar.value)
            }
        }
        flushASCII()
        flushCodePoints()
        return pieces.joined(separator: " || ")
    }
}
