import SwiftUI

// `View` is another protocol (~ Rust trait / TS interface); conforming
// types describe UI, they don't draw it directly. `ContentView` is a
// struct (value type) -- SwiftUI recreates and diffs these value
// descriptions cheaply and re-renders only what changed, similar in
// spirit to React re-rendering a function component and diffing the
// virtual DOM, except here the "component" is a Swift value, not a
// function call.
struct ContentView: View {
    // `@State` holding an `@Observable` reference type is the modern
    // (macOS 14+/Observation-framework) replacement for the older
    // `@StateObject` -- this view owns the model's lifetime (it's
    // created once, here, and survives view re-renders), and mutations
    // to any of its properties trigger re-renders of whatever reads them.
    @State private var model = SampleBuilderModel()

    /// Plain default init for real use (`ContentView()` in
    /// `SupremeSamplerApp`) -- relies on `model`'s own
    /// `= SampleBuilderModel()` default above. Declared explicitly only
    /// because defining the `model:` init below (needed for testing)
    /// suppresses Swift's normally-automatic memberwise init.
    init() {}

    /// Test seam: lets a test supply a pre-configured model (e.g. one
    /// with `injectCatalogForTesting` already called) to exercise the
    /// `NavigationSplitView` branch below, which `init()` above can
    /// never reach on its own. No default value here (unlike a more
    /// typical `model: SampleBuilderModel = SampleBuilderModel()`)
    /// because Swift evaluates a default *argument* expression in a
    /// separate, non-isolated context even when the initializer itself
    /// is `@MainActor` -- constructing the `@MainActor`-isolated
    /// `SampleBuilderModel` there fails to compile. `init()` above
    /// sidesteps that by using the *property's* default instead of a
    /// parameter's.
    ///
    /// `_model = State(wrappedValue: model)` is how you seed a `@State`
    /// property from a custom init -- the underscore-prefixed name
    /// reaches the property wrapper itself (`State<SampleBuilderModel>`)
    /// rather than the wrapped value, similar in spirit to reaching a
    /// Python property's underlying storage via `self.__dict__`, just a
    /// language feature here instead of a convention.
    @MainActor
    init(model: SampleBuilderModel) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        Group {
            if model.catalogPath == nil {
                CatalogPickerView(model: model)
            } else {
                NavigationSplitView {
                    SampleBuilderView(model: model)
                } detail: {
                    ScriptPreviewView(model: model)
                }
                .navigationTitle("SupremeSampler")
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        // `.task` runs once when the view first appears (and again if
        // its identity changes), the idiomatic SwiftUI hook for a one-
        // time startup action -- unlike putting this in `init()`, which
        // would be wrong here: SwiftUI can construct a View *value*
        // (running its init) many times over a single view's actual
        // on-screen lifetime as it re-diffs the tree, so an init isn't a
        // reliable "this happened once" signal the way it would be for
        // a class in Rust/TS/Python.
        .task {
            model.attemptAutoOpenRecentCatalog()
        }
    }
}

// `#Preview` is a Swift macro (compile-time code generation, vaguely like
// a Rust proc/attribute macro in mechanism) that Xcode uses to render this
// view in a live canvas while you edit -- conceptually similar to a
// Storybook story for a React component, but built into the IDE.
#Preview {
    ContentView()
}
