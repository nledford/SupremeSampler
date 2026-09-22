import SwiftUI

// `@main` marks the process entry point, like `fn main()` in Rust or
// `if __name__ == "__main__":` in Python -- there's exactly one of these
// per executable.
//
// `App` is a protocol (~ a Rust trait, or a TS `interface` you implement).
// `struct ... : App` means "this value type conforms to the App protocol",
// not inheritance -- Swift structs don't have subclassing at all, closer to
// Rust structs implementing a trait than to a JS/Python class hierarchy.
@main
struct SupremeSamplerApp: App {
    // `some Scene` is an opaque return type: "some concrete type that
    // conforms to Scene, decided by the compiler from the body below, but
    // callers can't see which one." Directly analogous to Rust's
    // `-> impl Scene`. `var body: some Scene { ... }` is a computed
    // property (a getter with no stored backing field), not a stored
    // field -- closer to a Python `@property` or a JS getter than to a
    // plain struct field.
    var body: some Scene {
        // WindowGroup { ... } is SwiftUI's declarative UI style: you
        // describe *what* the window contains, not imperative
        // create-and-append calls. If you know React, this reads like
        // JSX/component composition -- `ContentView()` here is roughly
        // `<ContentView />`. The `{ ... }` is a trailing closure that
        // SwiftUI's "result builder" machinery turns into a view tree;
        // there's no equivalent construct in Rust/TS/Python, but the net
        // effect is the same as JSX children.
        WindowGroup {
            ContentView()
        }
    }
}
