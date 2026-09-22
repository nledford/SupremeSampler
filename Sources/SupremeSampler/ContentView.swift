import SwiftUI

// `View` is another protocol (~ Rust trait / TS interface); conforming
// types describe UI, they don't draw it directly. `ContentView` is a
// struct (value type) -- SwiftUI recreates and diffs these value
// descriptions cheaply and re-renders only what changed, similar in
// spirit to React re-rendering a function component and diffing the
// virtual DOM, except here the "component" is a Swift value, not a
// function call.
struct ContentView: View {
    var body: some View {
        // VStack/Image/Text are all views themselves, nested like JSX
        // elements. Each `.modifier(...)` call below (`.font`,
        // `.foregroundStyle`, `.padding`, ...) does NOT mutate the view
        // in place -- like Rust iterator adapters (`.map().filter()`) or
        // JS array methods, each one returns a new, wrapped value. So
        // `Text(...).font(...).bold()` is really
        // `Bold(Font(Text(...)))` under the hood, just written fluently.
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("SupremeSampler")
                .font(.title2)
                .bold()
            Text("Scaffold placeholder — rule builder and script preview go here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding()
    }
}

// `#Preview` is a Swift macro (compile-time code generation, vaguely like
// a Rust proc/attribute macro in mechanism) that Xcode uses to render this
// view in a live canvas while you edit -- conceptually similar to a
// Storybook story for a React component, but built into the IDE.
#Preview {
    ContentView()
}
