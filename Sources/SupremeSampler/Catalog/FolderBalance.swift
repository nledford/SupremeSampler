import Foundation

/// How a sample spreads across folders. Each photo in the sample comes
/// from a folder drawn with probability proportional to that folder's
/// `weight`, and then from a random photo inside it.
///
/// A folder is a photo's own folder (`idCatalogItem.PathGUID`), not a
/// top-level one: on the real catalog that is usually one set, and it
/// is what the `PathGUID` index covers. Surveyed 2026-09-23: tens of
/// thousands of folders, most small, but a few hundred of 500+ photos
/// held over a third of all photos -- mostly `[Archive]`'s fixed-size storage chunks -- which is what
/// "Off" lets dominate a sample.
///
/// `CaseIterable` gives the type an `allCases` array in declaration
/// order, like iterating a Rust enum with `strum::EnumIter` or
/// `Object.values()` over a TS enum; the picker lists the modes from it.
enum FolderBalance: CaseIterable, Hashable, Codable {
    /// Every photo equally likely: the plain random sample.
    case off
    /// A folder's weight is the square root of its size, so a folder
    /// 100x bigger is drawn 10x as often.
    case balanced
    /// Every folder equally likely, whatever its size.
    case equal

    /// The power a folder's photo count is raised to for its weight.
    var exponent: Double {
        switch self {
        case .off: return 1
        case .balanced: return 0.5
        case .equal: return 0
        }
    }

    func weight(photoCount: Int) -> Double {
        pow(Double(photoCount), exponent)
    }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .balanced: return "Balanced"
        case .equal: return "Equal"
        }
    }
}
