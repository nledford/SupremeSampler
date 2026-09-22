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
                Stepper(
                    "Sample size: \(model.sampleSize)",
                    value: $model.sampleSize,
                    in: 1...1_000_000,
                    step: 100
                )
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

                    if model.availableProps.isEmpty {
                        Text("No categories in this catalog.")
                            .foregroundStyle(.secondary)
                    } else {
                        // macOS Lists support multi-select natively via
                        // cmd/shift-click when given a Set binding, no
                        // explicit edit mode needed (unlike iOS).
                        List(model.availableProps, selection: $model.selectedCategoryGUIDs) { prop in
                            Text(prop.name)
                        }
                        .frame(minHeight: 150)
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
