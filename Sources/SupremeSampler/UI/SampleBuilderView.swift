import SwiftUI

/// The left-hand rule builder: sample size, a rating rule, a category
/// rule, and the live pre-flight match count -- the Lightroom Smart
/// Collection-style interface this app was built around.
struct SampleBuilderView: View {
    // `@Bindable` is what lets `$model.sampleSize` etc. work below: it
    // derives a two-way `Binding` for each stored property of an
    // `@Observable` reference, the way Vue's `v-model` or Svelte's
    // `bind:value` wire a form control straight to a piece of state.
    // Rust has no close built-in equivalent -- the nearest analogues are
    // reactive-framework-specific (Leptos/Dioxus signals), not a
    // language feature.
    @Bindable var model: SampleBuilderModel

    var body: some View {
        Form {
            Section("Sample") {
                // A number field rather than a bare `Stepper`: the old
                // control could only be nudged 100 at a time, so reaching
                // a value like 25000 meant 250 clicks. This is the SwiftUI
                // equivalent of `<input type="number">` -- a `TextField`
                // bound to an `Int` through a `FormatStyle` (`.number`),
                // which parses whatever you type and reverts to the
                // previous value if it doesn't parse, plus a label-less
                // `Stepper` beside it for the same click-to-nudge
                // affordance a browser's spinner arrows give.
                // `LabeledContent` is what keeps this row's label aligned
                // with the other rows' while the content is a composite
                // (field + stepper) rather than one control.
                LabeledContent("Sample size") {
                    HStack(spacing: 6) {
                        TextField(
                            "Sample size",
                            value: $model.sampleSize,
                            format: .number.grouping(.never)
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)

                        Stepper(
                            "Sample size",
                            value: $model.sampleSize,
                            in: SampleBuilderModel.sampleSizeRange,
                            step: 100
                        )
                        .labelsHidden()
                    }
                }
            }

            Section("Rating") {
                Toggle("Filter by rating", isOn: $model.ratingEnabled)
                if model.ratingEnabled {
                    Picker("Rating", selection: $model.ratingComparison) {
                        ForEach(RatingComparisonKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    Stepper("Value: \(model.ratingValue)", value: $model.ratingValue, in: 0...5)
                }
            }

            Section("Category") {
                Toggle("Filter by category", isOn: $model.categoryEnabled)
                if model.categoryEnabled {
                    Picker("Match", selection: $model.categoryMode) {
                        Text("Any of").tag(CategoryMatchMode.any)
                        Text("All of").tag(CategoryMatchMode.all)
                        Text("None of").tag(CategoryMatchMode.none)
                    }
                    .pickerStyle(.segmented)

                    if model.propTree.isEmpty {
                        Text("No categories in this catalog.")
                            .foregroundStyle(.secondary)
                    } else {
                        // `children: \.childrenOrNil` is what makes this
                        // a genuine outline/tree view (disclosure
                        // triangles, expand/collapse) instead of a flat
                        // list -- native SwiftUI, no third-party tree-
                        // view component needed. Combined with
                        // `selection:`, macOS Lists support multi-select
                        // natively via cmd/shift-click, no explicit edit
                        // mode needed (unlike iOS) -- selecting a parent
                        // node doesn't implicitly select its children;
                        // each node (leaf or not) is its own independent
                        // choice, matching how a photo can be tagged
                        // with any prop in the tree directly, not just
                        // leaves.
                        List(model.propTree, children: \.childrenOrNil, selection: $model.selectedCategoryGUIDs) {
                            node in
                            Text(node.name)
                        }
                        .frame(minHeight: 200)
                        Text("\(model.selectedCategoryGUIDs.count) selected")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section("Preview") {
                matchCountRow
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 320)
        // Re-runs the pre-flight count whenever the derived filter
        // changes -- not on every keystroke of unrelated state like
        // sampleSize, since SampleFilter (an Equatable value type)
        // doesn't include it.
        .onChange(of: model.currentFilter) {
            model.refreshMatchingCount()
        }
    }

    @ViewBuilder
    private var matchCountRow: some View {
        if model.isCountingMatches {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Counting matches…")
                    .foregroundStyle(.secondary)
            }
        } else if let count = model.matchingCount {
            Label("\(count) photo\(count == 1 ? "" : "s") match", systemImage: "checkmark.circle")
        } else {
            Text("—")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SampleBuilderView(model: SampleBuilderModel())
}
