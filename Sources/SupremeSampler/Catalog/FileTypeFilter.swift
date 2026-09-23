import Foundation

/// A constraint on a photo's file type: the text after the *last* dot in
/// its file name, compared ignoring A-Z case -- so `c.lr_.jpg` is "jpg"
/// and `B.JPG` is "jpg" too. `""` is "no extension": no dot at all, or a
/// name ending in one. The real catalog is mostly jpg, with some png,
/// webp and gif, and a few thousand mkv videos a photo sample may want to leave
/// out.
struct FileTypeFilter: Equatable {
    /// Lowercase, without the dot.
    let extensions: [String]
    let mode: ValueMatchMode

    /// The SQL `LIKE` pattern, used with `ESCAPE '\'`, matching a file
    /// name whose last extension is `ext`. Ending in ".jpg" is the same
    /// test as "last extension is jpg" because an extension has no dot.
    static func likePattern(forExtension ext: String) -> String {
        let escaped = ext
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%." + escaped
    }
}
