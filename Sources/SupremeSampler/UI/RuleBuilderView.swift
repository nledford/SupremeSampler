import SwiftUI

/// The main pane: the rule tree, Lightroom Smart Collection style (see
/// `RuleGroupEditor`). Wide, so each rule fits on one line.
struct RuleBuilderView: View {
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
