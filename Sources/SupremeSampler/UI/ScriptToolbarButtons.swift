import SwiftUI

/// Copy and Save… in the window's toolbar: the app's two ways out
/// (PRODUCT.md). In the toolbar rather than the script pane so they stay
/// put when the pane is hidden. Both actions come from `ContentView`,
/// which also offers them to the Edit and File menus.
struct ScriptToolbarButtons: View {
    var model: SampleBuilderModel
    let copy: () -> Void
    let save: () -> Void

    /// Whether to show "Copied": set by any copy, button or menu, via
    /// the model's `copyCount`. `@State` is storage the view owns across
    /// re-renders, like React's `useState`.
    @State private var didCopy = false

    var body: some View {
        Button(action: copy) {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
        }
        .help("Copy the script, to paste into Script Studio (⇧⌘C)")
        // `.onChange` runs the closure whenever the value changes, like a
        // React `useEffect` with that value as its only dependency.
        .onChange(of: model.copyCount) {
            didCopy = true
            // A `Task` restarted per copy: repeat copies keep the label up
            // for 1.5s after the last one, like re-arming a `setTimeout`.
            Task {
                let count = model.copyCount
                try? await Task.sleep(for: .seconds(1.5))
                if model.copyCount == count { didCopy = false }
            }
        }

        Button(action: save) {
            Label("Save…", systemImage: "square.and.arrow.down")
        }
        .disabled(!model.canSaveScript)
        .help(Self.saveHelp(canSave: model.canSaveScript, forecast: model.sampleForecast))
    }

    /// The Save button's tooltip, repeating the shortfall warning, since
    /// saving is the moment it matters.
    static func saveHelp(canSave: Bool, forecast: SampleForecast?) -> String {
        guard canSave else { return "Available once the match count has finished" }
        let plain = "Save as a .psc file (⌘S)"
        guard let forecast else { return plain }
        switch forecast.kind {
        case .full:
            return plain
        case .short:
            return plain + ". It will pick \(forecast.matching.formatted()), "
                + "not the \(forecast.requested.formatted()) requested."
        case .empty:
            return plain + ". No photos match it right now."
        }
    }
}
