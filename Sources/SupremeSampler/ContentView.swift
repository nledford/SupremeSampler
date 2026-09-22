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
    }
}

// `#Preview` is a Swift macro (compile-time code generation, vaguely like
// a Rust proc/attribute macro in mechanism) that Xcode uses to render this
// view in a live canvas while you edit -- conceptually similar to a
// Storybook story for a React component, but built into the IDE.
#Preview {
    ContentView()
}
