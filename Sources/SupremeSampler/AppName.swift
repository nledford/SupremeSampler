import Foundation

/// The app's name as people see it ("Supreme Sampler"), for anything that
/// shows it: the window title, the catalog picker, the script header.
///
/// Its one source is `PRODUCT_NAME` in `project.yml`, which Xcode writes
/// into the bundle's `CFBundleName`; this reads it back rather than
/// spelling it out again. Not to be confused with `SupremeSampler`, the
/// module name code uses (see AGENTS.md, "App name").
///
/// A case-less `enum` is Swift's idiom for a namespace of static members
/// that can't be instantiated -- like a Rust module or a TS `namespace`.
enum AppName {
    /// `static let` is computed once, lazily, on first use (like Rust's
    /// `LazyLock`). The fallback is the process name, which Xcode also
    /// derives from `PRODUCT_NAME`; it only matters if the key is missing.
    static let current: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? ProcessInfo.processInfo.processName
}
