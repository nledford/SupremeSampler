import AppKit
import Foundation

/// Writes text to the clipboard. A narrow protocol port -- same pattern
/// as `SampleBuilderCatalog`/`RecentCatalogStore` -- specifically so
/// tests never have to touch the *real* system pasteboard
/// (`NSPasteboard.general`), which is shared, global, mutable OS state:
/// a test that wrote to it for real would leave the last thing it
/// copied sitting in the user's actual clipboard after the test suite
/// finishes, silently clobbering whatever they'd copied before running
/// it. (This is not hypothetical -- an earlier version of
/// `ScriptPreviewView`'s test did exactly this.)
protocol ClipboardWriting: Sendable {
    func write(_ text: String)
}

/// The real implementation, backed by `NSPasteboard.general` -- macOS's
/// clipboard API, the equivalent of the browser's `navigator.clipboard`
/// in JS or the `arboard`/`copypasta` crates in Rust. SwiftUI has no
/// clipboard API of its own on macOS, so this is one of the occasional
/// drops down to AppKit directly.
struct SystemClipboard: ClipboardWriting {
    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
