import AppKit
import Foundation
import SwiftUI

@testable import SupremeSampler

extension SampleBuilderModel {
    /// How tests build a model: with an in-memory saved-path store, never
    /// the real one (see `SavedCatalogPathIsolationTests`). A test that
    /// cares about the store's contents passes its own.
    static func forTesting(
        catalogStore: any RecentCatalogStore = InMemoryRecentCatalogStore()
    ) -> SampleBuilderModel {
        SampleBuilderModel(catalogStore: catalogStore)
    }
}

/// The real, verified-compiling script in the sibling scripts repo that
/// the generator's boilerplate was transcribed from. Read from the
/// working copy, which may carry harmless local edits, so two things are
/// normalized away before comparing: line endings (Script Studio saves
/// CRLF; the committed file is LF) and the `SAMPLE_SIZE` value, which is
/// a parameter of the generator rather than boilerplate.
enum ReferenceScript {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/pascal/photo supreme/RandomCatalogSample.psc").path

    /// `nil` when the scripts repo isn't on this machine.
    static func load() -> (text: String, sampleSize: Int)? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // `firstMatch(of:)` with a regex literal, like Rust's
        // `Regex::captures` -- `.1` is the first capture group.
        guard let match = text.firstMatch(of: /SAMPLE_SIZE = (\d+);/), let size = Int(match.1) else { return nil }
        return (text, size)
    }
}

/// Stands in for the system save panel: records what it was asked,
/// and answers with a fixed destination (or `nil`, for Cancel).
final class FakeDestinationChooser: ScriptDestinationChoosing {
    let answer: URL?
    private(set) var askedFileName: String?
    private(set) var askedDirectory: URL?
    private(set) var timesAsked = 0

    init(answer: URL?) { self.answer = answer }

    func chooseDestination(suggestedFileName: String, startingIn directory: URL?) async -> URL? {
        timesAsked += 1
        askedFileName = suggestedFileName
        askedDirectory = directory
        return answer
    }
}

/// A SwiftUI view really rendered in a window, for behavior that only
/// happens while SwiftUI is drawing (`.onChange`, layout). Every test that
/// renders a view in a window goes through this, because two details
/// decide whether such a test means anything:
///
/// - **The window is put on screen.** A window that's built but never
///   displayed doesn't lay out like a real one, so an offscreen result
///   says little about the app. (2026-09-24: offscreen, a simple rule
///   tree hit AppKit's "Update Constraints in Window" loop where the same
///   window on screen didn't -- but on screen a fuller tree did, and so
///   did the real app, which crashed. Trust on-screen results.)
/// - **`close()` lets pending AppKit work finish.** AppKit reports some
///   exceptions a moment later; without a drain they land on whichever
///   test runs next and point the investigation at the wrong code.
@MainActor
final class HostedWindow {
    let window: NSWindow

    // `<Content: View>` is a generic type parameter (like Rust's
    // `<C: View>`), so any SwiftUI view can be hosted.
    init<Content: View>(_ view: Content, size: NSSize) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // `NSHostingView` puts a SwiftUI view inside an AppKit one.
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
    }

    /// Lets SwiftUI render and run its tasks until `condition` holds or
    /// `timeout` passes.
    func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Lets the window lay out and draw for a moment.
    func settle(for duration: Duration = .milliseconds(300)) async throws {
        try await Task.sleep(for: duration)
    }

    /// Closes the window, then gives AppKit a moment so anything it
    /// reports late is charged to the test that caused it.
    func close() async {
        window.orderOut(nil)
        window.close()
        try? await Task.sleep(for: .milliseconds(200))
    }
}
