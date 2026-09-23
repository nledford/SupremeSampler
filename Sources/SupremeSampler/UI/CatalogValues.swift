import Foundation

/// A list of values read from the open catalog for a picker (its color
/// labels; its file types), and where loading it stands. A failure is
/// shown in the picker rather than failing the whole catalog open: the
/// other rules still work without it.
enum CatalogValues: Equatable {
    case loading
    case loaded([ValueCount])
    case failed(String)
}
