import AppKit
import SwiftUI

/// The right-hand pane: a live, read-only preview of the generated
/// `.psc` source, with a Copy button. Copy-to-clipboard rather than
/// save-to-file is the deliberate v1 save action here -- paste into
/// Photo Supreme's Script Studio to review and test before it's ever
/// written to disk, matching how this was originally described.
struct ScriptPreviewView: View {
    var model: SampleBuilderModel

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

    private func copyToClipboard(_ text: String) {
        // NSPasteboard is AppKit's clipboard API -- macOS's equivalent
        // of the browser's `navigator.clipboard` in JS, or the
        // `arboard`/`copypasta` crates in Rust. SwiftUI has no clipboard
        // API of its own on macOS, so this is one of the occasional
        // drops down to AppKit directly.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

#Preview {
    ScriptPreviewView(model: SampleBuilderModel())
}
