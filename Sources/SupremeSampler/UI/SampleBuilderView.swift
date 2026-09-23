import SwiftUI

/// The left-hand rule builder: sample size, the (possibly nested) rules
/// -- see `RuleGroupEditor` -- and the live pre-flight match count, the
/// Lightroom Smart Collection-style interface this app was built around.
struct SampleBuilderView: View {
    // `@Bindable` is what lets `$model.sampleSize` etc. work below: it
    // derives a two-way `Binding` for each stored property of an
    // `@Observable` reference, the way Vue's `v-model` or Svelte's
    // `bind:value` wire a form control straight to a piece of state.
    // Rust has no close built-in equivalent -- the nearest analogues are
    // reactive-framework-specific (Leptos/Dioxus signals), not a
    // language feature.
    @Bindable var model: SampleBuilderModel

    // `@FocusState` is SwiftUI's property wrapper for reading and driving
    // keyboard focus declaratively -- closer to tracking a boolean piece
    // of state than to imperatively calling `.focus()`/`becomeFirstResponder`
    // the way AppKit/UIKit (or a JS `element.focus()` call) would. Needed
    // here because giving the sample-size `TextField` a fresh `.id()` on
    // a clamp (see that modifier below) recreates the field, which drops
    // whatever had focus -- this re-asserts it in the same update pass.
    @FocusState private var sampleSizeFieldIsFocused: Bool

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
                        // Forces SwiftUI to recreate this field (so its
                        // on-screen text re-reads the corrected value)
                        // whenever the model actually clamps an
                        // out-of-range entry -- see the doc comment on
                        // `sampleSizeClampGeneration`. An `.id()` change
                        // only rebuilds when the id itself changes, so
                        // ordinary in-range typing (which doesn't bump
                        // the generation) leaves the field untouched.
                        .id(model.sampleSizeClampGeneration)
                        .focused($sampleSizeFieldIsFocused)

                        Stepper(
                            "Sample size",
                            value: $model.sampleSize,
                            in: SampleBuilderModel.sampleSizeRange,
                            step: 100
                        )
                        .labelsHidden()
                    }
                    // The only way `sampleSizeClampGeneration` changes is
                    // an out-of-range value written through the text
                    // field above (the `Stepper`'s own `in:` keeps it in
                    // range), so a change here reliably means "the field
                    // the user was just typing in got recreated out from
                    // under them" -- restore focus to the new instance so
                    // typing can continue without an extra click.
                    .onChange(of: model.sampleSizeClampGeneration) {
                        // Deferred a tick (`DispatchQueue.main.async`,
                        // roughly a `setTimeout(fn, 0)` in JS terms):
                        // setting this in the same pass as the `.id()`
                        // change above was confirmed by hand to lose the
                        // race and leave the field unfocused -- the new
                        // `TextField` instance isn't installed yet when
                        // this closure runs.
                        DispatchQueue.main.async {
                            sampleSizeFieldIsFocused = true
                        }
                    }
                }
            }

            Section("Rules") {
                RuleGroupEditor(
                    group: $model.rules, propTree: model.propTree, depth: 0, onRemove: nil,
                    labels: model.catalogLabels, fileTypes: model.catalogFileTypes)
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
    SampleBuilderView(model: SampleBuilderModel(catalogStore: InMemoryRecentCatalogStore()))
}
