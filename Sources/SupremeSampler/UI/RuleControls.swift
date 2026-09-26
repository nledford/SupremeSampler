import SwiftUI

// One control per rule kind: the `[operator] [value]` half of a row,
// after `RuleRow`'s field picker. Each is a small `View` bound to its
// own draft type, so a row's field picker can swap one for another
// without the row knowing what any of them do.

/// "[is / is at least / …] [n stars]".
struct RatingRuleControls: View {
    @Binding var rule: RatingRuleDraft

    var body: some View {
        Picker("Comparison", selection: $rule.comparison) {
            ForEach(NumberComparisonKind.allCases) { kind in
                Text(kind.rawValue).tag(kind)
            }
        }
        .labelsHidden()
        .fixedSize()
        Stepper("\(rule.value) star\(rule.value == 1 ? "" : "s")", value: $rule.value, in: 0...5)
            .fixedSize()
    }
}

/// "[is / is at least / …] [n keywords]" -- how many keywords the photo
/// has (`KeywordCountFilter`).
struct KeywordCountRuleControls: View {
    @Binding var rule: KeywordCountRuleDraft

    var body: some View {
        Picker("Comparison", selection: $rule.comparison) {
            ForEach(NumberComparisonKind.allCases) { kind in
                Text(kind.rawValue).tag(kind)
            }
        }
        .labelsHidden()
        .fixedSize()
        Stepper("\(rule.value) keyword\(rule.value == 1 ? "" : "s")", value: $rule.value, in: 0...99)
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

        if !rule.operator.takesValue {
            // "is empty" / "is not empty": the operator says it all.
        } else if rule.operator.picksKeywords {
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
