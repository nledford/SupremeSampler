import Foundation

/// How many matching photos one folder holds -- one row of the audit
/// behind `FolderBalancePreview`. `path` is the folder's absolute path,
/// or `nil` when the catalog's path cache has no entry for it.
struct FolderPhotoCount: Equatable, Sendable {
    let path: String?
    let photos: Int
}

/// What a folder-balanced sample of the current filter would look like,
/// computed from per-folder photo counts: how many different folders it
/// would reach, and how it would split across top-level groups compared
/// with an unbalanced ("Off") sample. Pure -- the model fetches the
/// counts once per filter and rebuilds this whenever the mode or sample
/// size changes.
///
/// The numbers are expectations, from the same weights the script uses:
/// a group's share is its folders' total weight over everyone's, and a
/// folder is reached with probability `min(1, sampleSize * weight /
/// total)` -- exact for the script's systematic sampling. Folders too
/// small for their share (topped up at random by the script) are
/// ignored, so treat the numbers as approximate when the sample is
/// close to the number of matches.
struct FolderBalancePreview: Equatable {
    /// One top-level group of folders and the fraction of the sample
    /// expected to come from it.
    struct GroupShare: Equatable {
        let name: String
        let share: Double
        /// The same group's share with folder balance off, for comparison.
        let offShare: Double
    }

    let folderCount: Int
    /// About how many different folders the sample draws from.
    let expectedFolders: Int
    /// Largest share first; beyond `maxGroups`, the rest are folded into
    /// one "N others" entry.
    let groups: [GroupShare]

    init(folders: [FolderPhotoCount], balance: FolderBalance, sampleSize: Int, maxGroups: Int = 4) {
        folderCount = folders.count

        let weights = folders.map { balance.weight(photoCount: $0.photos) }
        let totalWeight = weights.reduce(0, +)
        let totalPhotos = Double(folders.reduce(0) { $0 + $1.photos })
        guard totalWeight > 0, totalPhotos > 0 else {
            expectedFolders = 0
            groups = []
            return
        }

        let reach = weights.reduce(0.0) { $0 + min(1, Double(sampleSize) * $1 / totalWeight) }
        expectedFolders = Int(reach.rounded())

        // `Dictionary(grouping:by:)` buckets values by a key, like
        // Python's `itertools.groupby` over unsorted input or Rust's
        // `fold` into a `HashMap<K, Vec<V>>`.
        let names = Self.groupNames(for: folders)
        let byGroup = Dictionary(grouping: folders.indices, by: { names[$0] })
        let shares = byGroup.map { name, indices in
            (
                share: GroupShare(
                    name: name,
                    share: indices.reduce(0.0) { $0 + weights[$1] } / totalWeight,
                    offShare: Double(indices.reduce(0) { $0 + folders[$1].photos }) / totalPhotos),
                photos: indices.reduce(0) { $0 + folders[$1].photos }
            )
        }
        // Largest share first; ties (common under "Equal") by photos,
        // then name, so the order never depends on hashing.
        let sorted = shares.sorted {
            ($0.share.share, $0.photos, $1.share.name) > ($1.share.share, $1.photos, $0.share.name)
        }.map(\.share)

        guard sorted.count > maxGroups + 1 else {
            groups = sorted
            return
        }
        let rest = sorted.dropFirst(maxGroups)
        groups = Array(sorted.prefix(maxGroups)) + [
            GroupShare(
                name: "\(rest.count) others",
                share: rest.reduce(0) { $0 + $1.share },
                offShare: rest.reduce(0) { $0 + $1.offShare }),
        ]
    }

    static let unknownFolderName = "(unknown folder)"

    /// Names each folder by its first path component below the deepest
    /// folder every known path shares. If one of those groups holds 99%+
    /// of the photos, its own subfolders are used instead (the others
    /// keep their names), and so on down -- on the real catalog, a tiny
    /// `videos` tree beside `photos` would otherwise leave just "photos"
    /// and "videos". A folder that *is* the shared folder is named after
    /// it.
    private static func groupNames(for folders: [FolderPhotoCount]) -> [String] {
        let parts = folders.map { folder in
            folder.path.map { $0.split(separator: "/").map(String.init) }
        }
        var names = folders.map { _ in unknownFolderName }
        var active = folders.indices.filter { parts[$0] != nil }
        guard let first = active.first.flatMap({ parts[$0] }) else { return names }

        var depth = first.count
        for index in active.dropFirst() {
            depth = min(depth, zip(first, parts[index]!).prefix { $0 == $1 }.count)
        }
        // A lone folder (or all-identical paths) shares every
        // component; step back one so it's named after itself.
        if active.allSatisfy({ parts[$0]!.count == depth }) {
            depth = max(depth - 1, 0)
        }

        let totalPhotos = Double(folders.reduce(0) { $0 + $1.photos })
        while true {
            // A nested function, closing over `depth` like a JS closure
            // or a Rust closure that borrows it.
            func name(_ index: Int) -> String {
                let path = parts[index]!
                return path.count > depth ? path[depth] : (path.last ?? "/")
            }
            let byName = Dictionary(grouping: active, by: name)
            let dominant = byName.first { _, members in
                Double(members.reduce(0) { $0 + folders[$1].photos }) >= 0.99 * totalPhotos
            }
            guard let (dominantName, members) = dominant,
                members.contains(where: { parts[$0]!.count > depth + 1 })
            else {
                for index in active { names[index] = name(index) }
                return names
            }
            for index in active where name(index) != dominantName {
                names[index] = name(index)
            }
            active = members
            depth += 1
        }
    }
}
