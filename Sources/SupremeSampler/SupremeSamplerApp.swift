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
        // JSX/component composition -- `MainWindow()` here is roughly
        // `<MainWindow />`. The `{ ... }` is a trailing closure that
        // SwiftUI's "result builder" machinery turns into a view tree;
        // there's no equivalent construct in Rust/TS/Python, but the net
        // effect is the same as JSX children.
        WindowGroup {
            MainWindow()
        }
        // Wide enough for settings, one-line rules and the script side by
        // side (`RuleBuilderView.comfortableWidth`). Only a new window's
        // size: macOS restores a window's last size (at least
        // `ContentView`'s minimum) over this.
        .defaultSize(width: RuleBuilderView.defaultWindowWidth, height: 820)
        // `.commands { ... }` extends the app's menu bar -- the SwiftUI
        // analogue of a web app registering global keyboard shortcuts,
        // except these show up as real, discoverable File-menu items
        // too, not just invisible key handlers. `CommandGroup(after:)`
        // inserts alongside a named existing group (here, right after
        // the default "New Window" item) rather than replacing it.
        //
        // This can't call into `ContentView`'s state directly -- a
        // `Commands` builder lives outside any specific window's view
        // hierarchy, so the button posts a notification instead, which
        // `ContentView` listens for. See `Notification.Name
        // .openCatalogRequested` in ContentView.swift.
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Catalog…") {
                    NotificationCenter.default.post(name: .openCatalogRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            ScriptCommands()
        }
    }
}

/// One window's root: owns what that window remembers across launches.
/// `@SceneStorage` is `@State` saved with the window's restored state; it
/// only works inside a real app scene, so it lives here rather than in
/// `ContentView`, which tests render on their own.
struct MainWindow: View {
    @SceneStorage("showsScript") private var showsScript = true

    var body: some View {
        ContentView(showsScript: $showsScript)
    }
}
