import SwiftUI

/// The collapsible right-hand pane: a live, read-only preview of the generated
/// `.psc` source, with Copy (paste into Script Studio to try it out) and
/// Save… (write a `.psc` file, normally into the scripts repo). Save
/// waits for the pre-flight count -- see `SampleBuilderModel.canSaveScript`.
struct ScriptPreviewView: View {
    static let minimumWidth: CGFloat = 360
    static let idealWidth: CGFloat = 460

    var model: SampleBuilderModel

    /// Defaults to the real system clipboard; tests substitute an
    /// in-memory fake instead (see `ClipboardWriting`'s doc comment for
    /// why that matters here specifically).
    var clipboard: any ClipboardWriting = SystemClipboard()

    /// Defaults to the real save panel; tests substitute a fake that
    /// answers with a temp file.
    var destinationChooser: any ScriptDestinationChoosing = SavePanelDestinationChooser()

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
                Button {
                    // A button action is synchronous; `Task { ... }` starts
                    // the async save without blocking it, like calling an
                    // `async` function without awaiting it in JS.
                    Task { await saveScript() }
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.canSaveScript)
                .help(model.canSaveScript ? "Save as a .psc file" : "Available once the match count has finished")
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
        // ⌘S is registered by `ContentView`, not here: this pane can be
        // hidden, and a hidden pane's views are gone.
    }

    /// Opens the save panel in the scripts repo (when it exists) and
    /// writes the file. `internal`, like `copyToClipboard`, so tests can
    /// call it directly with a fake chooser.
    func saveScript() async {
        await model.saveScript(using: destinationChooser, startingIn: PSCFile.preferredDirectory())
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
