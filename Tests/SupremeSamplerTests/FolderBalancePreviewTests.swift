import XCTest

@testable import SupremeSampler

/// Specifies the folder balance preview: from how many matching photos
/// each folder holds, what a balanced sample would look like -- how many
/// folders it would reach, and how it would split across the top-level
/// folders compared with an unbalanced sample.
final class FolderBalancePreviewTests: XCTestCase {
    private func folder(_ path: String?, _ photos: Int) -> FolderPhotoCount {
        FolderPhotoCount(path: path, photos: photos)
    }

    func test_givenFoldersUnderOneRoot_whenPreviewing_thenGroupsAreTheFoldersJustBelowIt() {
        let preview = FolderBalancePreview(
            folders: [
                folder("/Volumes/Photos/photos/Portraits/A/set 1/", 30),
                folder("/Volumes/Photos/photos/Portraits/B/", 10),
                folder("/Volumes/Photos/photos/[Archive]/Sets/Set39/", 60),
            ],
            balance: .off, sampleSize: 10)

        XCTAssertEqual(preview.groups.map(\.name), ["[Archive]", "Portraits"])
    }

    func test_givenOneGroupHoldingNearlyEverything_whenPreviewing_thenItIsSplitIntoItsOwnSubfolders() {
        // Seen on the real catalog: a tiny `videos` tree beside `photos`
        // made the groups "photos 100%" and "videos <1%", which says
        // nothing. A group with 99%+ of the photos is opened up instead.
        let preview = FolderBalancePreview(
            folders: [
                folder("/Volumes/Photos/library/photos/Portraits/A/", 600),
                folder("/Volumes/Photos/library/photos/[Archive]/Sets/", 400),
                folder("/Volumes/Photos/library/videos/clips/", 5),
            ],
            balance: .off, sampleSize: 10)

        XCTAssertEqual(preview.groups.map(\.name), ["Portraits", "[Archive]", "videos"])
    }

    func test_givenOff_whenPreviewing_thenEachGroupsShareIsItsShareOfThePhotos() {
        let preview = FolderBalancePreview(
            folders: [folder("/p/big/1/", 90), folder("/p/small/1/", 10)], balance: .off, sampleSize: 10)

        XCTAssertEqual(preview.groups, [
            .init(name: "big", share: 0.9, offShare: 0.9),
            .init(name: "small", share: 0.1, offShare: 0.1),
        ])
    }

    func test_givenBalanced_whenPreviewing_thenSharesFollowSquareRootWeightsAndKeepTheOffShareForComparison() {
        // Weights 9 and 1 (sqrt of 81 and 1): 90% / 10%, against 81/82
        // and 1/82 of the photos.
        let preview = FolderBalancePreview(
            folders: [folder("/p/big/1/", 81), folder("/p/small/1/", 1)], balance: .balanced, sampleSize: 10)

        XCTAssertEqual(preview.groups.map(\.name), ["big", "small"])
        XCTAssertEqual(preview.groups[0].share, 0.9, accuracy: 1e-12)
        XCTAssertEqual(preview.groups[0].offShare, 81.0 / 82, accuracy: 1e-12)
        XCTAssertEqual(preview.groups[1].share, 0.1, accuracy: 1e-12)
    }

    func test_givenManyGroups_whenPreviewing_thenTheSmallestAreFoldedIntoOther() {
        let folders = (1...6).map { folder("/p/g\($0)/x/", $0 * 10) }
        let preview = FolderBalancePreview(folders: folders, balance: .equal, sampleSize: 10, maxGroups: 3)

        // Equal: every folder weighs 1, so each group is 1/6; ties keep
        // the larger group (by photos) first.
        XCTAssertEqual(preview.groups.map(\.name), ["g6", "g5", "g4", "3 others"])
        XCTAssertEqual(preview.groups[3].share, 0.5, accuracy: 1e-12)
        XCTAssertEqual(preview.groups[3].offShare, 60.0 / 210, accuracy: 1e-12)
    }

    func test_givenOneGroupTooManyForTheLimit_whenPreviewing_thenItIsShownRatherThanCalledOther() {
        let folders = (1...4).map { folder("/p/g\($0)/x/", $0) }
        let preview = FolderBalancePreview(folders: folders, balance: .off, sampleSize: 10, maxGroups: 3)

        XCTAssertEqual(preview.groups.count, 4)
        XCTAssertFalse(preview.groups.contains { $0.name.hasSuffix("others") })
    }

    func test_givenEqualAndFewerPhotosThanFolders_whenPreviewing_thenEveryPhotoComesFromADifferentFolder() {
        let folders = (1...4).map { folder("/p/g\($0)/", 100) }

        XCTAssertEqual(FolderBalancePreview(folders: folders, balance: .equal, sampleSize: 3).expectedFolders, 3)
        XCTAssertEqual(FolderBalancePreview(folders: folders, balance: .equal, sampleSize: 50).expectedFolders, 4)
        XCTAssertEqual(FolderBalancePreview(folders: folders, balance: .equal, sampleSize: 50).folderCount, 4)
    }

    func test_givenOffWithOneHugeFolder_whenPreviewing_thenTheSampleReachesFewerFolders() {
        // Each tiny folder's chance is 5 * 1/1003 -- about 0.5% each.
        let folders = [folder("/p/huge/", 1000)] + (1...3).map { folder("/p/tiny\($0)/", 1) }
        let off = FolderBalancePreview(folders: folders, balance: .off, sampleSize: 5)
        let equal = FolderBalancePreview(folders: folders, balance: .equal, sampleSize: 5)

        XCTAssertEqual(off.expectedFolders, 1)
        XCTAssertEqual(equal.expectedFolders, 4)
    }

    func test_givenAFolderWithNoKnownPath_whenPreviewing_thenItIsGroupedAsUnknown() {
        let preview = FolderBalancePreview(
            folders: [folder("/p/a/1/", 5), folder("/p/b/1/", 5), folder(nil, 5)], balance: .off, sampleSize: 10)

        XCTAssertEqual(Set(preview.groups.map(\.name)), ["a", "b", "(unknown folder)"])
    }

    func test_givenOneFolder_whenPreviewing_thenItsGroupIsTheFolderItself() {
        let preview = FolderBalancePreview(folders: [folder("/p/only/", 5)], balance: .balanced, sampleSize: 10)

        XCTAssertEqual(preview.groups, [.init(name: "only", share: 1, offShare: 1)])
    }

    func test_givenPhotosDirectlyInTheSharedRoot_whenPreviewing_thenTheyAreGroupedUnderTheRootsName() {
        let preview = FolderBalancePreview(
            folders: [folder("/p/photos/", 5), folder("/p/photos/a/", 5)], balance: .off, sampleSize: 10)

        XCTAssertEqual(Set(preview.groups.map(\.name)), ["photos", "a"])
    }

    func test_givenNoMatchingFolders_whenPreviewing_thenItIsEmpty() {
        let preview = FolderBalancePreview(folders: [], balance: .balanced, sampleSize: 10)

        XCTAssertEqual(preview.folderCount, 0)
        XCTAssertEqual(preview.expectedFolders, 0)
        XCTAssertEqual(preview.groups, [])
    }
}
