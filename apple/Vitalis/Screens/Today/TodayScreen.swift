import SwiftUI
import VitalisKit
import VitalisUI

/// Vertical rhythm measured from spec/design/02, 03 and 24 at 390×844 (gaps include the fonts' ascent/descent).
enum TodayLayout {
    static let pulseGap: CGFloat = 18
    static let afterPulse: CGFloat = 1.5
    static let labelToHeadline: CGFloat = 10
    static let columnGap: CGFloat = 20
    static let stackGap: CGFloat = 6
    static let mapWidth: CGFloat = 130
    static let mapGap: CGFloat = 14
    static let trainingLine: CGFloat = 22
    static let hitSlop: CGFloat = 16
}

/// Status label + PulseLine above the content (spec 30 → StatusRow), below the system status bar.
struct TodayTop: View {
    let label: String
    let tint: VTint
    let pulse: Pulse?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusRow(label.isEmpty ? " " : label, tint: tint).padding(.top, VSpace.statusTop)
            line.padding(.top, TodayLayout.pulseGap)
        }
    }

    private var line: PulseLine {
        guard let p = pulse, let pos = PulseLine.positions(windowStart: p.window.start, windowEnd: p.window.end,
                                                            now: p.now, events: p.events.map(\.at)) else { return PulseLine(now: 0) }
        return PulseLine(events: pos.events, now: pos.now)
    }
}

/// `–` hero number + NO RECOVERY SCORE + the server's reason (calibrating, missing night; frame 24).
struct NoScoreBlock: View {
    let reason: String?
    var body: some View {
        HStack(alignment: .center, spacing: TodayLayout.columnGap) {
            // Zero layout height: the dash centres on the text column the way frame 24 draws it.
            Text("–").vNumber(92, color: VColor.steel).fixedSize().frame(height: 0)
            VStack(alignment: .leading, spacing: 7) {
                MonoLabel("No recovery score")
                if let reason { Text(reason).vBody().fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TodayScreen: View {
    @State private var store: TodayStore
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    /// False in previews: no network, exporter, notifications or Services.
    private let live: Bool

    init() { _store = State(initialValue: TodayStore.shared); live = true }
    init(store: TodayStore) { _store = State(initialValue: store); live = false }

    var body: some View {
        let status = store.status(now: store.now())
        let stale = status.isStale && store.today.value != nil
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TodayTop(label: statusLabel(status), tint: status.isStale ? .watch : .steel, pulse: store.today.value?.pulse)
                    Group {
                        if stale, case .stale(_, let section, let cause) = status.status {
                            staleBody(section: section, cause: cause)
                        } else {
                            homeBody
                        }
                    }
                    .padding(.horizontal, VSpace.gutter)
                }
                .padding(.bottom, VSpace.gutter)
            }
            .refreshable { if live { await AppModel.shared.syncNow(); await store.refresh() } }
            if !stale, store.phase != .loading, let label = store.actionLabel {
                PrimaryButton(label) { store.apply(store.intent, router: router) }
                    .padding(.horizontal, VSpace.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, VSpace.buttonBottomAboveTabs)
            }
        }
        // Below the system status bar, like the other tabs: its icons would cover the SYNCED label.
        .task(id: scenePhase) {
            guard live, scenePhase == .active else { return }
            store.observeExporter(AppModel.shared.$snapshot)
            await store.refresh()
            store.presentDigestIfDue(router: router)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                if Task.isCancelled { return }
                await store.refresh()
            }
        }
        .onChange(of: live ? Services.shared.writesVersion : 0) { Task { await store.refresh() } }
    }

    private func statusLabel(_ status: StaleState) -> String {
        guard store.phase != .loading else { return "" }
        if store.phase == .failed { return "OFFLINE" }
        switch status.status {
        case .synced(let label), .offline(let label): return label
        case .stale(let label, _, _): return label
        }
    }

    // MARK: Home (frame 03)

    @ViewBuilder private var homeBody: some View {
        let t = store.today.value
        VStack(alignment: .leading, spacing: 0) {
            nowBlock(t)
            if store.phase == .failed {
                Text("Connect to your server to see today.").vBody().padding(.top, 12)
                SecondaryButton("Try again") { Task { await store.refresh() } }.padding(.top, 12)
            }
            recovery(t?.recovery).padding(.top, 3)
            VSection { fuelActivity(t) }
            VSection(top: 15) { training(t) }
        }
    }

    private func nowBlock(_ t: TodayResponse?) -> some View {
        let label = ["Now", t?.verdict.label].compactMap { $0 }.joined(separator: " · ")
        let lines = t.map { HeadlineLines.split($0.verdict.headline) } ?? ["–"]
        return VStack(alignment: .leading, spacing: 0) {
            MonoLabel(label, tint: .pulse)
            HeadlineLines(lines, size: 46, colors: t == nil ? [VColor.steel] : []).padding(.top, TodayLayout.labelToHeadline)
        }
        .padding(.top, TodayLayout.afterPulse)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Now" + (t?.verdict.label.map { ", \($0.lowercased())" } ?? ""), t?.verdict.headline].compactMap { $0 }.joined(separator: ". "))
        .overlay(alignment: .topTrailing) {
            HStack(alignment: .firstTextBaseline, spacing: 14) { dateButton(t?.day); gearButton }
                .padding(.top, TodayLayout.afterPulse)
        }
    }

    @ViewBuilder private func dateButton(_ day: String?) -> some View {
        if let label = TodayFormat.dateLabel(day: day) {
            // Reopens today's digest without touching the dismissed flag.
            Button { router.showsDigest = true } label: { MonoLabel(label).hitSlop() }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label). Morning digest")
        }
    }

    private var gearButton: some View {
        Button { router.open(.settings) } label: { Image(systemName: "gearshape").vLabel().hitSlop() }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
    }

    @ViewBuilder private func recovery(_ r: TodayResponse.Recovery?) -> some View {
        if let r, r.status != "ok" {
            NoScoreBlock(reason: r.reason).padding(.top, 16)
        } else {
            let score = TodayFormat.number(r?.score)
            HStack(alignment: .bottom, spacing: TodayLayout.columnGap) {
                Button { router.tab = .sleep } label: {
                    VStack(alignment: .leading, spacing: -2.4) {
                        Text(score ?? "–").vNumber(92, color: score == nil ? VColor.steel : nil).lineLimit(1).fixedSize()
                        MonoLabel("Recovery")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(["Recovery \(score ?? "not available")", r?.band].compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(.isButton)
                VStack(spacing: 0) {
                    Button { router.tab = .sleep } label: { row("Sleep", TodayFormat.number(r?.parts?.sleep?.score), tint: nil, arrow: nil) }
                    Button { router.tab = .body } label: { vital("HRV", r?.parts?.hrv) }
                    Button { router.tab = .body } label: { vital("Resting", r?.parts?.restingHr, showsRule: false) }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func vital(_ key: String, _ part: TodayResponse.VitalPart?, showsRule: Bool = true) -> some View {
        row(key, TodayFormat.number(part?.value), tint: part?.tint, arrow: TodayFormat.arrow(part?.arrow), showsRule: showsRule)
    }

    private func row(_ key: String, _ value: String?, tint: String?, arrow: VArrow?, showsRule: Bool = true) -> some View {
        ReadingRow(key, value: value ?? "–", tint: value == nil ? .steel : VTint.server(tint, else: .bone),
                   arrow: value == nil ? nil : arrow, showsRule: showsRule)
    }

    private func fuelActivity(_ t: TodayResponse?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            fuel(t?.fuel).frame(maxWidth: .infinity, alignment: .leading)
            activity(t?.activity).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fuel(_ f: TodayResponse.Fuel?) -> some View {
        let left = f?.kcalLeft
        let over = (left ?? 0) < 0
        let value = TodayFormat.number(left?.magnitude)
        return VStack(alignment: .leading, spacing: TodayLayout.stackGap) {
            VStack(alignment: .leading, spacing: TodayLayout.stackGap) {
                MonoLabel(over ? "Over by" : "Fuel left", tint: over ? .watch : .steel)
                Text(value ?? "–").vNumber(32, color: value == nil ? VColor.steel : over ? VColor.watch : nil).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            if let next = f?.nextLabel {
                Button { router.sheet = .quickAdd(slot: f?.nextSlot) } label: { MonoLabel("+ \(next)", tint: .bone).hitSlop() }
                    .buttonStyle(.plain)
            } else {
                MonoLabel("–")
            }
        }
    }

    private func activity(_ a: TodayResponse.Activity?) -> some View {
        let steps = TodayFormat.number(a?.steps)
        let target = ["OF \(TodayFormat.number(a?.stepsTarget) ?? "–")", TodayFormat.pace(a?.stepsPace)].compactMap { $0 }.joined(separator: " · ")
        // Decided in brief 01: active energy rides as a second line so Activity shows both pillars.
        let active = ["\(TodayFormat.number(a?.activeKcal) ?? "–") ACTIVE KCAL", TodayFormat.pace(a?.activeKcalPace)].compactMap { $0 }.joined(separator: " · ")
        return Button { router.tab = .body } label: {
            VStack(alignment: .leading, spacing: TodayLayout.stackGap) {
                MonoLabel("Steps")
                Text(steps ?? "–").vNumber(32, color: steps == nil ? VColor.steel : nil).lineLimit(1)
                VStack(alignment: .leading, spacing: 4) {
                    MonoLabel(target)
                    MonoLabel(active)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func training(_ t: TodayResponse?) -> some View {
        let tr = t?.training
        // Heat 0 everywhere = no working set in 30 days; a "Legs fresh" label over a blank body would mislead.
        let empty = tr.map { $0.heat.values.allSatisfy { $0 == 0 } } ?? false
        let lines: [(String, Color)] = empty ? [("No workouts yet", VColor.bone)]
            : [tr?.freshLabel.map { ($0, VColor.bone) }, tr?.loadedLabel.map { ($0, VColor.steel) }].compactMap { $0 }
        HStack(alignment: .center, spacing: TodayLayout.mapGap) {
            Button { router.tab = .train } label: {
                MuscleMap(heat: tr?.heat ?? [:], view: .both).frame(width: TodayLayout.mapWidth)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 12) {
                Button { router.tab = .train } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.0).vHeadline(22, color: line.1).lineLimit(1).minimumScaleFactor(0.6)
                                .frame(height: TodayLayout.trainingLine, alignment: .bottom)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                // Empty training offers a start as a secondary unless the verdict's primary already does.
                if empty, t?.verdict.action?.kind != "start_workout" {
                    SecondaryButton(store.startLabel) { router.open(.workoutStart) }
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
    }

    // MARK: Stale (frame 24)

    private func staleBody(section: String, cause: String) -> some View {
        let t = store.today.value
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                dateButton(t?.day)
                Spacer(minLength: 8)
                gearButton
            }
            .padding(.top, TodayLayout.afterPulse)
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(VColor.watch).frame(height: 1.5)
                MonoLabel(section, tint: .watch).padding(.top, VSpace.sectionPad)
                HeadlineLines(HeadlineLines.split(cause), size: 36).padding(.top, 12)
                Text(StaleState.body).vBody().padding(.top, 11)
                PrimaryButton("Fix sync") { router.open(.settingsSync) }.padding(.top, 19)
            }
            .padding(.top, 15)
            VSection(top: 32) { recovery(t?.recovery).padding(.top, 4) }
            if let t, let action = t.verdict.action {
                VSection(top: 31) { staleAction(t, action).padding(.top, 4) }
            }
        }
    }

    /// The verdict's action, demoted to a secondary button while sync is broken.
    private func staleAction(_ t: TodayResponse, _ action: TodayResponse.Action) -> some View {
        let due = action.kind == "start_workout" ? t.training.due : nil
        let watchStart = store.startLabel.hasSuffix("Watch")
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                MonoLabel(due == nil ? "Now" : "Training")
                HeadlineLines(HeadlineLines.split(due.map { "\($0.name) are due" } ?? t.verdict.headline, maxChars: 22), size: 26)
                    .padding(.top, 9)
                if due != nil, watchStart { Text("Watch logging still works offline").vBody().padding(.top, 3) }
            }
            Spacer(minLength: 0)
            SecondaryButton(due == nil ? (store.actionLabel ?? action.label) : "Start") { store.apply(store.intent, router: router) }
        }
    }
}

private extension View {
    /// ≥ 44 pt tap target around small labels without moving them.
    func hitSlop() -> some View {
        padding(TodayLayout.hitSlop).contentShape(Rectangle()).padding(-TodayLayout.hitSlop)
    }
}

// MARK: - Previews (fixtures only)

#if DEBUG
private struct TodayPreview: View {
    let store: TodayStore
    var body: some View {
        VStack(spacing: 0) {
            TodayScreen(store: store).frame(maxHeight: .infinity)
            TabBar(selection: .constant(.today))
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .vScreen()
        .environment(Router())
        .onAppear { VFont.register() }
    }
}

@MainActor private func previewStore(_ t: TodayResponse?, now: String = "2026-10-24T09:41:00+05:30", fetchedAt: String? = nil,
                                      failed: Bool = false, exporter: ExporterState = ExporterState()) -> TodayStore {
    let store = TodayStore(api: { nil }, defaults: UserDefaults(suiteName: "today-preview") ?? .standard, snapshotDirectory: nil,
                           now: TodayPreviewData.clock(now), preview: t, previewFetchedAt: APIDate.parse(fetchedAt), previewFailed: failed)
    store.updateExporter(exporter)
    return store
}

private let staleSince = "2026-10-21T16:12:00+05:30"
private let stalePatch = #"""
{"freshness": {"last_sync": "2026-10-21T16:12:00+05:30"},
 "recovery": {"score": null, "band": null, "status": "missing", "reason": "Last night's sleep and heart data haven't reached Vitalis yet."}}
"""#

#Preview("Home · frame 03") { TodayPreview(store: previewStore(TodayPreviewData.today(TodayPreviewData.frame03))) }

#Preview("Home · evening fixture") {
    TodayPreview(store: previewStore(TodayPreviewData.today(), now: "2026-10-24T22:14:00+05:30"))
}

#Preview("Home · calibrating") {
    TodayPreview(store: previewStore(TodayPreviewData.today(TodayPreviewData.frame03, #"""
    {"recovery": {"score": null, "band": null, "status": "calibrating", "reason": "Needs 9 more nights", "nights_needed": 9}}
    """#)))
}

#Preview("Home · missing night") {
    TodayPreview(store: previewStore(TodayPreviewData.today(TodayPreviewData.frame03, #"""
    {"recovery": {"score": null, "band": null, "status": "missing", "reason": "No sleep recorded for last night"}}
    """#)))
}

#Preview("Home · stale 401 (frame 24)") {
    TodayPreview(store: previewStore(TodayPreviewData.today(TodayPreviewData.frame03, stalePatch),
                                     exporter: ExporterState(lastSuccess: APIDate.parse(staleSince),
                                                             lastError: "HKQuantityTypeIdentifierStepCount: Server returned HTTP 401. The anchor was kept.")))
}

#Preview("Home · stale unreachable") {
    TodayPreview(store: previewStore(TodayPreviewData.today(TodayPreviewData.frame03, stalePatch),
                                     exporter: ExporterState(lastSuccess: APIDate.parse(staleSince),
                                                             lastError: "HKQuantityTypeIdentifierStepCount: The Internet connection appears to be offline.")))
}

#Preview("Home · empty training") {
    TodayPreview(store: previewStore(TodayPreviewData.today(TodayPreviewData.frame03, #"""
    {"verdict": {"headline": "Eat well today", "action": {"kind": "log_meal", "label": "Log lunch"}},
     "training": {"fresh_label": null, "loaded_label": null, "due": null,
                  "heat": {"abdominals": 0, "abductors": 0, "adductors": 0, "biceps": 0, "calves": 0, "chest": 0, "forearms": 0,
                           "glutes": 0, "hamstrings": 0, "lats": 0, "lower-back": 0, "middle-back": 0, "neck": 0, "quadriceps": 0,
                           "shoulders": 0, "traps": 0, "triceps": 0}}}
    """#)))
}

#Preview("Home · empty fuel") {
    TodayPreview(store: previewStore(TodayPreviewData.today(TodayPreviewData.frame03, #"""
    {"generated_at": "2026-10-24T07:20:00+05:30",
     "fuel": {"kcal_eaten": 0, "kcal_left": 2300, "protein_g": 0, "next_slot": "breakfast", "next_label": "LOG BREAKFAST"}}
    """#)))
}

#Preview("Home · loading") { TodayPreview(store: previewStore(nil)) }

#Preview("Home · offline, cached") {
    TodayPreview(store: previewStore(TodayPreviewData.today(TodayPreviewData.frame03), now: "2026-10-24T10:20:00+05:30",
                                     fetchedAt: "2026-10-24T09:41:00+05:30", failed: true))
}

#Preview("Home · offline, no cache") { TodayPreview(store: previewStore(nil, failed: true)) }
#endif
