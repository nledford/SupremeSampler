import AppKit
import UniformTypeIdentifiers

/// Asks the user where to save a script. A narrow protocol port, same
/// pattern as `ClipboardWriting`: the real one shows the system save
/// panel, which a unit test can't drive, so tests substitute a fake that
/// answers with a file in a temp folder.
///
/// `@MainActor` because a save panel is UI and must run on the main
/// thread. Returns `nil` when the user cancels -- an `async` function
/// returning an optional, like a Rust `async fn` returning `Option<Url>`.
@MainActor
protocol ScriptDestinationChoosing {
    func chooseDestination(suggestedFileName: String, startingIn directory: URL?) async -> URL?
}

/// The real implementation: `NSSavePanel`, AppKit's standard Save dialog
/// (SwiftUI's `.fileExporter` can't set a starting folder before macOS
/// 15, and this app targets 14). The panel handles "Replace existing
/// file?" itself, so a returned URL is always OK to write.
struct SavePanelDestinationChooser: ScriptDestinationChoosing {
    func chooseDestination(suggestedFileName: String, startingIn directory: URL?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Script"
        panel.nameFieldStringValue = Self.nameFieldValue(for: suggestedFileName)
        panel.allowedContentTypes = [UTType(filenameExtension: "psc", conformingTo: .plainText) ?? .plainText]
        panel.canCreateDirectories = true
        if let directory {
            panel.directoryURL = directory
        }

        // Shown as a sheet on the window when there is one, so the rules
        // can't be edited out from under the save. The panel reports back
        // through a completion callback; `withCheckedContinuation` bridges
        // that into `await` -- the same job as wrapping a callback API in
        // `new Promise(resolve => ...)` in JS.
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }

    /// The panel appends `.psc` itself (it's limited to that type), so
    /// it's given the bare name -- otherwise it shows
    /// "RandomSample.psc.psc".
    nonisolated static func nameFieldValue(for suggestedFileName: String) -> String {
        URL(fileURLWithPath: suggestedFileName).deletingPathExtension().lastPathComponent
    }
}
