import SwiftUI

// The rule builder's editor, Lightroom Smart Collection style: a group
// is a "Match [all/any/none] of" header followed by its rules, and a
// rule can be another group, rendered indented beneath its parent.
//
// Every view here produces one or more *rows* of the enclosing `Form`:
// a view whose body yields several views (a header plus a `ForEach`)
// is flattened into consecutive rows, so a nested group simply
// contributes more rows -- no nested scroll views or boxes. Nesting is
// shown by leading indentation.
//
// `@Binding` (used throughout) is a two-way reference to a value owned
// somewhere else -- here, a slice of `SampleBuilderModel.rules`. It's
// the equivalent of React passing `value` plus `onChange` down as props,
// bundled into one handle: reading it reads the owner's value, writing
// it writes the owner's value.

private let indentPerLevel: CGFloat = 16

/// One group: its "Match … of" header row, then a row per rule.
/// Recursive -- a nested group's rules are drawn by another
/// `RuleGroupEditor`, one level deeper.
struct RuleGroupEditor: View {
    @Binding var group: RuleGroupDraft
    let propTree: [CatalogPropNode]
    /// 0 for the root group; its rules are drawn at `depth + 1`.
    let depth: Int
    /// `nil` for the root group, which can't be removed. `(() -> Void)?`
    /// is an optional closure, like `(() => void) | undefined` in TS.
    let onRemove: (() -> Void)?

    var body: some View {
        // Kept short and on one line: the sidebar is narrow, and a row
        // wider than it squeezes its text into a tall sliver and pushes
        // the whole form off the left edge (seen in the running app).
        HStack {
            Text("Match")
            Picker("Match", selection: $group.match) {
                Text("all").tag(GroupMatch.all)
                Text("any").tag(GroupMatch.any)
                Text("none").tag(GroupMatch.none)
            }
            .labelsHidden()
            .fixedSize()
            Text("of:")
            Spacer(minLength: 0)
            // `Menu` is a pull-down button (a `<select>`-less dropdown of
            // actions); each `Button` inside it is one menu item.
            Menu {
                Button("Rating rule") { group.add(.rating) }
                Button("Category rule") { group.add(.category) }
                Button("File path rule") { group.add(.path) }
                Divider()
                Button("Nested group") { group.add(.group) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a rule or nested group")
            .accessibilityLabel(depth == 0 ? "Add rule" : "Add rule to group")
            if let onRemove {
                RemoveRuleButton(accessibilityLabel: "Remove group", action: onRemove)
            }
        }
        .padding(.leading, CGFloat(depth) * indentPerLevel)

        if group.rules.isEmpty {
            Text(emptyGroupHint)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.leading, CGFloat(depth + 1) * indentPerLevel)
        }

        // Iterates the rules by value and hands each row a binding
        // looked up by `id` (see `binding(for:)`), rather than
        // `ForEach($group.rules)`'s index-based bindings -- removing a
        // row while SwiftUI still holds a binding to a now-out-of-range
        // index is a known crash with the index-based form.
        ForEach(group.rules) { rule in
            RuleRow(
                rule: binding(for: rule),
                propTree: propTree,
                depth: depth + 1,
                onRemove: { group.removeRule(id: rule.id) }
            )
        }
    }

    /// Spells out the vacuous case, since "matches everything" vs.
    /// "matches nothing" for an empty group isn't obvious.
    private var emptyGroupHint: String {
        switch group.match {
        case .all, .none: return "No rules yet — matches every photo."
        case .any: return "No rules yet — matches no photos."
        }
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

/// Dispatches one rule to the row for its kind.
struct RuleRow: View {
    @Binding var rule: RuleDraft
    let propTree: [CatalogPropNode]
    let depth: Int
    let onRemove: () -> Void

    var body: some View {
        // `switch` over an enum with payloads, like Rust's `match`; each
        // case unwraps the payload and builds a binding that writes an
        // edited payload back into the same enum case.
        switch rule.content {
        case .rating(let rating):
            RatingRuleRow(
                rule: Binding(
                    get: {
                        if case .rating(let current) = rule.content { return current }
                        return rating
                    },
                    set: { rule.content = .rating($0) }
                ),
                onRemove: onRemove
            )
            .padding(.leading, CGFloat(depth) * indentPerLevel)
        case .category(let category):
            CategoryRuleRow(
                rule: Binding(
                    get: {
                        if case .category(let current) = rule.content { return current }
                        return category
                    },
                    set: { rule.content = .category($0) }
                ),
                propTree: propTree,
                onRemove: onRemove
            )
            .padding(.leading, CGFloat(depth) * indentPerLevel)
        case .path(let path):
            PathRuleRow(
                rule: Binding(
                    get: {
                        if case .path(let current) = rule.content { return current }
                        return path
                    },
                    set: { rule.content = .path($0) }
                ),
                onRemove: onRemove
            )
            .padding(.leading, CGFloat(depth) * indentPerLevel)
        case .group(let group):
            RuleGroupEditor(
                group: Binding(
                    get: {
                        if case .group(let current) = rule.content { return current }
                        return group
                    },
                    set: { rule.content = .group($0) }
                ),
                propTree: propTree,
                depth: depth,
                onRemove: onRemove
            )
        }
    }
}

/// "Rating [is / is at least / is at most] [n] stars".
struct RatingRuleRow: View {
    @Binding var rule: RatingRuleDraft
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Text("Rating")
            Picker("Comparison", selection: $rule.comparison) {
                ForEach(RatingComparisonKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()
            Stepper("\(rule.value) star\(rule.value == 1 ? "" : "s")", value: $rule.value, in: 0...5)
            Spacer()
            RemoveRuleButton(accessibilityLabel: "Remove rating rule", action: onRemove)
        }
    }
}

/// "Category [any of / all of / none of]" plus the category tree to pick
/// from. Picking a node includes its subcategories (see `CategoryBranch`).
struct CategoryRuleRow: View {
    @Binding var rule: CategoryRuleDraft
    let propTree: [CatalogPropNode]
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Category")
                Picker("Match", selection: $rule.mode) {
                    Text("Any of").tag(CategoryMatchMode.any)
                    Text("All of").tag(CategoryMatchMode.all)
                    Text("None of").tag(CategoryMatchMode.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                RemoveRuleButton(accessibilityLabel: "Remove category rule", action: onRemove)
            }

            if propTree.isEmpty {
                Text("No categories in this catalog.")
                    .foregroundStyle(.secondary)
            } else {
                // `children: \.childrenOrNil` makes this a real outline
                // view (disclosure triangles); `selection:` gives native
                // cmd/shift-click multi-select on macOS.
                List(propTree, children: \.childrenOrNil, selection: $rule.selectedGUIDs) { node in
                    Text(node.name)
                }
                .frame(height: 180)
                Text("\(rule.selectedGUIDs.count) selected, including their subcategories")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}

/// "Path [starts with / ends with / contains] [text]", matched against
/// the photo's full path (folder plus file name).
struct PathRuleRow: View {
    @Binding var rule: PathRuleDraft
    let onRemove: () -> Void

    /// What's in the text field right now, applied to `rule` only after
    /// typing pauses: every change re-runs the live count, and a path
    /// count scans every photo (~2s on the real catalog), so updating per
    /// keystroke would stack up queries. `@State` is view-owned storage
    /// that survives re-renders -- like `useState` in React.
    @State private var typedText: String

    init(rule: Binding<PathRuleDraft>, onRemove: @escaping () -> Void) {
        _rule = rule
        self.onRemove = onRemove
        _typedText = State(initialValue: rule.wrappedValue.text)
    }

    var body: some View {
        HStack {
            Text("Path")
            Picker("Match", selection: $rule.kind) {
                Text("contains").tag(PathMatchKind.contains)
                Text("starts with").tag(PathMatchKind.startsWith)
                Text("ends with").tag(PathMatchKind.endsWith)
            }
            .labelsHidden()
            .fixedSize()
            TextField("Path text", text: $typedText, prompt: Text("/travel/"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .help("Matched against the full path, folder and file name. Case doesn't matter for A–Z.")
                // `.task(id:)` restarts whenever `typedText` changes and
                // cancels the previous run -- so the sleep below is a
                // debounce, like clearing and resetting a `setTimeout`.
                .task(id: typedText) {
                    guard typedText != rule.text else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    rule.text = typedText
                }
            RemoveRuleButton(accessibilityLabel: "Remove path rule", action: onRemove)
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
