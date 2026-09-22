import XCTest

@testable import SupremeSampler

// `@MainActor` on the test class: SampleBuilderModel is itself
// @MainActor-isolated (required for anything SwiftUI reads), so any code
// touching it -- including test code -- has to run on the main actor
// too. XCTest runs test methods on the main thread by default, but the
// *type checker* still needs this annotation to allow synchronous
// access to a MainActor type from here.
@MainActor
final class SampleBuilderModelTests: XCTestCase {
    // These tests only exercise `currentFilter`/`generatedScript`, both
    // pure computed properties with no catalog/file access -- unlike
    // PhotoSupremeCatalog's methods, nothing here needs a fixture.
    // openCatalog/refreshMatchingCount (the catalog-touching methods)
    // are exercised by hand via `just run`, not by an automated test in
    // this pass; SwiftUI view-model catalog integration is thin enough
    // here that PhotoSupremeCatalogTests' existing coverage of the
    // underlying queries carries most of the weight.

    func test_givenNoFiltersEnabled_whenComputingCurrentFilter_thenFilterIsUnconstrained() {
        let model = SampleBuilderModel()
        XCTAssertEqual(model.currentFilter, SampleFilter())
    }

    func test_givenRatingEnabled_whenComputingCurrentFilter_thenIncludesRatingFilter() {
        let model = SampleBuilderModel()
        model.ratingEnabled = true
        model.ratingComparison = .atLeast
        model.ratingValue = 4

        XCTAssertEqual(model.currentFilter, SampleFilter(rating: .atLeast(4)))
    }

    func test_givenRatingToggledBackOff_whenComputingCurrentFilter_thenRatingIsNilAgain() {
        let model = SampleBuilderModel()
        model.ratingEnabled = true
        model.ratingValue = 4
        model.ratingEnabled = false

        XCTAssertNil(model.currentFilter.rating)
    }

    func test_givenCategoryEnabled_whenComputingCurrentFilter_thenIncludesCategoryFilter() {
        let model = SampleBuilderModel()
        model.categoryEnabled = true
        model.categoryMode = .all
        model.selectedCategoryGUIDs = ["g1", "g2"]

        let category = model.currentFilter.category
        XCTAssertEqual(category?.mode, .all)
        XCTAssertEqual(Set(category?.propGUIDs ?? []), ["g1", "g2"])
    }

    func test_givenBothFiltersEnabled_whenComputingCurrentFilter_thenIncludesBoth() {
        let model = SampleBuilderModel()
        model.ratingEnabled = true
        model.ratingComparison = .exactly
        model.ratingValue = 5
        model.categoryEnabled = true
        model.categoryMode = .any
        model.selectedCategoryGUIDs = ["g1"]

        let filter = model.currentFilter
        XCTAssertEqual(filter.rating, .exactly(5))
        XCTAssertEqual(filter.category, CategoryFilter(propGUIDs: ["g1"], mode: .any))
    }

    func test_givenSampleSizeAndFilter_whenGeneratingScript_thenReflectsCurrentState() {
        let model = SampleBuilderModel()
        model.sampleSize = 250
        model.ratingEnabled = true
        model.ratingComparison = .exactly
        model.ratingValue = 5

        let script = model.generatedScript

        XCTAssertTrue(script.contains("SAMPLE_SIZE = 250;"))
        XCTAssertTrue(script.contains("Rating = 5"))
    }
}
