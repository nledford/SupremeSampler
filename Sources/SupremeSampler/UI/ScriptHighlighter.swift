import SwiftUI

/// Colors the script preview: `PascalTokenizer`'s runs, each kind in its
/// own system color. System colors adapt to light and dark mode on their
/// own, and plain text gets no color at all, so it keeps the view's
/// default (like CSS `inherit`).
enum ScriptHighlighter {
    /// `AttributedString` is Foundation's styled text: a string plus
    /// attribute runs, like a list of `<span style=...>`s over one text.
    static func highlight(_ source: String) -> AttributedString {
        var result = AttributedString()
        for token in PascalTokenizer.tokenize(source) {
            var run = AttributedString(token.text)
            run.foregroundColor = color(for: token.kind)
            result.append(run)
        }
        return result
    }

    /// `Color?` is an optional (Rust `Option<Color>`); `nil` means "don't
    /// set one".
    static func color(for kind: PascalToken.Kind) -> Color? {
        switch kind {
        case .keyword: Color(nsColor: .systemPurple)
        case .comment: Color(nsColor: .secondaryLabelColor)
        case .string: Color(nsColor: .systemRed)
        case .number: Color(nsColor: .systemBlue)
        case .plain: nil
        }
    }
}
