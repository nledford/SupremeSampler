import SwiftUI

// The widgets shared by the rules whose value is a list of things read
// from the catalog (labels, file types, bookmarks): a mode picker, a
// summary button that opens the list in a popover, and the list itself.

/// "is any of / is none of", for rules over a list of values.
struct ValueModePicker: View {
    @Binding var mode: ValueMatchMode

    var body: some View {
        Picker("Match", selection: $mode) {
            Text("is any of").tag(ValueMatchMode.any)
            Text("is none of").tag(ValueMatchMode.none)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// A button showing a summary of the picked values; click to pick in a
/// popover. Generic over the popover's content: `<Content: View>` is a
/// type parameter with a bound, like Rust's `<C: View>` -- any view type
/// works, fixed per use.
struct ValuePickerButton<Content: View>: View {
    let summary: String
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content
    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = true
        } label: {
            HStack(spacing: 4) {
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 240, alignment: .leading)
        }
        .fixedSize()
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding()
            .frame(width: 320)
        }
    }
}

/// A picker's options in groups with a divider between each, so a long
/// menu reads as a few short runs. Each option is tagged with its own
/// value, as `Picker` needs. Generic over the option type, like a Rust
/// fn over `T: Hashable`.
struct SectionedPickerItems<Option: Hashable, ItemLabel: View>: View {
    let sections: [[Option]]
    @ViewBuilder let label: (Option) -> ItemLabel

    var body: some View {
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self) { option in
                label(option).tag(option)
            }
        }
    }
}

/// A multi-select list of values read from the catalog, each with its
/// photo count, or the state of loading them.
struct CatalogValuePicker: View {
    let values: CatalogValues
    @Binding var selection: Set<String>
    /// Plural, for messages: "labels", "file types".
    let noun: String
    /// How to show the empty-string value, if it's meaningful.
    var emptyValueName: String = "(none)"
    /// How to show a value, when the stored form isn't readable on its
    /// own (a bookmark's number).
    var displayName: ((String) -> String)? = nil

    var body: some View {
        switch values {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading \(noun)…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label("Couldn't load \(noun): \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .loaded(let list):
            List(list, selection: $selection) { item in
                HStack {
                    if item.value.isEmpty {
                        Text(emptyValueName).italic()
                    } else {
                        Text(displayName?(item.value) ?? item.value)
                    }
                    Spacer()
                    Text(item.count, format: .number).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(height: 240)
            Text("\(selection.count) selected")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
