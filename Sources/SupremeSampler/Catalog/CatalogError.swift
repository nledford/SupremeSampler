import Foundation

/// Domain errors for opening/reading the Photo Supreme catalog.
///
/// A Swift `enum` with associated values is close to a Rust enum (e.g.
/// `enum CatalogError { FileNotFound { path: String } }`) or a TS
/// discriminated union -- much closer to those than to Python's usual
/// single-class-per-error-type exception style. Conforming to `Error`
/// (a protocol/marker, ~ Rust's `std::error::Error` trait) is what lets
/// Swift's `throw`/`try`/`catch` machinery use it.
enum CatalogError: Error, Equatable {
    /// The catalog file doesn't exist at the given path. Checked
    /// explicitly before opening so this reads as a clear domain error
    /// instead of an opaque SQLite "unable to open database file".
    case fileNotFound(path: String)
}
