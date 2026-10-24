import SwiftUI
import VitalisKit
import VitalisUI

/// Spacing measured from spec/design/02-morning-digest.png at 390×844.
private enum DigestLayout {
    static let headlineToScore: CGFloat = 12
    static let scoreLabelOverlap: CGFloat = -0.75
    static let rowPad: CGFloat = 6
    static let yesterdayHeadlineNudge: CGFloat = 5
    static let planLabelGap: CGFloat = 14
    static let planTop: CGFloat = 5
    static let planRow: CGFloat = 49
    static let planDot: CGFloat = 8
    static let planDotGap: CGFloat = 12
    static let buttonHeight: CGFloat = 54
    static let buttonBottom: CGFloat = 38
}

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
                    TodayTop(label: d == nil ? "" : label(status), tint: status.isStale ? .watch : .steel, pulse: d?.pulse)
                    content(d).padding(.horizontal, VSpace.gutter)
                }
                .padding(.bottom, VSpace.gutter)
            }
            PrimaryButton("Start my day", height: DigestLayout.buttonHeight) {
                TodayStore.shared.finishDigest()
                router.showsDigest = false
            }
            .padding(.horizontal, VSpace.gutter)
            .padding(.top, 8)
            .padding(.bottom, DigestLayout.buttonBottom)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .vScreen()
        .task {
            guard live, let api = Services.shared.api else { return }
            await digest.load(cached: { await api.cached(DigestResponse.self, path: "v2/digest") }) { try await api.digest() }
        }
    }

    private func label(_ status: StaleState) -> String {
        switch status.status {
        case .synced(let l), .offline(let l), .stale(let l, _, _): l
        }
    }

    @ViewBuilder private func content(_ d: DigestResponse?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoLabel([d?.dateLabel, d?.greeting].compactMap { $0 }.joined(separator: " · "))
                .padding(.top, TodayLayout.afterPulse)
            headline(d?.headline ?? [])
                .padding(.top, TodayLayout.labelToHeadline)
            sleep(d?.sleep).padding(.top, DigestLayout.headlineToScore)
            VSection { recovery(d?.recovery) }
            VSection { yesterday(d?.yesterday) }
            plan(d?.plan ?? [])
        }
    }

    /// Two lines: the first bone, the second `pulse` (the approved exception to rule 2, spec 30).
    private func headline(_ lines: [String]) -> some View {
        HeadlineLines(lines.isEmpty ? ["–"] : Array(lines.prefix(2)), size: 44,
                      colors: lines.isEmpty ? [VColor.steel] : [VColor.bone, VColor.pulse])
    }

    private func sleep(_ s: DigestResponse.Sleep?) -> some View {
        let score = TodayFormat.number(s?.score)
        let rows = s?.rows ?? []
        return HStack(alignment: .bottom, spacing: TodayLayout.columnGap) {
            VStack(alignment: .leading, spacing: DigestLayout.scoreLabelOverlap) {
                Text(score ?? "–").vNumber(96, color: score == nil ? VColor.steel : nil).lineLimit(1).fixedSize()
                MonoLabel("Sleep")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep \(score ?? "not available")")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    DigestRow(row: row, showsRule: i < rows.count - 1)
                }
            }
        }
    }

    private func recovery(_ r: DigestResponse.Recovery?) -> some View {
        let score = TodayFormat.number(r?.score)
        let tint = TodayFormat.bandTint(r?.band)
        return HStack(alignment: .center, spacing: TodayLayout.columnGap) {
            Text(score ?? "–").vNumber(48, color: score == nil ? VColor.steel : nil).lineLimit(1).fixedSize()
            VStack(alignment: .leading, spacing: TodayLayout.stackGap) {
                MonoLabel(["Recovery", r?.label].compactMap { $0 }.joined(separator: " · "), tint: r?.label == nil ? .steel : tint)
                (signal("HRV", r?.hrv) + Text(" · ") + signal("Resting", r?.restingHr)).vReading()
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Value in bone, arrow in the server's tint (frame 02).
    private func signal(_ key: String, _ s: DigestResponse.Signal?) -> Text {
        let value = TodayFormat.number(s?.value) ?? "–"
        let base = Text("\(key.uppercased()) \(value)")
        guard let glyph = TodayFormat.arrowGlyph(s?.arrow) else { return base }
        return base + Text(" ") + Text(glyph).foregroundStyle(VTint.server(s?.tint, else: .bone).color)
    }

    private func yesterday(_ y: DigestResponse.Yesterday?) -> some View {
        VStack(alignment: .leading, spacing: TodayLayout.stackGap) {
            MonoLabel("Yesterday")
            HStack(alignment: .top, spacing: 0) {
                stat(TodayFormat.number(y?.steps), "Steps")
                stat(TodayFormat.number(y?.activeKcal), "Active kcal")
                VStack(alignment: .leading, spacing: 0) {
                    let title = y.map { $0.workout?.title ?? "Rest" }
                    HeadlineLines([title ?? "–"], size: 26, colors: title == nil ? [VColor.steel] : [])
                    MonoLabel(y == nil ? " " : y?.workout == nil ? "No workout" : "Workout", size: .small)
                }
                .padding(.top, DigestLayout.yesterdayHeadlineNudge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func stat(_ value: String?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value ?? "–").vNumber(24, color: value == nil ? VColor.steel : nil).lineLimit(1)
            MonoLabel(label, size: .small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func plan(_ items: [DigestResponse.PlanItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoLabel("Today")
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 0) {
                        Rule()
                        HStack(spacing: DigestLayout.planDotGap) {
                            Circle().fill(item.primary ? VColor.pulse : VColor.steel)
                                .frame(width: DigestLayout.planDot, height: DigestLayout.planDot)
                            Text(item.title).vHeadline(22).lineLimit(1).minimumScaleFactor(0.7)
                            Spacer(minLength: 8)
                            if let reason = item.reason { MonoLabel(reason).lineLimit(1) }
                        }
                        .frame(minHeight: DigestLayout.planRow)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, DigestLayout.planTop)
        }
        .padding(.top, DigestLayout.planLabelGap)
    }
}

/// ReadingRow with the digest's 6 pt padding and an optional delta; the tint marks the delta, or the value without one.
private struct DigestRow: View {
    let row: DigestResponse.Row
    let showsRule: Bool

    var body: some View {
        let tint = VTint.server(row.tint, else: .bone)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(row.label).vReading(tint: .steel).textCase(.uppercase)
                Spacer(minLength: 12)
                valueText(tint: tint).vReading(tint: row.value == nil ? .steel : .bone).textCase(.uppercase)
            }
            .padding(.vertical, DigestLayout.rowPad)
            if showsRule { Rule() }
        }
        .accessibilityElement(children: .combine)
    }

    private func valueText(tint: VTint) -> Text {
        guard let value = row.value else { return Text("–") }
        guard let delta = row.delta else { return row.tint == nil ? Text(value) : Text(value).foregroundStyle(tint.color) }
        return Text(value) + Text(" ") + (row.tint == nil ? Text(delta) : Text(delta).foregroundStyle(tint.color))
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
