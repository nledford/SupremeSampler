import SwiftUI

/// The File menu's "Save Script…" (⌘S), replacing the standard Save
/// item -- this app has no documents of its own to save.
///
/// A `Commands` builder lives outside every window, so it can't read a
/// window's state directly. `@FocusedValue` is SwiftUI's channel for
/// that: the focused window publishes a value (`ScriptPreviewView`'s
/// `.focusedSceneValue`), and the menu reads whichever window is in
/// front -- the menu-bar equivalent of reading React context from the
/// active window. (`Open Catalog…` predates this and uses a global
/// notification instead, which reaches every open window at once.)
struct SaveScriptCommands: Commands {
    @FocusedValue(\.saveScriptAction) private var saveScriptAction

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save Script…") {
                saveScriptAction?.perform()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveScriptAction?.isEnabled != true)
        }
    }
}

/// What the focused window offers the Save Script… command.
struct SaveScriptAction {
    let isEnabled: Bool
    let perform: () -> Void
}

/// Declares the `saveScriptAction` slot in SwiftUI's focused-value
/// store, keyed by a type rather than a string -- roughly a typed
/// `React.createContext` default.
private struct SaveScriptActionKey: FocusedValueKey {
    typealias Value = SaveScriptAction
}

extension FocusedValues {
    var saveScriptAction: SaveScriptAction? {
        get { self[SaveScriptActionKey.self] }
        set { self[SaveScriptActionKey.self] = newValue }
    }
}
