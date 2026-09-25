import SwiftUI

/// The top of the rules pane: how many photos the rules match, and what
/// the script will do with them. The live count is the point of the app
/// (PRODUCT.md), so it leads the window instead of sitting in the
/// sidebar -- and it says when the sample will come up short, which the
/// script itself never would.
struct MatchSummaryView: View {
    var model: SampleBuilderModel

    /// Whether the user asked macOS to cut down on motion. `@Environment`
    /// reads a value SwiftUI passes down the view tree, like React
    /// context; this one comes from System Settings.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                headline
                if model.isCountingMatches {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Counting matches")
                }
            }
            detail
            // Its own line, so a long file name or error can never squeeze
            // the count beside it.
            saveStatus
        }
        // Tells VoiceOver the count each time one finishes -- even when
        // it comes back unchanged -- since nothing on screen takes focus.
        .onChange(of: model.isCountingMatches) { wasCounting, isCounting in
            guard wasCounting, !isCounting, let count = model.matchingCount else { return }
            AccessibilityNotification.Announcement(Self.headlineText(count: count)).post()
        }
    }

    /// "245,112 photos match", the number dimmed while a newer count runs
    /// (the old one stays until then, so the line doesn't jump).
    /// `@ViewBuilder` lets a property return a different view per branch
    /// of an `if`/`switch`, like JSX with a conditional inside.
    @ViewBuilder
    private var headline: some View {
        if let count = model.matchingCount {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if count == 0 {
                    Text("No photos match")
                        .font(.title2.weight(.semibold))
                } else {
                    // One `Text` joined with `+`, not two side by side, so
                    // the words move with the digits as they roll instead
                    // of being overlapped by a wider number mid-animation.
                    (Text(count, format: .number)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        + Text(count == 1 ? " photo matches" : " photos match")
                        .font(.title3))
                        // Rolls the digits when the count changes;
                        // `reduceMotion` swaps it for a plain cut.
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
                        .animation(reduceMotion ? nil : .snappy, value: count)
                }
            }
            .opacity(model.isCountingMatches ? 0.45 : 1)
            .accessibilityElement(children: .combine)
        } else if model.isCountingMatches {
            Text("Counting matches…")
                .font(.title3)
                .foregroundStyle(.secondary)
        } else {
            Text("Not counted yet")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    static func headlineText(count: Int) -> String {
        switch count {
        case 0: return "No photos match"
        case 1: return "1 photo matches"
        default: return "\(count.formatted()) photos match"
        }
    }

    /// One line under the count: what the script will pick, or the
    /// problem with the count.
    @ViewBuilder
    private var detail: some View {
        if let message = model.errorMessage {
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if model.catalogPath != nil {
                    Button("Try Again") { model.refreshMatchingCount() }
                        .buttonStyle(.link)
                }
            }
        } else if let forecast = model.sampleForecast {
            switch forecast.kind {
            case .full:
                Text(Self.fullSampleText(forecast: forecast, balance: model.folderBalance))
                    .foregroundStyle(.secondary)
            case .short:
                HStack(spacing: 8) {
                    Label {
                        Text(
                            "Fewer than the \(forecast.requested.formatted()) requested, so the script will pick all \(forecast.matching.formatted())."
                        )
                    } icon: {
                        // `.multicolor` draws the triangle in the system's
                        // own warning yellow, as Finder and Mail do.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                    Button("Sample All \(forecast.matching.formatted())") { model.useAllMatches() }
                        .buttonStyle(.link)
                        // The count on screen is for the old rules until the
                        // new one arrives.
                        .disabled(model.isCountingMatches)
                        .help("Set the sample size to the number of matching photos")
                }
            case .empty:
                Label("The script would pick nothing. Loosen a rule, or save it for when photos match.", systemImage: "circle.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func fullSampleText(forecast: SampleForecast, balance: FolderBalance) -> String {
        let pick = "The script will pick \(forecast.requested.formatted()) of them at random"
        switch balance {
        case .off: return pick + "."
        case .balanced: return pick + ", balanced across folders."
        case .equal: return pick + ", spread equally across folders."
        }
    }

    /// The last save, while the script still matches it, or why it
    /// failed. Here rather than in the script pane, which can be hidden.
    @ViewBuilder
    private var saveStatus: some View {
        if let url = model.lastSavedScriptURL {
            HStack(spacing: 6) {
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        } else if let message = model.saveErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(2)
        }
    }
}

// `#Preview`: a live canvas in Xcode, like a Storybook story.
#Preview {
    MatchSummaryView(model: SampleBuilderModel(catalogStore: InMemoryRecentCatalogStore()))
        .padding()
}
