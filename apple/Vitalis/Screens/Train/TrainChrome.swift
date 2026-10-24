import SwiftUI
import VitalisKit
import VitalisUI

/// StatusRow over the PulseLine (rule 1), fixed above the scrolling content of every Train screen.
struct TrainTopBar: View {
    let status: String
    var tint: VTint = .steel
    let pulse: PulsePositions?

    var body: some View {
        VStack(spacing: 14) {
            StatusRow(status, tint: tint).padding(.top, VSpace.statusTop)
            // Train isn't a timeline: flat with only the now-dot (spec 30 → PulseLine, tabs other than Today).
            PulseLine(events: [], now: 0.64)
        }
    }
}

/// Status label for a Train read: stale and offline rules from spec 20 §6, server `last_sync` only.
@MainActor
func trainStatus(_ freshness: Freshness?, fetchedAt: Date?, failed: Bool) -> (String, VTint) {
    let state = StaleState(lastSync: APIDate.parse(freshness?.lastSync), lastSuccess: nil, failure: nil,
                           cachedAt: fetchedAt, refreshFailed: failed, now: Date())
    switch state.status {
    case .synced(let label): return (label, .steel)
    case .offline(let label): return (label, .steel)
    case .stale(let label, _, _): return (label, .watch)
    }
}

/// `< TRAIN` back link of the pushed screens (the system bar is hidden).
struct BackLink: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).foregroundStyle(VColor.bone)
                MonoLabel(title, tint: .bone)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to \(title)")
    }
}

/// Number over a mono caption, one column of a stats row.
struct StatColumn: View {
    let value: String
    var suffix: String? = nil
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value).vNumber(32, color: value == TrainFormat.dash ? VColor.steel : nil)
                if let suffix { Text(suffix).vNumber(32, color: VColor.steel) }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            MonoLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One-line error under cached content, or the no-cache body with Try again (spec 20 §7).
struct TrainLoadError: View {
    let error: Error?
    let hasValue: Bool
    let retry: () -> Void

    var body: some View {
        if error != nil, !hasValue {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect to your server to see your training.").vBody()
                SecondaryButton("Try again", action: retry)
            }
            .accessibilityElement(children: .contain)
        } else if let error = error as? APIError, hasValue {
            MonoLabel(error.statusLine, tint: .watch)
        }
    }
}

extension View {
    /// Pushed Train screens draw their own back link.
    func trainPushed() -> some View {
        toolbar(.hidden, for: .navigationBar).vScreen()
    }
}
