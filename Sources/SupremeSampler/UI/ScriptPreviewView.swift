import SwiftUI

/// The right-hand pane: a live, read-only preview of the generated
/// `.psc` source, with a Copy button. Copy-to-clipboard rather than
/// save-to-file is the deliberate v1 save action here -- paste into
/// Photo Supreme's Script Studio to review and test before it's ever
/// written to disk, matching how this was originally described.
struct ScriptPreviewView: View {
    var model: SampleBuilderModel

    /// Defaults to the real system clipboard; tests substitute an
    /// in-memory fake instead (see `ClipboardWriting`'s doc comment for
    /// why that matters here specifically).
    var clipboard: any ClipboardWriting = SystemClipboard()

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Generated Script")
                    .font(.headline)
                Spacer()
                Button {
                    copyToClipboard(model.generatedScript)
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
            }

            ScrollView {
                Text(model.generatedScript)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding()
        .frame(minWidth: 420)
    }

    // `internal` (the default), not `private`: lets tests call this
    // directly with a known string and check the real clipboard
    // afterward, rather than only being reachable by simulating a
    // button tap, which a plain unit test can't do.
    func copyToClipboard(_ text: String) {
        clipboard.write(text)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

#Preview {
    ScriptPreviewView(model: SampleBuilderModel(catalogStore: InMemoryRecentCatalogStore()))
}
