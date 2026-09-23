import XCTest

@testable import SupremeSampler

/// Specifies the on-disk format of a saved script: the same as the
/// committed, verified-compiling `RandomCatalogSample.psc` in the scripts
/// repo -- UTF-8 with LF line endings and no byte-order mark. (Script
/// Studio itself re-saves files with CRLF, which also compiles, but turns
/// every line of a committed script into a git diff; the repo's history
/// is the curation audit trail, so files are written the way they're
/// committed.)
final class PSCFileTests: XCTestCase {
    func test_givenAScriptWithCRLFLineEndings_whenEncoding_thenTheyBecomeLF() {
        let data = PSCFile.encode("begin\r\n  OpenRandomSample;\r\nend;\r\n")

        XCTAssertEqual(data, Data("begin\n  OpenRandomSample;\nend;\n".utf8))
    }

    func test_givenAGeneratedScript_whenEncoding_thenItIsItsUTF8BytesWithNoByteOrderMark() {
        let script = RandomSampleScriptGenerator.generate(sampleSize: 100)
        let data = PSCFile.encode(script)

        XCTAssertEqual(data, Data(script.utf8))
        XCTAssertEqual(Array(data.prefix(2)), Array("{\n".utf8), "starts with the header brace, no BOM")
    }

    func test_givenAnUnfilteredScript_whenEncoding_thenTheBodyIsByteIdenticalToTheVerifiedReferenceScript() throws {
        guard let (reference, referenceSampleSize) = ReferenceScript.load() else {
            throw XCTSkip("RandomCatalogSample.psc not found at \(ReferenceScript.path) -- skipping cross-repo check")
        }
        let encoded = PSCFile.encode(RandomSampleScriptGenerator.generate(sampleSize: referenceSampleSize))

        // Everything from the first `const` on is meant to be identical;
        // before that, each file has its own header comment.
        func body(_ data: Data) -> Data {
            guard let range = data.range(of: Data("\nconst\n".utf8)) else { return Data() }
            return data[range.lowerBound...]
        }
        let referenceBody = body(Data(reference.utf8))
        XCTAssertGreaterThan(referenceBody.count, 1000, "found no `const` line -- has the reference script's format changed?")
        XCTAssertEqual(body(encoded), referenceBody)
    }

    func test_givenTheSuggestedFileName_whenSaving_thenItIsAPSCFileThatIsNotTheReferenceScript() {
        // The reference script is what the generator's tests compare
        // against; a save panel defaulting to its name invites
        // overwriting it.
        XCTAssertTrue(PSCFile.suggestedFileName.hasSuffix(".psc"))
        XCTAssertNotEqual(PSCFile.suggestedFileName, "RandomCatalogSample.psc")
    }

    // MARK: - Where the save panel starts

    func test_givenTheScriptsRepoExists_whenChoosingWhereToStart_thenTheSavePanelOpensThere() throws {
        let existing = FileManager.default.temporaryDirectory

        XCTAssertEqual(PSCFile.preferredDirectory(candidate: existing), existing)
    }

    func test_givenTheScriptsRepoIsMissing_whenChoosingWhereToStart_thenTheSavePanelDecides() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")

        XCTAssertNil(PSCFile.preferredDirectory(candidate: missing))
    }
}

/// The save panel is limited to `.psc` files and appends that extension
/// itself, so seeding its name field with "RandomSample.psc" showed
/// "RandomSample.psc.psc" (seen in the running app).
final class SavePanelNameFieldTests: XCTestCase {
    func test_givenASuggestedNameWithTheExtension_whenSeedingTheSavePanel_thenTheExtensionIsLeftToThePanel() {
        XCTAssertEqual(SavePanelDestinationChooser.nameFieldValue(for: "RandomSample.psc"), "RandomSample")
    }

    func test_givenASuggestedNameWithoutAnExtension_whenSeedingTheSavePanel_thenItIsUnchanged() {
        XCTAssertEqual(SavePanelDestinationChooser.nameFieldValue(for: "RandomSample"), "RandomSample")
    }
}
