import Foundation

/// What the window was building when the app last ran: the rules, sample
/// size and folder balance, and the catalog they were built against.
/// Restored only for that same catalog, since keyword picks are catalog
/// GUIDs that mean nothing in another one.
///
/// `Codable` means the compiler writes the JSON encoding and decoding,
/// like `#[derive(Serialize, Deserialize)]` in Rust. Stored as JSON
/// through `RecentCatalogStore`. A saved session that no
/// longer decodes (the rule types changed shape in a later version) is
/// simply dropped -- losing an old draft beats refusing to launch.
struct SavedSession: Codable, Equatable {
    var catalogPath: String
    var rules: RuleGroupDraft
    var sampleSize: Int
    var folderBalance: FolderBalance

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// `nil` for missing or unreadable data. `try?` turns a thrown error
    /// into `nil`, like `.ok()` on a Rust `Result`.
    static func decode(_ data: Data?) -> SavedSession? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }
}

/// Encodes a menu enum by its case name (`isAnyOf`) rather than its raw
/// value, which is the text shown in the menu ("is any of"). Swift's
/// automatic `Codable` for a `String`-backed enum would store the label,
/// so a wording change in a later version would make every saved session
/// unreadable. `String(describing:)` on an enum case gives its name, like
/// `format!("{:?}", v)` on a fieldless Rust enum.
enum CaseNameCoding {
    static func encode<T>(_ value: T, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(describing: value))
    }

    static func decode<T: CaseIterable>(_ type: T.Type, from decoder: Decoder) throws -> T {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let value = T.allCases.first(where: { String(describing: $0) == name }) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "No case named \(name)")
        }
        return value
    }
}
