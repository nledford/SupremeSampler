import SwiftUI

/// The sidebar: sample size and folder balance. The rules and the live
/// match count are the main pane (`RuleBuilderView`).
struct SampleSettingsView: View {
    static let minimumWidth: CGFloat = 260
    static let idealWidth: CGFloat = 300

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
                            format: .number
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

                folderBalanceRow
            }
        }
        .formStyle(.grouped)
        .navigationSplitViewColumnWidth(min: Self.minimumWidth, ideal: Self.idealWidth)
    }

    /// One segmented control rather than a toggle plus a slider: "Off" is
    /// just one end of the scale, and the three presets differ visibly
    /// where arbitrary values between them wouldn't. `.tag(...)` is what
    /// the `Picker` writes into its binding when that segment is chosen,
    /// like an `<option value>` in HTML.
    private var folderBalanceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Folder balance", selection: $model.folderBalance) {
                ForEach(FolderBalance.allCases, id: \.self) { balance in
                    Text(balance.displayName).tag(balance)
                }
            }
            .pickerStyle(.segmented)

            Text(folderBalanceExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.folderBalance != .off {
                folderBalancePreviewRows
            }
        }
    }

    /// The folder audit's result for the chosen mode: how many folders
    /// the sample would reach, and each top-level group's share, with
    /// its unbalanced share alongside for comparison.
    @ViewBuilder
    private var folderBalancePreviewRows: some View {
        if model.isAuditingFolders {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking folders…")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        } else if let preview = model.folderBalancePreview {
            VStack(alignment: .leading, spacing: 2) {
                Text("≈ \(preview.expectedFolders.formatted()) of \(preview.folderCount.formatted()) folders")
                ForEach(preview.groups, id: \.name) { group in
                    // The fixed-width "was" column keeps the percentages
                    // roughly aligned without a full `Grid`.
                    HStack(spacing: 6) {
                        Text(group.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Self.percent(group.share))
                            .monospacedDigit()
                        Text("was \(Self.percent(group.offShare))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                }
            }
            .font(.caption)
        } else if let message = model.folderAuditErrorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// Whole percents, but never a misleading "0%" for a share that
    /// exists.
    static func percent(_ share: Double) -> String {
        if share > 0 && share < 0.005 { return "<1%" }
        return share.formatted(.percent.precision(.fractionLength(0)))
    }

    private var folderBalanceExplanation: String {
        switch model.folderBalance {
        case .off: return "Every photo equally likely, so big folders dominate."
        case .balanced: return "Folders weighted by the square root of their size."
        case .equal: return "Every folder equally likely, whatever its size."
        }
    }
}

#Preview {
    SampleSettingsView(model: SampleBuilderModel(catalogStore: InMemoryRecentCatalogStore()))
}
