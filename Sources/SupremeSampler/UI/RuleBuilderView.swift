import SwiftUI

/// The main pane: the rule tree, Lightroom Smart Collection style (see
/// `RuleGroupEditor`). Wide, so each rule fits on one line.
struct RuleBuilderView: View {
    /// The narrowest the rules pane gets. Every kind of rule fits here
    /// stacked (operator and value on a second line), three groups deep;
    /// `RuleRowWidthTests` measures that.
    static let minimumWidth: CGFloat = 580

    /// Where every kind of rule fits on one line at the top level --
    /// what a new window leaves the rules (see `defaultWindowWidth`;
    /// after that, the user's divider positions win). `RuleRowWidthTests`
    /// measures that too.
    static let comfortableWidth: CGFloat = 760

    /// A new window: the sidebar and script at their ideal widths, the
    /// rules at `comfortableWidth`.
    static let defaultWindowWidth: CGFloat = 300 + comfortableWidth + ScriptPreviewView.idealWidth

    // `@Bindable` derives two-way bindings (`$model.rules`) from an
    // `@Observable` model, like Vue's `v-model`.
    @Bindable var model: SampleBuilderModel

    var body: some View {
        ScrollView {
            RuleGroupEditor(
                group: $model.rules, propTree: model.propTree, depth: 0, onRemove: nil,
                labels: model.catalogLabels, fileTypes: model.catalogFileTypes, bookmarks: model.catalogBookmarks
            )
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
