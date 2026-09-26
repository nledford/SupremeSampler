import Foundation

/// The file name the save panel suggests for a script, built from what the
/// script samples: `Random` + one short PascalCase phrase per rule + a
/// folder-balance suffix, e.g. `RandomRated3PlusNoKeywordsBalanced.psc`.
/// Pure, like the generator; the save panel still lets the user rename.
///
/// - The two rules expected on every script -- pending deletion excluded,
///   bookmark "none of Hidden" -- are background, left out when they sit
///   at the top of an "all of" root (anywhere else they change what's
///   sampled, so they're named).
/// - Nothing left to name gives `PSCFile.suggestedFileName`, never the
///   reference script's name (the generator's tests compare against that
///   file, so a default save must not overwrite it).
/// - ASCII letters and digits only, like the scripts themselves: accents
///   fold ("Été" is "Ete"), anything else is dropped. That also keeps
///   every suggestion a safe file name.
/// - Sample size is left out: it's quick to change, and the script shows
///   it on its first lines.
enum ScriptFileName {
    /// Roughly how long the part after `Random` may grow before the rest
    /// of the root's rules become `Etc`. Soft: the first rule is always
    /// named in full, however long.
    static let softLimit = 60

    private static let prefix = "Random"
    private static let referenceStem = "RandomCatalogSample"

    /// `keywordName` looks up a picked keyword's name by GUID (from the
    /// catalog's keyword tree); `nil` means it's no longer in the tree.
    /// A closure parameter, like passing `impl Fn(&str) -> Option<String>`
    /// in Rust.
    static func suggest(
        for filter: SampleFilter, folderBalance: FolderBalance, keywordName: (String) -> String?
    ) -> String {
        let root = filter.root
        var body = ""
        if root.match == .all {
            // The root's rules one by one, so a long list can stop at a
            // rule boundary with `Etc` rather than mid-word.
            let phrases = root.rules.filter { !isBackground($0) }.compactMap { phrase(for: $0, keywordName) }
            for phrase in phrases {
                if !body.isEmpty && body.count + phrase.count > softLimit {
                    body += "Etc"
                    break
                }
                body += phrase
            }
        } else {
            body = phrase(for: .group(root), keywordName) ?? ""
        }

        switch folderBalance {
        case .off: break
        case .balanced: body += "Balanced"
        case .equal: body += "EqualFolders"
        }

        guard !body.isEmpty else { return PSCFile.suggestedFileName }
        var stem = prefix + body
        if stem == referenceStem { stem += "Filtered" }
        return stem + ".psc"
    }

    /// Top-level rules every script is expected to carry.
    private static func isBackground(_ rule: FilterRule) -> Bool {
        switch rule {
        case .pendingDeletion(false): return true
        case .bookmark(let bookmark): return bookmark.mode == .none && bookmark.values == [5]
        default: return false
        }
    }

    /// One rule's phrase, or `nil` when it narrows nothing worth naming
    /// (no text typed, nothing picked, or a name with no ASCII form).
    private static func phrase(for rule: FilterRule, _ keywordName: (String) -> String?) -> String? {
        switch rule {
        case .rating(let rating):
            switch rating {
            case .exactly(0): return "Unrated"
            case .exactly(let n): return "Rated\(n)"
            case .atLeast(let n): return "Rated\(n)Plus"
            case .atMost(let n): return "Rated\(n)OrLess"
            case .isNot(let n): return "NotRated\(n)"
            }

        case .keywordCount(let count):
            switch count {
            case .isEmpty: return "NoKeywords"
            case .isNotEmpty: return "WithKeywords"
            case .exactly(let n): return "Keywords\(n)"
            case .atLeast(let n): return "Keywords\(n)Plus"
            case .atMost(let n): return "Keywords\(n)OrLess"
            case .isNot(let n): return "KeywordsNot\(n)"
            }

        case .category(let category):
            // A keyword's own name, not its path: short, and the script's
            // header spells out the full rules anyway.
            let names = category.branches.compactMap { branch -> String? in
                guard let name = keywordName(branch.rootGUID) else { return "Keyword" }
                return nonEmpty(pascalCase(name))
            }
            guard !names.isEmpty else { return nil }
            switch category.mode {
            case .any: return names.joined(separator: "Or")
            case .all: return names.joined(separator: "And")
            case .none: return "No" + names.joined(separator: "Or")
            }

        case .keywordPath(let keywordPath):
            guard let words = nonEmpty(pascalCase(keywordPath.text)) else { return nil }
            return (keywordPath.negated ? "No" : "") + words

        case .path(let path):
            guard let words = nonEmpty(pascalCase(path.text)) else { return nil }
            return (path.negated ? "NotPath" : "Path") + words

        case .label(let label):
            guard !label.labels.isEmpty else { return nil }
            if label.mode == .any && label.labels == [""] { return "NoLabel" }
            let words = label.labels.compactMap { $0.isEmpty ? "None" : nonEmpty(pascalCase($0)) }
            guard !words.isEmpty else { return nil }
            return (label.mode == .any ? "Label" : "NotLabel") + words.joined(separator: "Or")

        case .fileType(let fileType):
            let words = fileType.extensions.compactMap { $0.isEmpty ? "NoExtension" : nonEmpty(pascalCase($0)) }
            guard !words.isEmpty else { return nil }
            return (fileType.mode == .any ? "" : "No") + words.joined(separator: "Or")

        case .bookmark(let bookmark):
            let words = bookmark.values.sorted().compactMap { nonEmpty(pascalCase(BookmarkFilter.displayName(for: $0))) }
            guard !words.isEmpty else { return nil }
            return (bookmark.mode == .any ? "" : "Not") + words.joined(separator: "Or")

        case .pendingDeletion(let isPending):
            return isPending ? "PendingDeletion" : "NotPendingDeletion"

        case .group(let group):
            let phrases = group.rules.compactMap { phrase(for: $0, keywordName) }
            guard !phrases.isEmpty else { return nil }
            switch group.match {
            case .all: return phrases.joined()
            case .any: return phrases.joined(separator: "Or")
            case .none: return "No" + phrases.joined(separator: "Or")
            }
        }
    }

    /// `text` as PascalCase ASCII words: accents folded, every run of
    /// other characters a word break, each word's first letter uppercased
    /// and the rest kept ("O'Brien" is "OBrien", "/2019/travel/" is
    /// "2019Travel", "Nature\Trees" is "NatureTrees").
    static func pascalCase(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: nil)
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }
}
