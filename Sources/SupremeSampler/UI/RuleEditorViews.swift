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
        case .keywordCount(let keywordCount):
            KeywordCountRuleControls(
                rule: payload(
                    fallback: keywordCount, { if case .keywordCount(let k) = $0 { return k }; return nil },
                    RuleDraft.Content.keywordCount))
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
