import SwiftUI
import VitalisKit
import VitalisUI

/// Full-screen morning digest over Today (spec 20 §4). "Start my day" dismisses; only an automatic presentation sets
/// the once-per-day flag (TodayStore.finishDigest).
struct DigestScreen: View {
    @Environment(Router.self) private var router
    @State private var digest: Loadable<DigestResponse>
    private let live: Bool
    private let now: () -> Date

    init() { _digest = State(initialValue: Loadable()); live = true; now = { Date() } }
    init(preview: DigestResponse?, now: @escaping () -> Date) { _digest = State(initialValue: Loadable(preview)); live = false; self.now = now }

    var body: some View {
        let d = digest.value
        let status = TodayStore.status(lastSync: d?.freshness?.lastSync, exporter: live ? TodayStore.shared.exporter : ExporterState(),
                                       cachedAt: digest.fetchedAt, refreshFailed: digest.error != nil, now: now())
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    top(staleLabel: d == nil ? nil : staleLabel(status))
                    pulse(d?.pulse).padding(.top, VSpace.s2)
                    content(d)
                }
                .padding(.bottom, VSpace.s4)
            }
            PrimaryButton("Start my day") { close() }
                .padding(.horizontal, VSpace.edge)
                .padding(.vertical, VSpace.s2)
        }
        .vScreen()
        .task {
            guard live, let api = Services.shared.api else { return }
            await digest.load(cached: { await api.cached(DigestResponse.self, path: "v2/digest") }) { try await api.digest() }
        }
    }

    private func close() {
        TodayStore.shared.finishDigest()
        router.showsDigest = false
    }

    /// Close on the gutter, then when the digest came from the server; a stale sync says so on the right.
    private func top(staleLabel: String?) -> some View {
        HStack(spacing: VSpace.s2) {
            // A way out that isn't "Start my day", e.g. when reopened in the evening.
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(VColor.text)
                    .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close digest")
            FreshnessLine(DataFreshness(fetchedAt: digest.fetchedAt, refreshing: digest.isLoading))
            Spacer(minLength: VSpace.s2)
            if let staleLabel { Text(staleLabel).vText(.secondary, color: VColor.watch).lineLimit(1) }
        }
        .padding(.horizontal, VSpace.edge)
    }

    /// The day so far, edge to edge (the brand line, drawn from the server's window).
    private func pulse(_ p: Pulse?) -> PulseLine {
        guard let p, let pos = PulseLine.positions(windowStart: p.window.start, windowEnd: p.window.end,
                                                    now: p.now, events: p.events.map(\.at)) else { return PulseLine(now: 0) }
        return PulseLine(events: pos.events, now: pos.now)
    }

    private func staleLabel(_ status: StaleState) -> String? {
        if case .stale(let label, _, _) = status.status { return DigestCopy.sentence(label) }
        return nil
    }

    @ViewBuilder private func content(_ d: DigestResponse?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                Text([d?.dateLabel?.capitalized, d?.greeting.map(DigestCopy.sentence)].compactMap { $0 }.joined(separator: " · "))
                    .vText(.secondary)
                    .padding(.top, VSpace.s3)
                headline(d?.headline ?? []).padding(.top, VSpace.s2)
                sleepScore(d?.sleep).padding(.top, VSpace.s5)
            }
            .padding(.horizontal, VSpace.edge)
            sleepRows(d?.sleep?.rows ?? [])
            SectionLabel("Recovery")
            recovery(d?.recovery).padding(.horizontal, VSpace.edge)
            SectionLabel("Yesterday")
            yesterday(d?.yesterday).padding(.horizontal, VSpace.edge)
            plan(d?.plan ?? [])
        }
    }

    /// Two lines: the first in text, the second in accent (the approved exception to rule 2, spec 30).
    private func headline(_ lines: [String]) -> some View {
        let shown = lines.isEmpty ? ["–"] : Array(lines.prefix(2))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, line in
                Text(line).vText(.display, color: lines.isEmpty ? VColor.text3 : i == 1 ? VColor.accent : nil)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func sleepScore(_ s: DigestResponse.Sleep?) -> some View {
        let score = TodayFormat.number(s?.score)
        return Figure(score ?? "–", unit: "sleep score", size: 56, color: score == nil ? VColor.text3 : nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep \(score ?? "not available")")
    }

    @ViewBuilder private func sleepRows(_ rows: [DigestResponse.Row]) -> some View {
        if !rows.isEmpty {
            ListCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in DigestRow(row: row) }
            }
            .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
        }
    }

    private func recovery(_ r: DigestResponse.Recovery?) -> some View {
        let score = TodayFormat.number(r?.score)
        let tone: VTone = switch TodayFormat.bandTint(r?.band) { case .good: .good; case .watch: .watch; default: .usual }
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.s3) {
                CardHeader("Recovery", status: r?.label.map { (DigestCopy.sentence($0), tone) })
                Figure(score ?? "–", unit: "/100", size: 40, color: score == nil ? VColor.text3 : nil)
                (signal("HRV", r?.hrv, unit: "ms") + Text("  ·  ") + signal("Resting HR", r?.restingHr, unit: "bpm")).vText(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Value in text, arrow in the server's tint (frame 02).
    private func signal(_ key: String, _ s: DigestResponse.Signal?, unit: String) -> Text {
        let value = TodayFormat.number(s?.value)
        let base = Text("\(key) ") + Text(value.map { "\($0) \(unit)" } ?? "–").foregroundStyle(VColor.text)
        guard let glyph = TodayFormat.arrowGlyph(s?.arrow) else { return base }
        return base + Text(" ") + Text(glyph).foregroundStyle(VTone.server(s?.tint).color)
    }

    private func yesterday(_ y: DigestResponse.Yesterday?) -> some View {
        ReadoutRow([Readout("Steps", TodayFormat.number(y?.steps) ?? "–"),
                    Readout("Active kcal", TodayFormat.number(y?.activeKcal) ?? "–"),
                    Readout("Workout", y.map { $0.workout?.title ?? "Rest" } ?? "–")])
    }

    @ViewBuilder private func plan(_ items: [DigestResponse.PlanItem]) -> some View {
        SectionLabel("Today")
        if !items.isEmpty {
            ListCard {
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    ListRow(item.title, subtitle: item.reason.map(DigestCopy.sentence), chevron: false) {
                        Circle().fill(item.primary ? VColor.accent : VColor.usual).frame(width: 8, height: 8).accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, VSpace.edge)
        }
    }
}

/// One sleep row: label, value and delta; a status dot when the server flags it (good = better than usual, watch = off it).
private struct DigestRow: View {
    let row: DigestResponse.Row

    var body: some View {
        ListRow(DigestCopy.sentence(row.label), value: value, chevron: false) {
            if row.tint != nil {
                Circle().fill(VTone.server(row.tint).color).frame(width: 8, height: 8)
                    .accessibilityLabel(row.tint == "good" ? "better than usual" : "off your usual")
            }
        }
    }

    private var value: String {
        guard let v = row.value else { return "–" }
        return [v, row.delta].compactMap { $0?.lowercased() }.joined(separator: " ")
    }
}

/// The server sends digest words in mono caps ("DURATION", "6 DAYS SINCE"); the system sets them in sentence case.
private enum DigestCopy {
    static func sentence(_ s: String) -> String {
        let lower = s.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}

// MARK: - Previews (fixtures only)

#if DEBUG
@MainActor private func digestPreview(_ d: DigestResponse?) -> some View {
    DigestScreen(preview: d, now: TodayPreviewData.clock("2026-10-24T07:05:00+05:30"))
        .environment(Router())
        .onAppear { VFont.register() }
}

/// Frame 02's morning values on top of the fixture.
private let morning = #"""
{"greeting": "GOOD MORNING", "night_ended_at": "2026-10-24T06:51:00+05:30",
 "sleep": {"score": 85, "rows": [{"key": "duration", "label": "DURATION", "value": "7H41", "delta": "+12M", "tint": "good"},
                                 {"key": "bedtime", "label": "BEDTIME", "value": "23:02", "tint": null},
                                 {"key": "efficiency", "label": "EFFICIENCY", "value": "94%", "tint": null},
                                 {"key": "wakeups", "label": "WAKE-UPS", "value": "2", "tint": "watch"}]},
 "recovery": {"score": 78, "hrv": {"value": 62, "arrow": "up", "tint": "good"}, "resting_hr": {"value": 57, "arrow": "up", "tint": "watch"}},
 "yesterday": {"steps": 9870, "active_kcal": 2240, "workout": null},
 "plan": [{"kind": "train", "title": "Train legs", "reason": "6 DAYS SINCE", "primary": true},
          {"kind": "eat", "title": "Eat 2,300 kcal", "reason": "160 G PROTEIN", "primary": false},
          {"kind": "walk", "title": "Walk 9,000", "reason": "YOUR USUAL", "primary": false}],
 "pulse": {"window": {"start": "2026-10-24T06:51:00+05:30", "end": "2026-10-24T23:00:00+05:30"}, "now": "2026-10-24T07:05:00+05:30",
           "events": [{"at": "2026-10-24T06:51:00+05:30", "kind": "wake"}]},
 "freshness": {"last_sync": "2026-10-24T07:04:00+05:30"}}
"""#

#Preview("Digest · good night (frame 02)") { digestPreview(TodayPreviewData.digest(morning)) }

#Preview("Digest · short night") {
    digestPreview(TodayPreviewData.digest(morning, #"""
    {"headline": ["Short night.", "Keep it easy."],
     "sleep": {"score": 58, "band": "poor", "rows": [{"key": "duration", "label": "DURATION", "value": "5H20", "delta": "−2H09", "tint": "watch"},
                                                     {"key": "bedtime", "label": "BEDTIME", "value": "01:10", "delta": "2H LATE", "tint": "watch"},
                                                     {"key": "efficiency", "label": "EFFICIENCY", "value": "91%", "tint": null},
                                                     {"key": "wakeups", "label": "WAKE-UPS", "value": "1", "tint": null}]},
     "recovery": {"score": 54, "band": "ease", "label": "EASE"}}
    """#))
}

#Preview("Digest · wake-ups flagged") {
    digestPreview(TodayPreviewData.digest(morning, #"""
    {"sleep": {"score": 71, "rows": [{"key": "duration", "label": "DURATION", "value": "7H05", "delta": "−24M", "tint": null},
                                     {"key": "bedtime", "label": "BEDTIME", "value": "23:10", "delta": "ON TIME", "tint": null},
                                     {"key": "efficiency", "label": "EFFICIENCY", "value": "82%", "tint": "watch"},
                                     {"key": "wakeups", "label": "WAKE-UPS", "value": "6", "tint": "watch"}]}}
    """#))
}

#Preview("Digest · loading") { digestPreview(nil) }

#Preview("Digest · evening fixture") { digestPreview(TodayPreviewData.digest()) }
#endif
