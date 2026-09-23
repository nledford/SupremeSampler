import XCTest

@testable import SupremeSampler

/// Specifies how folder balance weights a folder by its size. A sample
/// draws each photo's folder with probability proportional to its
/// weight, so the weight is the whole policy: `photos^1` is today's
/// plain random sample (every photo equally likely), `photos^0` makes
/// every folder equally likely, and `photos^0.5` sits between them.
final class FolderBalanceTests: XCTestCase {
    func test_givenOff_whenWeighingAFolder_thenItWeighsAsManyAsItsPhotos() {
        XCTAssertEqual(FolderBalance.off.weight(photoCount: 400), 400)
    }

    func test_givenBalanced_whenWeighingAFolder_thenItWeighsTheSquareRootOfItsPhotos() {
        XCTAssertEqual(FolderBalance.balanced.weight(photoCount: 400), 20)
    }

    func test_givenEqual_whenWeighingFolders_thenEveryFolderWeighsTheSame() {
        XCTAssertEqual(FolderBalance.equal.weight(photoCount: 1), 1)
        XCTAssertEqual(FolderBalance.equal.weight(photoCount: 9_987), 1)
    }

    func test_givenEachMode_whenComparingABigFolderToASmallOne_thenLaterModesFlattenTheGap() {
        // A 10,000-photo folder against a 100-photo one: 100x, 10x, 1x.
        let ratios = FolderBalance.allCases.map { $0.weight(photoCount: 10_000) / $0.weight(photoCount: 100) }
        XCTAssertEqual(ratios, [100, 10, 1])
    }

    func test_givenTheModes_whenListed_thenTheyRunFromOffToEqual() {
        XCTAssertEqual(FolderBalance.allCases, [.off, .balanced, .equal])
        XCTAssertEqual(FolderBalance.allCases.map(\.displayName), ["Off", "Balanced", "Equal"])
    }
}
