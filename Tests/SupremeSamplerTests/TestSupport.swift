import Foundation
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
    static let path = "~/Projects/pascal/photo supreme/RandomCatalogSample.psc"

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
