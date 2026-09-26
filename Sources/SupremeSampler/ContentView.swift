import SwiftUI

// `View` is another protocol (~ Rust trait / TS interface); conforming
// types describe UI, they don't draw it directly. `ContentView` is a
// struct (value type) -- SwiftUI recreates and diffs these value
// descriptions cheaply and re-renders only what changed, similar in
// spirit to React re-rendering a function component and diffing the
// virtual DOM, except here the "component" is a Swift value, not a
// function call.
struct ContentView: View {
    // `@State` holding an `@Observable` reference type is the modern
    // (macOS 14+/Observation-framework) replacement for the older
    // `@StateObject` -- this view owns the model's lifetime (it's
    // created once, here, and survives view re-renders), and mutations
    // to any of its properties trigger re-renders of whatever reads them.
    // The one place the real, `UserDefaults`-backed store is chosen.
    @State private var model = SampleBuilderModel(catalogStore: UserDefaultsRecentCatalogStore())

    // Backs the menu-bar "Open Catalog…" command (see
    // `SupremeSamplerApp.commands`) -- unlike `CatalogPickerView`'s own
    // `isPickingFile`, this one has to live here rather than down in a
    // child view, since the menu command needs to be able to trigger it
    // regardless of which child view (`CatalogPickerView` or the
    // `NavigationSplitView`) is currently showing.
    @State private var isPickingCatalog = false

    /// Which split-view columns show; the user can collapse the sidebar.
    @State private var columnVisibility: NavigationSplitViewVisibility

    /// Whether the generated script shows beside the rules (it can be
    /// hidden to give the rules the whole width). Owned by `MainWindow`,
    /// which remembers it per window; tests pass their own.
    @Binding private var showsScript: Bool

    /// Where ⌘S saves to: the real save panel, or a fake in tests.
    var destinationChooser: any ScriptDestinationChoosing = SavePanelDestinationChooser()

    /// Where Copy puts the script: the real clipboard, or a fake in tests
    /// (see `ClipboardWriting` for why tests must never use the real one).
    var clipboard: any ClipboardWriting = SystemClipboard()

    /// The window's undo stack (Edit > Undo), handed to the model so rule
    /// edits can register with it. Read from the environment, as
    /// SwiftUI passes each window its own.
    @Environment(\.undoManager) private var undoManager

    /// Plain default init for real use (`MainWindow` in
    /// `SupremeSamplerApp`) -- relies on `model`'s own default
    /// value above. Declared explicitly only
    /// because defining the `model:` init below (needed for testing)
    /// suppresses Swift's normally-automatic memberwise init.
    init(showsScript: Binding<Bool>) {
        _columnVisibility = State(initialValue: .all)
        _showsScript = showsScript
    }

    /// Test seam: lets a test supply a pre-configured model (e.g. one
    /// with `injectCatalogForTesting` already called) to exercise the
    /// `NavigationSplitView` branch below, which `init()` above can
    /// never reach on its own. No default value here (unlike a more
    /// typical `model: SampleBuilderModel = SampleBuilderModel()`)
    /// because Swift evaluates a default *argument* expression in a
    /// separate, non-isolated context even when the initializer itself
    /// is `@MainActor` -- constructing the `@MainActor`-isolated
    /// `SampleBuilderModel` there fails to compile. `init()` above
    /// sidesteps that by using the *property's* default instead of a
    /// parameter's.
    ///
    /// `_model = State(wrappedValue: model)` is how you seed a `@State`
    /// property from a custom init -- the underscore-prefixed name
    /// reaches the property wrapper itself (`State<SampleBuilderModel>`)
    /// rather than the wrapped value, similar in spirit to reaching a
    /// Python property's underlying storage via `self.__dict__`, just a
    /// language feature here instead of a convention.
    @MainActor
    init(
        model: SampleBuilderModel, columnVisibility: NavigationSplitViewVisibility = .all,
        showsScript: Binding<Bool> = .constant(true), destinationChooser: (any ScriptDestinationChoosing)? = nil,
        clipboard: (any ClipboardWriting)? = nil
    ) {
        _model = State(wrappedValue: model)
        _columnVisibility = State(initialValue: columnVisibility)
        _showsScript = showsScript
        // Optional rather than defaulting to the real chooser, for the
        // same default-argument isolation reason as `model` above.
        if let destinationChooser { self.destinationChooser = destinationChooser }
        if let clipboard { self.clipboard = clipboard }
    }

    var body: some View {
        Group {
            if model.catalogPath == nil {
                CatalogPickerView(model: model)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SampleSettingsView(model: model)
                } detail: {
                    // The rules and the script side by side, the script
                    // collapsible. Not `.inspector`, the obvious SwiftUI
                    // tool: an inspector in a `NavigationSplitView`'s detail
                    // column crashed the app ("Update Constraints in Window"
                    // loop, 2026-09-24) as soon as the detail held any
                    // AppKit-backed control -- a lone `Button` was enough --
                    // while this `HSplitView` (a SwiftUI wrapper over
                    // AppKit's `NSSplitView`) held up at every width tried.
                    // `WindowLayoutTests` guards it.
                    HSplitView {
                        RuleBuilderView(model: model)
                            .frame(minWidth: RuleBuilderView.minimumWidth, maxWidth: .infinity, maxHeight: .infinity)
                        if showsScript {
                            ScriptPreviewView(model: model)
                                .frame(
                                    minWidth: ScriptPreviewView.minimumWidth, idealWidth: ScriptPreviewView.idealWidth,
                                    maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .toolbar {
                        // Copy and Save… with their titles: they're the
                        // app's two ways out, too important to be bare
                        // icons. The pane toggle stays an icon, as
                        // macOS's own sidebar toggles are.
                        ToolbarItemGroup(placement: .primaryAction) {
                            ScriptToolbarButtons(model: model, copy: copyScript) {
                                Task { await saveScript() }
                            }
                            .labelStyle(.titleAndIcon)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showsScript.toggle()
                            } label: {
                                Label(showsScript ? "Hide Script" : "Show Script", systemImage: "sidebar.right")
                            }
                            .help(showsScript ? "Hide the generated script" : "Show the generated script")
                        }
                    }
                }
                // The open catalog's file name, and the folder it's in:
                // which catalog the count is about.
                .navigationTitle(catalogTitle)
                .navigationSubtitle(catalogFolder)
                // Here, on the view that's always present while a catalog
                // is open, rather than in a pane the user can hide. Re-runs
                // the pre-flight count when the filter changes -- not on
                // unrelated state like the sample size, which `SampleFilter`
                // (an `Equatable` value) doesn't include.
                .onChange(of: model.currentFilter) {
                    model.refreshMatchingCount()
                    model.refreshFolderAudit()
                }
                .onChange(of: model.folderBalance) {
                    model.refreshFolderAudit()
                }
                // Offers this window's save action to File > Save Script…
                // and Edit > Copy Script (see `ScriptCommands`). Registered
                // here, not in the script pane: the pane can be hidden, and
                // ⌘S should still work. Scoped to the focused window, so
                // with two windows open ⌘S saves the front one.
                .focusedSceneValue(\.saveScriptAction, saveScriptAction)
                .focusedSceneValue(\.copyScriptAction, ScriptCommandAction(isEnabled: true, perform: copyScript))
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: 560)
        // `.task` runs once when the view first appears (and again if
        // its identity changes), the idiomatic SwiftUI hook for a one-
        // time startup action -- unlike putting this in `init()`, which
        // would be wrong here: SwiftUI can construct a View *value*
        // (running its init) many times over a single view's actual
        // on-screen lifetime as it re-diffs the tree, so an init isn't a
        // reliable "this happened once" signal the way it would be for
        // a class in Rust/TS/Python.
        .task {
            // Rule edits register with this window's undo stack. A session
            // restored when a catalog opens clears it again, so Undo never
            // reaches back past the restore.
            model.undoManager = undoManager
            model.attemptAutoOpenRecentCatalog()
        }
        // Listens for the menu-bar command rather than being driven
        // directly by it, since `SupremeSamplerApp.commands` lives
        // outside this view's own state and SwiftUI's `Commands` scene
        // builder has no direct way to flip a `@State` var owned by a
        // window's content view. `NotificationCenter` is the standard
        // SwiftUI escape hatch for that -- the nearest analogue in a web
        // app would be a global event bus/`EventEmitter` instead of
        // passing a callback down through props.
        .onReceive(NotificationCenter.default.publisher(for: .openCatalogRequested)) { _ in
            isPickingCatalog = true
        }
        .fileImporter(isPresented: $isPickingCatalog, allowedContentTypes: [.item]) { result in
            handleCatalogFileImporterResult(result)
        }
    }

    /// The window's minimum width: every pane at its minimum.
    static let minimumWidth = SampleSettingsView.minimumWidth + RuleBuilderView.minimumWidth
        + ScriptPreviewView.minimumWidth

    /// File > Save Script…'s action for this window: enabled once the
    /// match count has finished (`SampleBuilderModel.canSaveScript`).
    var saveScriptAction: ScriptCommandAction {
        ScriptCommandAction(isEnabled: model.canSaveScript) {
            Task { await saveScript() }
        }
    }

    /// Copy, from the toolbar or Edit > Copy Script.
    func copyScript() {
        model.copyScript(to: clipboard)
    }

    /// The open catalog's file name, for the window title.
    var catalogTitle: String {
        guard let path = model.catalogPath else { return AppName.current }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// The folder holding the open catalog, with the home folder as `~`.
    var catalogFolder: String {
        model.catalogPath.map(Self.folderDisplay(forCatalogAt:)) ?? ""
    }

    static func folderDisplay(forCatalogAt path: String) -> String {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    /// Opens the save panel in the scripts repo (when it exists) and
    /// writes the file -- the same as the toolbar's Save… button.
    func saveScript() async {
        await model.saveScript(using: destinationChooser, startingIn: PSCFile.preferredDirectory())
    }

    /// Pulled out of the `.fileImporter` closure for the same reason as
    /// `CatalogPickerView.handleFileImporterResult`: directly unit-
    /// testable without driving the system Open panel. Not shared with
    /// that method via a common helper -- the two call sites are each a
    /// few lines, and the two views have different reasons to exist
    /// (first-open vs. switch-catalog), so a shared abstraction here
    /// would cost more than it saves.
    func handleCatalogFileImporterResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            _ = url.startAccessingSecurityScopedResource()
            model.openCatalog(at: url.path)
        case .failure(let error):
            model.reportPickerFailure(error)
        }
    }
}

extension Notification.Name {
    /// Posted by the "Open Catalog…" menu-bar command
    /// (`SupremeSamplerApp.commands`); observed by `ContentView` to
    /// present the file picker.
    static let openCatalogRequested = Notification.Name("com.nateledford.SupremeSampler.openCatalogRequested")
}

// `#Preview` is a Swift macro (compile-time code generation, vaguely like
// a Rust proc/attribute macro in mechanism) that Xcode uses to render this
// view in a live canvas while you edit -- conceptually similar to a
// Storybook story for a React component, but built into the IDE.
#Preview {
    ContentView(model: SampleBuilderModel(catalogStore: InMemoryRecentCatalogStore()))
}
