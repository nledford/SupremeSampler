import XCTest

@testable import SupremeSampler

/// The app's name as people see it is "Supreme Sampler"; `SupremeSampler`
/// (no space) is only the module/target name code uses. The visible name
/// has one source, `PRODUCT_NAME` in `project.yml`: Xcode derives the
/// bundle's file name, `CFBundleName` (the bold app-menu title) and the
/// executable (the process name) from it, and overwrites any other
/// `CFBundleName` while it generates the Info.plist. A `CFBundleDisplayName`
/// once renamed only some menu items, and an install-time rename left the
/// DMG shipping a different name (2026-09-26).
///
/// The test bundle is hosted in the app, so `Bundle.main` is the built app
/// itself -- like reading the real binary's metadata, not a fixture.
final class AppNameTests: XCTestCase {
    private static let appName = "Supreme Sampler"

    private func infoValue(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    func test_givenTheBuiltApp_whenReadingItsBundleName_thenItIsTheAppName() {
        XCTAssertEqual(infoValue("CFBundleName"), Self.appName)
    }

    func test_givenTheBuiltApp_whenReadingItsFileName_thenItIsTheAppName() {
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, Self.appName + ".app")
    }

    func test_givenTheBuiltApp_whenReadingItsExecutable_thenTheProcessIsNamedAfterTheApp() {
        XCTAssertEqual(infoValue("CFBundleExecutable"), Self.appName)
    }

    /// What the app shows (window title, picker heading, script header)
    /// reads the name back from the bundle instead of spelling it out.
    func test_givenTheBuiltApp_whenAskingForTheAppName_thenItIsTheBundleName() {
        XCTAssertEqual(AppName.current, Self.appName)
    }

    /// A display name would be a second copy of the name, free to drift
    /// from `PRODUCT_NAME` again.
    func test_givenTheBuiltApp_whenReadingItsDisplayName_thenThereIsNoSecondCopyOfTheName() {
        XCTAssertNil(infoValue("CFBundleDisplayName"))
    }
}
