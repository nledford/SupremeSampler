import Foundation

/// One version of the `.psc` layout this app writes -- the "schema" a
/// saved script follows. A `protocol` is Swift's interface (a C#
/// `interface`, a Rust trait): each format version is a type that can
/// write a script and read its settings back.
///
/// Every script carries its version in the header (`Script format: N`);
/// scripts saved before versions existed have no stamp and are format 1,
/// whose output they match line for line. `ScriptReader` checks a file
/// against *its own* format's output, so an unedited script from an older
/// version opens cleanly and is upgraded by saving it (which always
/// writes `ScriptFormats.latest`), while a hand edit is still reported.
///
/// To change what the generator writes: copy the current format into a
/// frozen type that keeps producing the old text (it's how old files are
/// recognized) -- all of it, including the SQL `SQLPredicateText` renders
/// for it and constants like `KeywordPathFilter.keywordPathsQuery`, since
/// `ScriptFormat1` calls the live generator -- bump
/// `RandomSampleScriptGenerator.formatVersion`, add the new format to
/// `ScriptFormats.all`, and override `settings(in:)` in the new one only
/// if the way settings are stored changed. `GoldenScriptTests` fails when
/// format 1's output changes, which is the reminder.
protocol ScriptFormat {
    var version: Int { get }

    func generate(sampleSize: Int, filter: SampleFilter, folderBalance: FolderBalance) -> String

    /// The settings a file in this format holds, or why it isn't one.
    func settings(in lines: [String]) -> Result<ScriptSettings, ScriptFormatError>
}

/// What a script is generated from: the same three things the window edits.
struct ScriptSettings: Equatable {
    var sampleSize: Int
    var folderBalance: FolderBalance
    var filter: SampleFilter
    /// Conditions in the SQL that weren't recognized, left out of `filter`.
    var unreadableClauses: [String]
}

/// Why a file isn't a script in some format -- shown to the user.
struct ScriptFormatError: Error, Equatable {
    let reason: String
}

enum ScriptFormats {
    /// Every format this version of the app can read, oldest first.
    /// `any ScriptFormat` is a value of some type conforming to the
    /// protocol, chosen at run time -- Rust's `Box<dyn ScriptFormat>`, or
    /// a C# variable typed as the interface.
    static let all: [any ScriptFormat] = [ScriptFormat1()]

    /// What saving writes.
    static var latest: any ScriptFormat { all[all.count - 1] }

    /// The header line naming a script's format.
    static let stampPrefix = "  Script format: "

    static func stamp(version: Int) -> String { stampPrefix + String(version) }

    /// The version a script's header names; 1 for a script saved before
    /// the stamp existed. `nil` for a stamp that isn't exactly
    /// `Script format: <number>`, or more than one stamp.
    static func version(of lines: [String]) -> Int? {
        let headerEnd = lines.firstIndex(of: "}") ?? 0
        let stamps = lines[..<headerEnd].filter { $0.hasPrefix(stampPrefix) }
        guard let stamp = stamps.first else { return 1 }
        guard stamps.count == 1, let version = Int(stamp.dropFirst(stampPrefix.count)), stamp == self.stamp(version: version)
        else { return nil }
        return version
    }
}

/// Format 1: the layout of the hand-verified `RandomCatalogSample.psc`
/// with filter SQL spliced in, written by `RandomSampleScriptGenerator`.
struct ScriptFormat1: ScriptFormat {
    let version = 1

    func generate(sampleSize: Int, filter: SampleFilter, folderBalance: FolderBalance) -> String {
        RandomSampleScriptGenerator.generate(sampleSize: sampleSize, filter: filter, folderBalance: folderBalance)
    }
}

// Default implementations for every format -- like a Rust trait's
// default methods, or a C# interface's default members. A later format
// overrides these only if it stores settings differently.
extension ScriptFormat {
    func settings(in lines: [String]) -> Result<ScriptSettings, ScriptFormatError> {
        guard let sampleSize = Self.sampleSize(in: lines) else {
            return .failure(ScriptFormatError(reason: "It doesn't set SAMPLE_SIZE, so it isn't a random sample script."))
        }
        let notOurs = ScriptFormatError(reason: "Its query for counting the catalog isn't one Supreme Sampler writes.")
        guard let countQuery = Self.countQuery(in: lines) else { return .failure(notOurs) }
        let predicate: String?
        if countQuery == Self.countQueryStart {
            predicate = nil
        } else if let filterText = countQuery.strippingAffixes(Self.countQueryStart + " WHERE ", "") {
            predicate = filterText
        } else {
            return .failure(notOurs)
        }
        if let predicate, SQLScanner.nesting(predicate) > SQLPredicateReader.maximumNesting {
            return .failure(ScriptFormatError(reason: "Its query nests far deeper than Supreme Sampler ever writes."))
        }
        let reading = SQLPredicateReader.read(predicate)
        return .success(
            ScriptSettings(
                sampleSize: sampleSize, folderBalance: Self.folderBalance(in: lines), filter: reading.filter,
                unreadableClauses: reading.unreadableClauses))
    }

    private static var countQueryStart: String {
        "SELECT COUNT(*) AS RowCount, MAX(rowid) AS MaxRowID FROM idCatalogItem"
    }

    private static func sampleSize(in lines: [String]) -> Int? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let number = trimmed.strippingAffixes("SAMPLE_SIZE = ", ";"), let size = Int(number), size > 0 {
                return size
            }
        }
        return nil
    }

    /// The SQL assigned on the line after `AExtentSet.CommandText :=`.
    private static func countQuery(in lines: [String]) -> String? {
        guard
            let index = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "AExtentSet.CommandText :="
            }),
            index + 1 < lines.count,
            let literal = lines[index + 1].trimmingCharacters(in: .whitespaces).strippingAffixes("", ";")
        else { return nil }
        return PascalStringLiteral.unescape(literal)
    }

    /// Off unless the script calls `BalancedItemGUIDs`; then the folder
    /// weight in its query says which kind. (If the weight was edited
    /// into something else, comparing with the regenerated script says so.)
    private static func folderBalance(in lines: [String]) -> FolderBalance {
        guard lines.contains(where: { $0.contains("BalancedItemGUIDs(SAMPLE_SIZE)") }) else { return .off }
        let weights = FolderBalance.allCases.filter { balance in
            balance != .off
                && lines.contains { $0.contains(FolderBalanceSQL.weight(balance, photoCount: "COUNT(*)") + " AS Weight") }
        }
        return weights.first ?? .balanced
    }
}
