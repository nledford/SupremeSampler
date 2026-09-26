import SwiftUI

// The rule builder's text fields, and the begin/end-of-edit hooks they
// report through. Kept apart from the controls that use them because the
// undo behavior they implement is subtle enough to be worth reading on
// its own (see `DebouncedTextField` and AGENTS.md, "A focused text field
// owns undo until it loses focus").

/// A text field whose value reaches `text` only after typing pauses for
/// 0.4s: every change re-runs the live count, and some counts scan every
/// photo (~2s for a file path), so updating per keystroke would stack up
/// queries. The row owns `typedText` so it can react to it right away.
struct DebouncedTextField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    @Binding var typedText: String
    let help: String

    /// The text this field last handed to `text` itself, so the sync
    /// below can tell its own commit from a change made elsewhere.
    @State private var committedText: String?

    /// Whether this field is being edited (`@FocusState`: keyboard
    /// focus as a plain bool, read and set declaratively).
    @FocusState private var isFocused: Bool

    /// Whether this field has told the model an edit began and not yet
    /// that it ended -- so a field removed mid-edit can still end it.
    @State private var isInEdit = false

    /// Text arriving from the model (an undo) on its way into the field;
    /// while set, losing focus mustn't commit the field's older text.
    @State private var incomingText: String?

    /// Tells the model when editing starts and ends (see
    /// `SampleBuilderModel.beginTextEditing`).
    @Environment(\.ruleTextEditing) private var textEditing

    var body: some View {
        TextField(title, text: $typedText, prompt: Text(prompt))
            .focused($isFocused)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120, idealWidth: 200, maxWidth: 280)
            .help(help)
            // `.task(id:)` restarts whenever `typedText` changes and
            // cancels the previous run -- so the sleep below is a
            // debounce, like clearing and resetting a `setTimeout`.
            .task(id: typedText) {
                guard typedText != text else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                committedText = typedText
                text = typedText
            }
            // The other direction: a change that didn't come from typing
            // here (Edit > Undo) must show in the field, or the next
            // keystroke would write the stale text back. Its own commit is
            // skipped, so a keystroke landing in between is never undone.
            //
            // Editing ends first: while the field is focused, AppKit's
            // field editor records any change to its text as typing on the
            // window's undo stack, so the next ⌘Z put the undone text
            // straight back (seen on screen, 2026-09-25). Ending editing
            // drops the field's own typing undo, and the text is set a
            // turn later, once it has.
            .onChange(of: text) {
                defer { committedText = text }
                guard text != committedText, text != typedText else { return }
                let external = text
                incomingText = external
                isFocused = false
                DispatchQueue.main.async {
                    typedText = external
                    incomingText = nil
                }
            }
            // Editing a field is one undo step, from focus to blur. What's
            // typed is committed on blur rather than after the debounce,
            // so it belongs to the edit being closed.
            .onChange(of: isFocused) { _, focused in
                if focused {
                    guard !isInEdit else { return }
                    isInEdit = true
                    textEditing.begin()
                } else {
                    if incomingText == nil, typedText != text {
                        committedText = typedText
                        text = typedText
                    }
                    endEdit()
                }
            }
            // A row removed or swapped for another field while its text
            // is being edited never loses focus the usual way.
            .onDisappear { endEdit() }
    }

    private func endEdit() {
        guard isInEdit else { return }
        isInEdit = false
        textEditing.end()
    }
}

/// The begin/end-of-edit calls a rule's text field makes, handed down by
/// `RuleBuilderView` through the environment -- like React context, so
/// the rows in between needn't pass them along. The defaults do nothing,
/// for previews and tests that render a row on its own.
struct RuleTextEditingHooks {
    var begin: () -> Void = {}
    var end: () -> Void = {}
}

private struct RuleTextEditingKey: EnvironmentKey {
    static let defaultValue = RuleTextEditingHooks()
}

extension EnvironmentValues {
    var ruleTextEditing: RuleTextEditingHooks {
        get { self[RuleTextEditingKey.self] }
        set { self[RuleTextEditingKey.self] = newValue }
    }
}
