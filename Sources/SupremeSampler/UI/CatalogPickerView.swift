import SwiftUI

/// Shown before a catalog is open. `.fileImporter` is SwiftUI's
/// file-picker modifier -- it drives the system Open panel and hands
/// back a `URL`, the same role `<input type="file">` plays in a web
/// app, or the `rfd`/`native-dialog` crates in Rust.
struct CatalogPickerView: View {
    var model: SampleBuilderModel

    @State private var isPickingFile = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("SupremeSampler")
                .font(.title2)
                .bold()
            Text("Open a Photo Supreme catalog (.cat.db) to build a sample.")
                .foregroundStyle(.secondary)
            if model.isOpeningCatalog {
                ProgressView("Opening catalog…")
            } else {
                Button("Open Catalog…") {
                    isPickingFile = true
                }
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 320)
        // `.item` (rather than a specific UTType) since Photo Supreme's
        // catalog file uses a non-standard double extension (".cat.db")
        // that has no registered system file type to filter on -- this
        // just opens the standard picker without restricting by kind.
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                // Security-scoped access: a no-op outside the App
                // Sandbox (this app isn't sandboxed -- see AGENTS.md).
                // Deliberately NOT paired with a matching
                // stopAccessingSecurityScopedResource() here:
                // openCatalog(at:) only *starts* its work (it launches a
                // Task and returns immediately) and this app keeps
                // querying the same file afterward as filters change, so
                // stopping right after this call would revoke access
                // before it's actually used, and again on every later
                // query. If sandboxing is ever turned on, the stop
                // belongs wherever the catalog is closed or replaced,
                // which doesn't exist yet -- there's currently no way to
                // close a catalog once opened.
                _ = url.startAccessingSecurityScopedResource()
                model.openCatalog(at: url.path)
            case .failure(let error):
                model.reportPickerFailure(error)
            }
        }
    }
}

#Preview {
    CatalogPickerView(model: SampleBuilderModel())
}
