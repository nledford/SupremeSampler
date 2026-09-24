import Foundation

/// The on-disk form of a generated script. Pure, like the generator:
/// no file I/O here, just bytes and names.
///
/// Matches the committed, verified-compiling `RandomCatalogSample.psc`:
/// UTF-8, LF line endings, no byte-order mark. Script Studio re-saves
/// files with CRLF -- which compiles too -- but the scripts repo commits
/// LF, and its git history is the curation audit trail, so a CRLF file
/// would show every line as changed.
enum PSCFile {
    /// Deliberately not `RandomCatalogSample.psc` -- that's the verified
    /// reference script the generator's tests compare against, and a
    /// save panel defaulting to its name invites overwriting it. The
    /// scripts repo's convention is to name each file after its purpose,
    /// so this is a starting point to rename, not a final name.
    static let suggestedFileName = "RandomSample.psc"

    /// Where generated scripts live: a separate git repo whose history
    /// is the curation audit trail (see AGENTS.md). Hard-coded because
    /// this is a one-user tool (PRODUCT.md); `preferredDirectory` falls
    /// back gracefully when it isn't there. Built from the home folder
    /// (`~` isn't expanded in a file URL, unlike in a shell).
    static let scriptsRepository = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/pascal/photo supreme", isDirectory: true)

    /// The script's UTF-8 bytes with every line ending as LF (a CRLF
    /// that slipped in is normalized, not doubled).
    static func encode(_ script: String) -> Data {
        let normalized = script.replacingOccurrences(of: "\r\n", with: "\n")
        // `Data(string.utf8)` is the raw UTF-8 bytes -- like Rust's
        // `s.as_bytes().to_vec()` -- and never adds a BOM.
        return Data(normalized.utf8)
    }

    /// The folder a save panel should open in: `candidate` if it's an
    /// existing directory, otherwise `nil` (let the panel decide).
    static func preferredDirectory(candidate: URL = scriptsRepository) -> URL? {
        // `ObjCBool` + `&isDirectory` is an out-parameter, a holdover
        // from Objective-C -- the same shape as passing `&mut bool` in
        // Rust for the callee to fill in.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? candidate : nil
    }
}
