import XCTest

@testable import SupremeSampler

/// The keyword path rule's meaning, independent of SQL. Both predicate
/// renderers are checked against this same behavior in
/// `PredicateConsistencyTests`.
final class KeywordPathFilterTests: XCTestCase {
    private func filter(_ kind: KeywordPathMatchKind, _ text: String, negated: Bool = false) -> KeywordPathFilter {
        KeywordPathFilter(kind: kind, text: text, negated: negated)
    }

    // MARK: - One path

    func test_givenANestedKeyword_whenAPartIsNamedInAnyCase_thenItsPathMatches() {
        XCTAssertTrue(filter(.hasPart, "trees").matches(keywordPath: "Nature\\Trees\\Oak"))
    }

    func test_givenCharmAndArm_whenMatchingAPartNamedArm_thenOnlyArmMatches() {
        XCTAssertTrue(filter(.hasPart, "arm").matches(keywordPath: "Nature\\Arm"))
        XCTAssertFalse(filter(.hasPart, "arm").matches(keywordPath: "Style\\Charm"))
    }

    func test_givenCharmAndArm_whenMatchingPathsContainingArm_thenBothMatch() {
        XCTAssertTrue(filter(.contains, "arm").matches(keywordPath: "Nature\\Arm"))
        XCTAssertTrue(filter(.contains, "arm").matches(keywordPath: "Style\\Charm"))
    }

    func test_givenSeveralPartsInTheText_whenMatchingParts_thenTheyMustBeConsecutiveWholeParts() {
        XCTAssertTrue(filter(.hasPart, "Trees\\Oak").matches(keywordPath: "Nature\\Trees\\Oak"))
        XCTAssertFalse(filter(.hasPart, "Nature\\Oak").matches(keywordPath: "Nature\\Trees\\Oak"))
        XCTAssertFalse(filter(.hasPart, "elly\\Nave").matches(keywordPath: "Nature\\Trees\\Oak"))
    }

    func test_givenAPrefix_whenMatchingStartsWith_thenItIsALiteralPrefixNotAWholePart() {
        XCTAssertTrue(filter(.startsWith, "Nature\\Trees").matches(keywordPath: "Nature\\Trees\\Oak"))
        XCTAssertTrue(filter(.startsWith, "Nature\\Trees").matches(keywordPath: "Nature\\Treestand"))
        XCTAssertFalse(filter(.startsWith, "Trees").matches(keywordPath: "Nature\\Trees"))
    }

    func test_givenAKeywordName_whenMatchingEndsWith_thenOnlyPathsEndingThereMatch() {
        XCTAssertTrue(filter(.endsWith, "\\Oak").matches(keywordPath: "Nature\\Trees\\Oak"))
        XCTAssertFalse(filter(.endsWith, "\\Oak").matches(keywordPath: "Nature\\Trees\\Oak\\Pierced"))
    }

    func test_givenLikeWildcardsInTheText_whenMatching_thenTheyMeanThemselves() {
        XCTAssertTrue(filter(.contains, "100%").matches(keywordPath: "Crop\\100%"))
        XCTAssertFalse(filter(.contains, "1%0").matches(keywordPath: "Crop\\100"))
        XCTAssertTrue(filter(.contains, "a_b").matches(keywordPath: "x\\a_b"))
        XCTAssertFalse(filter(.contains, "a_b").matches(keywordPath: "x\\axb"))
    }

    /// SQLite's `LIKE` folds A-Z only, so the Swift meaning must too.
    func test_givenNonASCIILetters_whenMatching_thenCaseIsNotFolded() {
        XCTAssertTrue(filter(.contains, "TREES").matches(keywordPath: "Nature\\trees"))
        XCTAssertFalse(filter(.contains, "É").matches(keywordPath: "Style\\é"))
    }

    // MARK: - A photo's keywords

    func test_givenAPhotoWithNoKeywords_whenMatchingContains_thenItDoesNotMatch() {
        XCTAssertFalse(filter(.contains, "x").matchesPhoto(keywordPaths: []))
    }

    func test_givenAPhotoWithNoKeywords_whenMatchingDoesNotContain_thenItMatches() {
        XCTAssertTrue(filter(.contains, "x", negated: true).matchesPhoto(keywordPaths: []))
    }

    func test_givenAPhotoWithOneMatchingKeywordAmongOthers_whenNegated_thenItDoesNotMatch() {
        let photo = ["Nature\\Trees", "Places\\Beach"]

        XCTAssertTrue(filter(.hasPart, "Trees").matchesPhoto(keywordPaths: photo))
        XCTAssertFalse(filter(.hasPart, "Trees", negated: true).matchesPhoto(keywordPaths: photo))
    }

    func test_givenEmptyText_whenMatchingEitherWay_thenEveryPhotoMatches() {
        for kind in KeywordPathMatchKind.allCases {
            for negated in [false, true] {
                XCTAssertTrue(filter(kind, "", negated: negated).matchesPhoto(keywordPaths: []))
                XCTAssertTrue(filter(kind, "", negated: negated).matchesPhoto(keywordPaths: ["Nature"]))
            }
        }
    }
}
