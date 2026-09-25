import SwiftUI

/// The main pane: the live match count (`MatchSummaryView`) over the
/// rule tree, Lightroom Smart Collection style (see `RuleGroupEditor`).
/// Wide, so each rule fits on one line.
struct RuleBuilderView: View {
    /// The narrowest the rules pane gets. Every kind of rule fits here
    /// stacked (operator and value on a second line), three groups deep;
    /// `RuleRowWidthTests` measures that.
    static let minimumWidth: CGFloat = 580

    /// Where every kind of rule fits on one line at the top level --
    /// what a new window leaves the rules (see `defaultWindowWidth`;
    /// after that, the user's divider positions win). `RuleRowWidthTests`
    /// measures that too. Also the widest the rules grow: past it, a
    /// short row's "−" and "+" would drift far from its controls.
    static let comfortableWidth: CGFloat = 760

    /// A new window: the sidebar and script at their ideal widths, the
    /// rules at `comfortableWidth`.
    static let defaultWindowWidth: CGFloat =
        SampleSettingsView.idealWidth + comfortableWidth + ScriptPreviewView.idealWidth

    // `@Bindable` derives two-way bindings (`$model.rules`) from an
    // `@Observable` model, like Vue's `v-model`.
    @Bindable var model: SampleBuilderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned above the scrolling rules, so the count stays in
            // view however long the rule list gets.
            MatchSummaryView(model: model)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: Self.comfortableWidth, alignment: .leading)
            Divider()
            ScrollView {
                RuleGroupEditor(
                    group: $model.rules, propTree: model.propTree, depth: 0, onRemove: nil,
                    labels: model.catalogLabels, fileTypes: model.catalogFileTypes, bookmarks: model.catalogBookmarks
                )
                .padding()
                .frame(maxWidth: Self.comfortableWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
