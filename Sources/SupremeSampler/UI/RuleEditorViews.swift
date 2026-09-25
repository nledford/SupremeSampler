import AppKit
import SwiftUI

// The rule builder's editor, Lightroom Smart Collection style. Every rule
// is one line -- `[Field] [operator] [value] … [− +]` -- inside a
// bordered box per group; a nested group is a box inside its parent's,
// headed "[All / Any / None] of the following are true".
//
// Values that are lists (picked keywords, labels, file types, bookmarks)
// sit behind a button that summarizes the picks and opens the list in a
// popover, so rows stay one line even in a narrow window.
//
// `@Binding` (used throughout) is a two-way reference to a value owned
// somewhere else -- here, a slice of `SampleBuilderModel.rules`. It's
// the equivalent of React passing `value` plus `onChange` down as props,
// bundled into one handle: reading it reads the owner's value, writing
// it writes the owner's value.

/// One group: a header row, then a row per rule, all in one box.
/// Recursive -- a nested group is drawn by another `RuleGroupEditor`,
/// inside its parent's box.
struct RuleGroupEditor: View {
    @Binding var group: RuleGroupDraft
    let propTree: [CatalogPropNode]
    /// 0 for the root group.
    let depth: Int
    /// `nil` for the root group, which can't be removed. `(() -> Void)?`
    /// is an optional closure, like `(() => void) | undefined` in TS.
    let onRemove: (() -> Void)?
    /// The catalog's color labels, file types and bookmarks, for those
    /// rules' pickers.
    var labels: CatalogValues = .loading
    var fileTypes: CatalogValues = .loading
    var bookmarks: CatalogValues = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(8)

            if group.rules.isEmpty {
                Divider()
                Text(emptyGroupHint)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(8)
            }

            // Iterates the rules by value and hands each row a binding
            // looked up by `id` (see `binding(for:)`), rather than
            // `ForEach($group.rules)`'s index-based bindings -- removing a
            // row while SwiftUI still holds a binding to a now-out-of-range
            // index is a known crash with the index-based form.
            ForEach(group.rules) { rule in
                Divider()
                RuleRow(
                    rule: binding(for: rule),
                    propTree: propTree,
                    depth: depth,
                    actions: actions(for: rule),
                    labels: labels,
                    fileTypes: fileTypes,
                    bookmarks: bookmarks
                )
                .padding(8)
                // A nested group is its own box, with its own rows to
                // highlight; only a plain rule row lights up.
                .modifier(RowHoverHighlight(isEnabled: rule.field != nil))
            }
        }
        .ruleBox()
    }

    /// Kept short and on one line: an over-wide row squeezes its text
    /// into a tall sliver (seen in the running app, 2026-09-23).
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if depth == 0 {
                Text("Match")
                matchPicker(all: "all", any: "any", none: "none")
                Text("of the following rules:")
            } else {
                matchPicker(
                    all: "All of the following are true",
                    any: "Any of the following are true",
                    none: "None of the following are true")
            }
            Spacer(minLength: 0)
            if let onRemove {
                RemoveRuleButton(accessibilityLabel: "Remove group", action: onRemove)
            }
            // The header's "+" appends inside this group.
            AddRuleMenu(accessibilityLabel: depth == 0 ? "Add rule" : "Add rule to group", onAdd: addToGroup)
        }
        .contentShape(Rectangle())
        // Right-click anywhere on the header: the same actions as its
        // buttons, named, for anyone who never finds Option-click.
        .contextMenu {
            Button("Add Rule") { addToGroup(.rule) }
            Button("Add Nested Group") { addToGroup(.group) }
            if let onRemove {
                Divider()
                Button("Remove Group", role: .destructive, action: onRemove)
            }
        }
    }

    /// The header's "+": appends inside this group.
    private func addToGroup(_ choice: AddRuleMenu.Choice) {
        switch choice {
        case .rule: group.add(group.fieldForNewRule)
        case .group: group.addGroup()
        }
    }

    private func matchPicker(all: String, any: String, none: String) -> some View {
        Picker("Match", selection: $group.match) {
            Text(all).tag(GroupMatch.all)
            Text(any).tag(GroupMatch.any)
            Text(none).tag(GroupMatch.none)
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Spells out the vacuous case, since "matches everything" vs.
    /// "matches nothing" for an empty group isn't obvious.
    private var emptyGroupHint: String {
        switch group.match {
        case .all, .none: return "No rules yet, so this matches every photo. Click + to add one."
        case .any: return "No rules yet, so this matches no photos. Click + to add one."
        }
    }

    /// What a row's own controls do to this group. Each closure finds the
    /// row by `id` when it runs, so it stays right after edits elsewhere.
    /// `internal`, not `private`, so tests can press a row's "+".
    func actions(for rule: RuleDraft) -> RuleRowActions {
        RuleRowActions(
            changeField: { group.changeField(ofRule: rule.id, to: $0) },
            remove: { group.removeRule(id: rule.id) },
            add: { choice in
                switch choice {
                case .rule: group.insertRule(rule.field ?? group.fieldForNewRule, after: rule.id)
                case .group: group.insertGroup(after: rule.id)
                }
            }
        )
    }

    /// A `Binding` built by hand from a getter/setter pair -- like
    /// defining a JS property with `get`/`set`. Finds the rule by `id`
    /// on every access, so it stays correct after rows are added or
    /// removed; falls back to the last-seen value if the rule is gone.
    private func binding(for rule: RuleDraft) -> Binding<RuleDraft> {
        Binding(
            get: { group.rules.first { $0.id == rule.id } ?? rule },
            set: { updated in
                if let index = group.rules.firstIndex(where: { $0.id == rule.id }) {
                    group.rules[index] = updated
                }
            }
        )
    }
}

/// What a rule row's field picker, "−" and "+" do. A plain struct of
/// closures, like passing an object of callbacks as a React prop.
struct RuleRowActions {
    var changeField: (RuleField) -> Void
    var remove: () -> Void
    var add: (AddRuleMenu.Choice) -> Void

    /// Does nothing -- for previews and tests.
    static let none = RuleRowActions(changeField: { _ in }, remove: {}, add: { _ in })
}

/// One rule: `[Field] [operator] [value] … [− +]`, or a nested group.
struct RuleRow: View {
    @Binding var rule: RuleDraft
    let propTree: [CatalogPropNode]
    /// The depth of the group this row is in.
    let depth: Int
    let actions: RuleRowActions
    var labels: CatalogValues = .loading
    var fileTypes: CatalogValues = .loading
    var bookmarks: CatalogValues = .loading

    var body: some View {
        if case .group(let group) = rule.content {
            RuleGroupEditor(
                group: payload(fallback: group, { if case .group(let g) = $0 { return g }; return nil }, RuleDraft.Content.group),
                propTree: propTree,
                depth: depth + 1,
                onRemove: actions.remove,
                labels: labels,
                fileTypes: fileTypes,
                bookmarks: bookmarks
            )
        } else if let field = rule.field {
            // One line when it fits, as Lightroom draws it; otherwise the
            // operator and value drop to an indented second line rather
            // than squeezing or overflowing. `ViewThatFits` shows the
            // first child whose ideal width fits -- like a CSS container
            // query choosing between two layouts.
            ViewThatFits(in: .horizontal) {
                line(field: field, stacked: false)
                line(field: field, stacked: true)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button("Add Rule Below") { actions.add(.rule) }
                Button("Add Nested Group Below") { actions.add(.group) }
                Divider()
                Button("Remove Rule", role: .destructive, action: actions.remove)
            }
        }
    }

    /// The row's two layouts. `internal` so `RuleRowWidthTests` can
    /// measure each one.
    @ViewBuilder
    func line(field: RuleField, stacked: Bool) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    fieldPicker(field)
                    Spacer(minLength: 0)
                    rowButtons(field)
                }
                HStack(spacing: 8) {
                    fieldControls(field)
                }
                .padding(.leading, 16)
            }
        } else {
            HStack(spacing: 8) {
                fieldPicker(field)
                fieldControls(field)
                Spacer(minLength: 0)
                rowButtons(field)
            }
        }
    }

    private func fieldPicker(_ field: RuleField) -> some View {
        Picker("Field", selection: Binding(get: { field }, set: actions.changeField)) {
            SectionedPickerItems(sections: RuleField.menuSections) { Text($0.rawValue) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func fieldControls(_ field: RuleField) -> some View {
        controls
            // A new field is a new set of controls: without this, SwiftUI
            // could keep one field's typed-but-unsaved text (view
            // `@State`) for the next field in the same spot.
            .id(field)
    }

    @ViewBuilder
    private func rowButtons(_ field: RuleField) -> some View {
        RemoveRuleButton(accessibilityLabel: "Remove \(field.rawValue.lowercased()) rule", action: actions.remove)
        AddRuleMenu(accessibilityLabel: "Add rule after this one", onAdd: actions.add)
    }

    /// The operator and value controls for this row's field. `@ViewBuilder`
    /// lets a computed property return different view types per branch,
    /// like a JSX expression with a `switch` in it.
    @ViewBuilder
    private var controls: some View {
        switch rule.content {
        case .rating(let rating):
            RatingRuleControls(
                rule: payload(fallback: rating, { if case .rating(let r) = $0 { return r }; return nil }, RuleDraft.Content.rating))
        case .keyword(let keyword):
            KeywordRuleControls(
                rule: payload(fallback: keyword, { if case .keyword(let k) = $0 { return k }; return nil }, RuleDraft.Content.keyword),
                propTree: propTree)
        case .path(let path):
            PathRuleControls(
                rule: payload(fallback: path, { if case .path(let p) = $0 { return p }; return nil }, RuleDraft.Content.path))
        case .label(let label):
            LabelRuleControls(
                rule: payload(fallback: label, { if case .label(let l) = $0 { return l }; return nil }, RuleDraft.Content.label),
                labels: labels)
        case .fileType(let fileType):
            FileTypeRuleControls(
                rule: payload(
                    fallback: fileType, { if case .fileType(let f) = $0 { return f }; return nil }, RuleDraft.Content.fileType),
                fileTypes: fileTypes)
        case .bookmark(let bookmark):
            BookmarkRuleControls(
                rule: payload(
                    fallback: bookmark, { if case .bookmark(let b) = $0 { return b }; return nil }, RuleDraft.Content.bookmark),
                bookmarks: bookmarks)
        case .pendingDeletion(let deletion):
            PendingDeletionRuleControls(
                rule: payload(
                    fallback: deletion, { if case .pendingDeletion(let d) = $0 { return d }; return nil },
                    RuleDraft.Content.pendingDeletion))
        case .group:
            EmptyView()
        }
    }

    /// A binding to one case's payload inside `rule.content`: reads it
    /// out with `extract` (or the last-seen `fallback` if the case has
    /// since changed), writes an edit back with `embed`. `<Payload>` is a
    /// generic parameter, like Rust's `fn payload<P>(...)`; an enum case
    /// such as `RuleDraft.Content.rating` doubles as its constructor
    /// function, which is what `embed` receives. `internal` for tests.
    func payload<Payload>(
        fallback: Payload, _ extract: @escaping (RuleDraft.Content) -> Payload?,
        _ embed: @escaping (Payload) -> RuleDraft.Content
    ) -> Binding<Payload> {
        Binding(
            get: { extract(rule.content) ?? fallback },
            // Only while the rule is still this case: a late write from a
            // control the row has since replaced must not undo a field
            // change.
            set: { newValue in
                guard extract(rule.content) != nil else { return }
                rule.content = embed(newValue)
            }
        )
    }
}

/// "[is / is at least / …] [n stars]".
struct RatingRuleControls: View {
    @Binding var rule: RatingRuleDraft

    var body: some View {
        Picker("Comparison", selection: $rule.comparison) {
            ForEach(RatingComparisonKind.allCases) { kind in
                Text(kind.rawValue).tag(kind)
            }
        }
        .labelsHidden()
        .fixedSize()
        Stepper("\(rule.value) star\(rule.value == 1 ? "" : "s")", value: $rule.value, in: 0...5)
            .fixedSize()
    }
}

/// "[is any of …] [picked keywords ▾]" or "[has a part named …] [text]
/// [N keywords]". Picking a keyword includes its subcategories (see
/// `CategoryBranch`); path text is matched as `KeywordPathFilter` says.
struct KeywordRuleControls: View {
    @Binding var rule: KeywordRuleDraft
    let propTree: [CatalogPropNode]

    /// What's in the text field right now; `rule.text` catches up once
    /// typing pauses (see `DebouncedTextField`). The keyword hint follows
    /// this, not `rule.text`, so it updates as you type. `@State` is
    /// view-owned storage that survives re-renders -- like `useState` in
    /// React.
    @State private var typedText: String

    init(rule: Binding<KeywordRuleDraft>, propTree: [CatalogPropNode]) {
        _rule = rule
        self.propTree = propTree
        _typedText = State(initialValue: rule.wrappedValue.text)
    }

    var body: some View {
        Picker("Match", selection: $rule.operator) {
            SectionedPickerItems(sections: KeywordOperator.menuSections) { Text($0.rawValue) }
        }
        .labelsHidden()
        .fixedSize()

        if rule.operator.picksKeywords {
            ValuePickerButton(
                summary: ValueSummary.text(for: ValueSummary.keywordNames(for: rule.selectedGUIDs, in: propTree)),
                accessibilityLabel: "Keywords"
            ) {
                KeywordTreePicker(propTree: propTree, selection: $rule.selectedGUIDs)
            }
        } else {
            DebouncedTextField(
                title: "Keyword path text", prompt: "Nature\\Trees", text: $rule.text, typedText: $typedText,
                help: "A keyword's path is its categories and name joined by \\, like Nature\\Trees\\Oak. "
                    + "Case doesn't matter for A–Z.")
            if let hint = liveHint {
                KeywordMatchesButton(paths: hint)
            }
        }
    }

    /// The keywords the typed text matches right now, or `nil` with
    /// nothing typed.
    private var liveHint: [KeywordPath]? {
        var live = rule
        live.text = typedText
        guard !typedText.isEmpty, let filter = live.keywordPathFilter else { return nil }
        return filter.matchingKeywordPaths(in: KeywordPath.all(in: propTree))
    }
}

/// The category tree as a multi-select outline, for a popover.
struct KeywordTreePicker: View {
    let propTree: [CatalogPropNode]
    @Binding var selection: Set<String>

    var body: some View {
        if propTree.isEmpty {
            Text("No categories in this catalog.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // `children: \.childrenOrNil` makes this a real outline
                // view (disclosure triangles); `selection:` gives native
                // cmd/shift-click multi-select on macOS.
                List(propTree, children: \.childrenOrNil, selection: $selection) { node in
                    Text(node.name)
                }
                .frame(height: 300)
                Text("\(selection.count) selected, including their subcategories")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}

/// "N keywords" after a keyword path text; click for their paths.
struct KeywordMatchesButton: View {
    let paths: [KeywordPath]
    @State private var isShowingList = false

    var body: some View {
        Button("\(paths.count) keyword\(paths.count == 1 ? "" : "s")") { isShowingList = true }
            .buttonStyle(.link)
            .fixedSize()
            .help("Keywords whose path matches the text")
            // `.popover` shows a floating panel anchored to this view
            // while the bound flag is true -- like a controlled
            // `<Popover open={…}>` component in React.
            .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
                KeywordMatchesList(paths: paths)
                    .padding()
                    .frame(width: 320)
            }
    }
}

/// The paths a keyword path text matches.
struct KeywordMatchesList: View {
    let paths: [KeywordPath]

    var body: some View {
        if paths.isEmpty {
            Text("No keyword path matches this text.")
                .foregroundStyle(.secondary)
        } else {
            List(paths, id: \.guid) { path in
                Text(path.text)
            }
            .frame(height: 240)
        }
    }
}

/// "[contains / starts with / …] [text]", matched against the photo's
/// full path (folder plus file name).
struct PathRuleControls: View {
    @Binding var rule: PathRuleDraft
    @State private var typedText: String

    init(rule: Binding<PathRuleDraft>) {
        _rule = rule
        _typedText = State(initialValue: rule.wrappedValue.text)
    }

    var body: some View {
        Picker("Match", selection: $rule.operator) {
            SectionedPickerItems(sections: PathOperator.menuSections) { Text($0.rawValue) }
        }
        .labelsHidden()
        .fixedSize()
        DebouncedTextField(
            title: "Path text", prompt: "/travel/", text: $rule.text, typedText: $typedText,
            help: "Matched against the full path, folder and file name. Case doesn't matter for A–Z.")
    }
}

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

/// "[is any of / is none of] [picked labels ▾]". Shown exactly as
/// stored -- the real catalog mixes languages and imported values, and
/// which ones mean the same thing is the user's call, not the app's.
struct LabelRuleControls: View {
    @Binding var rule: LabelRuleDraft
    let labels: CatalogValues

    var body: some View {
        ValueModePicker(mode: $rule.mode)
        ValuePickerButton(
            summary: ValueSummary.text(for: labels, picked: rule.selectedLabels) { $0.isEmpty ? "No label" : $0 },
            accessibilityLabel: "Color labels"
        ) {
            CatalogValuePicker(values: labels, selection: $rule.selectedLabels, noun: "labels", emptyValueName: "No label")
        }
    }
}

/// "[is any of / is none of] [picked file types ▾]" -- the last
/// extension, lowercase.
struct FileTypeRuleControls: View {
    @Binding var rule: FileTypeRuleDraft
    let fileTypes: CatalogValues

    var body: some View {
        ValueModePicker(mode: $rule.mode)
        ValuePickerButton(
            summary: ValueSummary.text(for: fileTypes, picked: rule.selectedTypes) { $0.isEmpty ? "No extension" : $0 },
            accessibilityLabel: "File types"
        ) {
            CatalogValuePicker(
                values: fileTypes, selection: $rule.selectedTypes, noun: "file types", emptyValueName: "No extension")
        }
    }
}

/// "[is any of / is none of] [picked bookmarks ▾]", named the way the
/// earlier lusia tool uses them ("2 · Curated").
struct BookmarkRuleControls: View {
    @Binding var rule: BookmarkRuleDraft
    let bookmarks: CatalogValues

    var body: some View {
        ValueModePicker(mode: $rule.mode)
        ValuePickerButton(
            summary: ValueSummary.text(for: bookmarks, picked: rule.selectedValues) { value in
                Int(value).map(BookmarkFilter.displayName(for:)) ?? value
            },
            accessibilityLabel: "Bookmarks"
        ) {
            CatalogValuePicker(
                values: bookmarks, selection: $rule.selectedValues, noun: "bookmarks",
                displayName: { value in
                    guard let number = Int(value) else { return value }
                    return "\(number) · \(BookmarkFilter.displayName(for: number))"
                })
        }
    }
}

/// "[excluded / only]": photos the earlier lusia tool marked for
/// deletion (`Rating < 0`).
struct PendingDeletionRuleControls: View {
    @Binding var rule: PendingDeletionRuleDraft

    var body: some View {
        Picker("Pending deletion", selection: $rule.isPending) {
            Text("excluded").tag(false)
            Text("only").tag(true)
        }
        .labelsHidden()
        .fixedSize()
        .help("Photos marked for deletion have a negative rating.")
    }
}

/// "is any of / is none of", for rules over a list of values.
struct ValueModePicker: View {
    @Binding var mode: ValueMatchMode

    var body: some View {
        Picker("Match", selection: $mode) {
            Text("is any of").tag(ValueMatchMode.any)
            Text("is none of").tag(ValueMatchMode.none)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// A button showing a summary of the picked values; click to pick in a
/// popover. Generic over the popover's content: `<Content: View>` is a
/// type parameter with a bound, like Rust's `<C: View>` -- any view type
/// works, fixed per use.
struct ValuePickerButton<Content: View>: View {
    let summary: String
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content
    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = true
        } label: {
            HStack(spacing: 4) {
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 240, alignment: .leading)
        }
        .fixedSize()
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding()
            .frame(width: 320)
        }
    }
}

/// A row's or header's "+": click to add a rule; Option-click, or the
/// menu arrow, for a nested group (Lightroom's Option-click, plus a
/// visible way to find it).
struct AddRuleMenu: View {
    enum Choice: Equatable {
        case rule
        case group

        /// What a plain click on "+" adds.
        static func forClick(optionHeld: Bool) -> Choice {
            optionHeld ? .group : .rule
        }
    }

    let accessibilityLabel: String
    let onAdd: (Choice) -> Void

    var body: some View {
        // `Menu(content:label:primaryAction:)`: clicking the button runs
        // `primaryAction`; the small arrow beside it opens the menu -- a
        // split button.
        Menu {
            Button("Add Rule") { onAdd(.rule) }
            Button("Add Nested Group") { onAdd(.group) }
        } label: {
            Image(systemName: "plus.circle")
                .accessibilityLabel(accessibilityLabel)
        } primaryAction: {
            // `NSEvent` is AppKit, the older macOS UI framework under
            // SwiftUI; its class-level `modifierFlags` says which modifier
            // keys are held right now.
            onAdd(Choice.forClick(optionHeld: NSEvent.modifierFlags.contains(.option)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a rule. For a nested group, Option-click or use the arrow.")
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A picker's options in groups with a divider between each, so a long
/// menu reads as a few short runs. Each option is tagged with its own
/// value, as `Picker` needs. Generic over the option type, like a Rust
/// fn over `T: Hashable`.
struct SectionedPickerItems<Option: Hashable, ItemLabel: View>: View {
    let sections: [[Option]]
    @ViewBuilder let label: (Option) -> ItemLabel

    var body: some View {
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self) { option in
                label(option).tag(option)
            }
        }
    }
}

/// A faint wash behind a rule row under the pointer, tying the row's
/// "−" and "+" at the far right to the controls they act on. A
/// `ViewModifier` is a reusable bundle of modifiers with its own state,
/// like a React hook that also wraps markup.
struct RowHoverHighlight: ViewModifier {
    let isEnabled: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isEnabled && isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// The bordered box around a group's rows.
    func ruleBox() -> some View {
        background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A multi-select list of values read from the catalog, each with its
/// photo count, or the state of loading them.
struct CatalogValuePicker: View {
    let values: CatalogValues
    @Binding var selection: Set<String>
    /// Plural, for messages: "labels", "file types".
    let noun: String
    /// How to show the empty-string value, if it's meaningful.
    var emptyValueName: String = "(none)"
    /// How to show a value, when the stored form isn't readable on its
    /// own (a bookmark's number).
    var displayName: ((String) -> String)? = nil

    var body: some View {
        switch values {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading \(noun)…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label("Couldn't load \(noun): \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .loaded(let list):
            List(list, selection: $selection) { item in
                HStack {
                    if item.value.isEmpty {
                        Text(emptyValueName).italic()
                    } else {
                        Text(displayName?(item.value) ?? item.value)
                    }
                    Spacer()
                    Text(item.count, format: .number).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(height: 240)
            Text("\(selection.count) selected")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

/// The trailing "−" button on every removable row.
struct RemoveRuleButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
