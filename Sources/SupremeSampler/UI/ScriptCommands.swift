import SwiftUI

/// The script's menu commands: File > Open Script… (⇧⌘O), File > Save
/// Script… (⌘S), replacing the standard Save item -- this app has no
/// documents of its own to save -- and Edit > Copy Script (⇧⌘C).
///
/// A `Commands` builder lives outside every window, so it can't read a
/// window's state directly. `@FocusedValue` is SwiftUI's channel for
/// that: the focused window publishes a value (`ContentView`'s
/// `.focusedSceneValue`), and the menu reads whichever window is in
/// front -- the menu-bar equivalent of reading React context from the
/// active window. (`Open Catalog…` predates this and uses a global
/// notification instead, which reaches every open window at once.)
struct ScriptCommands: Commands {
    @FocusedValue(\.openScriptAction) private var openScriptAction
    @FocusedValue(\.saveScriptAction) private var saveScriptAction
    @FocusedValue(\.copyScriptAction) private var copyScriptAction

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Open Script…") {
                openScriptAction?.perform()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(openScriptAction?.isEnabled != true)
            Button("Save Script…") {
                saveScriptAction?.perform()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveScriptAction?.isEnabled != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Script") {
                copyScriptAction?.perform()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(copyScriptAction?.isEnabled != true)
        }
    }
}

/// What the focused window offers one of the script commands.
struct ScriptCommandAction {
    let isEnabled: Bool
    let perform: () -> Void
}

/// Declares the command slots in SwiftUI's focused-value store, keyed by
/// a type rather than a string -- roughly a typed `React.createContext`
/// default.
private struct OpenScriptActionKey: FocusedValueKey {
    typealias Value = ScriptCommandAction
}

private struct SaveScriptActionKey: FocusedValueKey {
    typealias Value = ScriptCommandAction
}

private struct CopyScriptActionKey: FocusedValueKey {
    typealias Value = ScriptCommandAction
}

extension FocusedValues {
    var openScriptAction: ScriptCommandAction? {
        get { self[OpenScriptActionKey.self] }
        set { self[OpenScriptActionKey.self] = newValue }
    }

    var saveScriptAction: ScriptCommandAction? {
        get { self[SaveScriptActionKey.self] }
        set { self[SaveScriptActionKey.self] = newValue }
    }

    var copyScriptAction: ScriptCommandAction? {
        get { self[CopyScriptActionKey.self] }
        set { self[CopyScriptActionKey.self] = newValue }
    }
}
