import SwiftUI

/// The collapsible right-hand pane: a live, read-only preview of the
/// generated `.psc` source. Only a preview -- Copy and Save… are in the
/// window's toolbar (`ScriptToolbarButtons`) and the menus, so they keep
/// working while this pane is hidden.
struct ScriptPreviewView: View {
    static let minimumWidth: CGFloat = 320
    static let idealWidth: CGFloat = 400

    var model: SampleBuilderModel

    /// The script with Pascal syntax colors (`ScriptHighlighter`). Only the
    /// preview is colored; Copy and Save… still write the plain text.
    var highlightedScript: AttributedString {
        ScriptHighlighter.highlight(model.generatedScript)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generated Script")
                .font(.headline)

            // Scrolls both ways and never wraps: Script Studio shows the
            // file one source line per line, and its error positions are
            // line numbers, so the preview keeps the same lines.
            ScrollView([.horizontal, .vertical]) {
                Text(highlightedScript)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding()
    }
}

#Preview {
    ScriptPreviewView(model: SampleBuilderModel(catalogStore: InMemoryRecentCatalogStore()))
}
