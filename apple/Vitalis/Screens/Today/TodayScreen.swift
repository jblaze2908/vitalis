import SwiftUI
import VitalisKit
import VitalisUI

/// The tab headline: one `.display` line per entry.
private struct TodayHeadline: View {
    let lines: [String]
    var color: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).vText(.display, color: color).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct TodayScreen: View {
    @State private var store: TodayStore
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = Detail.launchPath("today")
    /// False in previews: no network, exporter, notifications or Services.
    private let live: Bool

    init() { _store = State(initialValue: TodayStore.shared); live = true }
    init(store: TodayStore) { _store = State(initialValue: store); live = false }

    var body: some View {
        let status = store.status(now: store.now())
        let stale = status.isStale && store.today.value != nil
        NavigationStack(path: $path) {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VHeader("Today", freshness: DataFreshness(fetchedAt: store.fetchedAt, refreshing: store.today.isLoading)) { headerTrailing }
                if stale, case .stale(_, let section, let cause) = status.status {
                    staleBody(section: section, cause: cause)
                } else {
                    homeBody
                }
            }
            .padding(.bottom, VSpace.s4)
        }
        .refreshable { if live { await AppModel.shared.syncNow(); await store.refresh() } }
        // Below the system status bar, like the other tabs: its icons would cover the header.
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
        .toolbar(.hidden, for: .navigationBar)
        .detailDestinations()
        }
    }

    /// The date opens the digest; when the phone can't reach the server it says so instead.
    @ViewBuilder private var headerTrailing: some View {
        if store.phase == .failed {
            Text("Offline").vText(.secondary, color: VColor.watch)
        } else if let label = TodayFormat.dateLabel(day: store.today.value?.day)?.capitalized {
            Button { router.showsDigest = true } label: { Text(label).vText(.secondary).hitSlop() }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label). Morning digest")
        }
    }

    // MARK: Home (2e Today)

    @ViewBuilder private var homeBody: some View {
        let t = store.today.value
        VStack(alignment: .leading, spacing: 0) {
            TodayHeadline(lines: t.map { TodayCopy.headline($0) } ?? ["–"], color: t == nil ? VColor.text3 : nil)
                .padding(.top, VSpace.s4).padding(.horizontal, VSpace.edge)
            if store.phase == .failed {
                Text("Connect to your server to see today.").vText(.body).padding(.top, VSpace.s3).padding(.horizontal, VSpace.edge)
                SecondaryButton("Try again") { Task { await store.refresh() } }.padding(.top, VSpace.s3).padding(.horizontal, VSpace.edge)
            }
            VStack(spacing: VSpace.s3) {
                recoveryCard(t?.recovery)
                // Cards in a row share the taller one's height.
                HStack(spacing: VSpace.s3) {
                    vitalCard("HRV", key: "hrv", t?.recovery.parts?.hrv, unit: "ms")
                    vitalCard("Resting HR", key: "resting_hr", t?.recovery.parts?.restingHr, unit: "bpm")
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: VSpace.s3) {
                    sleepCard(t?.sleep)
                    caloriesCard(t?.fuel)
                }
                .fixedSize(horizontal: false, vertical: true)
                stepsCard(t?.activity)
                musclesCard(t?.training)
            }
            .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5)
        }
    }

    private func tap<V: View>(_ action: @escaping () -> Void, @ViewBuilder _ label: () -> V) -> some View {
        Button(action: action) { label().contentShape(Rectangle()) }.buttonStyle(.plain)
    }

    // Recovery is HRV and resting HR against your range plus sleep: Body's vitals show those parts.
    @ViewBuilder private func recoveryCard(_ r: TodayResponse.Recovery?) -> some View {
        let ok = r?.status == "ok"
        tap({ router.showBody(.vitals) }) {
            VCard {
                VStack(alignment: .leading, spacing: VSpace.s3) {
                    CardHeader("Recovery", status: TodayCopy.recoveryStatus(r))
                    if ok || r == nil {
                        Figure(TodayFormat.number(r?.score) ?? "–", unit: "/100", size: 40, color: r?.score == nil ? VColor.text3 : nil)
                        BandScale(score: r?.score, ease: r?.bands?.ease ?? 45, steady: r?.bands?.steady ?? 60, ready: r?.bands?.ready ?? 75)
                    } else {
                        Figure("–", size: 40, color: VColor.text3)
                        if let reason = r?.reason { Text(reason).vText(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(["Recovery", TodayFormat.number(r?.score) ?? "not available", r?.band].compactMap { $0 }.joined(separator: ", "))
    }

    private func vitalCard(_ title: String, key: String, _ part: TodayResponse.VitalPart?, unit: String) -> some View {
        let tone = VTone.server(part?.tint)
        let usual = part?.usualRange.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil }
        return tap({ path.append(.metric(key: key)) }) {
            VCard {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(title, status: part?.value == nil ? nil : (TodayCopy.vitalWord(part), tone))
                    Sparkline(part?.week ?? [], usual: usual, tone: tone).frame(height: 26).padding(.top, VSpace.s3)
                    Figure(TodayFormat.number(part?.value) ?? "–", unit: unit, color: part?.value == nil ? VColor.text3 : nil).padding(.top, VSpace.s3)
                }
            }
        }
    }

    private func sleepCard(_ sl: TodayResponse.SleepSummary?) -> some View {
        let asleep = sl?.asleepH, need = sl?.needH
        return tap({ router.tab = .sleep }) {
            VCard {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader("Sleep", status: TodayCopy.sleepStatus(sl))
                    Meter(fraction: (asleep ?? 0) / max(need ?? 8, 1) * 0.88, marker: need == nil ? nil : 0.88,
                          caption: need.map { "Need \(TodayCopy.hm($0))" }, leading: asleep.map(TodayCopy.hm))
                        .padding(.top, VSpace.s3)
                    Figure(TodayFormat.number(sl?.score) ?? "–", unit: "score", color: sl?.score == nil ? VColor.text3 : nil).padding(.top, VSpace.s3)
                }
            }
        }
    }

    private func caloriesCard(_ f: TodayResponse.Fuel?) -> some View {
        let eaten = f?.kcalEaten ?? 0, target = f?.kcalTarget
        let over = (f?.kcalLeft ?? 0) < 0
        return tap({ router.tab = .eat }) {
            VCard {
                VStack(alignment: .leading, spacing: 0) {
                    // No intake pace exists to judge "on track", so under target only says what's left.
                    CardHeader("Calories", status: target == nil ? nil : over ? ("Over", .watch)
                               : ("\(TodayFormat.number(f?.kcalLeft) ?? "–") left", .quiet))
                    // 24 above and below keeps the meter level with Sleep's captioned one beside it.
                    Meter(fraction: target.map { eaten / max($0, 1) } ?? 0, fill: over ? VColor.watch : VColor.text).padding(.top, VSpace.s5)
                    Figure(TodayFormat.number(f?.kcalEaten) ?? "–", unit: target.map { "/\(TodayFormat.number($0) ?? "")" }).padding(.top, VSpace.s5)
                }
            }
        }
    }

    private func stepsCard(_ a: TodayResponse.Activity?) -> some View {
        let target = Double(a?.stepsTarget ?? 0), steps = Double(a?.steps ?? 0), expected = a?.stepsExpectedNow.map(Double.init)
        return tap({ path.append(.metric(key: "steps")) }) {
            VCard {
                HStack(alignment: .bottom, spacing: VSpace.s4) {
                    VStack(alignment: .leading, spacing: VSpace.s3) {
                        HStack(spacing: VSpace.s3) {
                            Text("Steps").vText(.headline)
                            if let s = TodayCopy.paceStatus(a?.stepsPace) { StatusWord(s.0, tone: s.1) }
                        }
                        Figure(TodayFormat.number(a?.steps) ?? "–", unit: a?.stepsTarget.map { "/\(TodayFormat.number($0) ?? "")" },
                               color: a?.steps == nil ? VColor.text3 : nil)
                    }
                    .fixedSize()
                    Meter(fraction: target > 0 ? steps / target : 0, marker: target > 0 ? expected.map { $0 / target } : nil,
                          caption: expected.map { "Usual by now \(TodayFormat.number($0) ?? "")" })
                        .padding(.bottom, VSpace.s2)
                }
            }
        }
    }

    @ViewBuilder private func musclesCard(_ tr: TodayResponse.Training?) -> some View {
        tap({ router.tab = .train }) {
            VCard {
                VStack(spacing: VSpace.s2) {
                    CardHeader("Muscles", status: TodayCopy.muscleStatus(tr))
                    MuscleMap(heat: tr?.heat ?? [:], view: .both, seam: VColor.surface).frame(width: 168, height: 136)
                }
            }
        }
    }

    // MARK: Stale (frame 24)

    private func staleBody(section: String, cause: String) -> some View {
        let t = store.today.value
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(VColor.watch).frame(height: 1)
                Text(section).vText(.label, color: VColor.watch).padding(.top, VSpace.s3)
                TodayHeadline(lines: HeadlineLines.split(cause)).padding(.top, VSpace.s3)
                Text(StaleState.body).vText(.body).padding(.top, VSpace.s3)
                PrimaryButton("Fix sync") { router.open(.settingsSync) }.padding(.top, VSpace.s5)
            }
            .padding(.top, VSpace.s4)
            recoveryCard(t?.recovery).padding(.top, VSpace.s5)
        }
        .padding(.horizontal, VSpace.edge)
    }
}

/// Today's words: headline lines, status words and h:mm, kept apart from layout so tests can pin them.
enum TodayCopy {
    /// "Steady day." over the server headline; an unknown band shows the headline alone.
    static func headline(_ t: TodayResponse) -> [String] {
        let lead: String? = switch t.recovery.band { case "ready": "Ready day."; case "steady": "Steady day."; case "ease": "Easy day."; case "rest": "Rest day."; default: nil }
        let head = t.verdict.headline.hasSuffix(".") ? t.verdict.headline : t.verdict.headline + "."
        return lead.map { [$0, head] } ?? HeadlineLines.split(head)
    }

    static func recoveryStatus(_ r: TodayResponse.Recovery?) -> (String, VTone)? {
        guard let r else { return nil }
        if r.status == "calibrating" { return ("Calibrating", .quiet) }
        if r.status != "ok" { return ("Missing", .quiet) }
        switch r.band {
        case "ready": return ("Ready", .good)
        case "steady": return ("Steady", .usual)
        case "ease": return ("Ease", .watch)
        case "rest": return ("Rest", .watch)
        default: return nil
        }
    }

    /// The word follows the server's flag (tint + arrow) so it never disagrees with the dot; unflagged reads Usual.
    static func vitalWord(_ p: TodayResponse.VitalPart?) -> String {
        guard let p, p.tint != nil else { return "Usual" }
        switch p.arrow { case "up": return "High"; case "down": return "Low"; default: return "Off usual" }
    }

    static func sleepStatus(_ s: TodayResponse.SleepSummary?) -> (String, VTone)? {
        guard let a = s?.asleepH, let n = s?.needH else { return nil }
        return a + 0.25 < n ? ("Short", .watch) : a >= n ? ("Good", .good) : ("OK", .usual)
    }

    static func paceStatus(_ raw: String?) -> (String, VTone)? {
        switch raw {
        case "ahead": ("Ahead", .good)
        case "on_pace": ("On pace", .good)
        case "behind": ("Behind", .watch)
        default: nil
        }
    }

    /// The loaded muscle in red, else Clear; a body that has never trained says so.
    static func muscleStatus(_ tr: TodayResponse.Training?) -> (String, VTone)? {
        guard let tr else { return nil }
        if tr.heat.values.allSatisfy({ $0 == 0 }) { return ("No workouts yet", .quiet) }
        if let loaded = tr.loadedLabel { return (loaded.prefix(1).uppercased() + loaded.dropFirst().lowercased(), .load) }
        return ("Clear", .good)
    }

    static func hm(_ hours: Double) -> String {
        let m = Int((hours * 60).rounded())
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }
}

private extension View {
    /// ≥ 44 pt tap target around small labels without moving them.
    func hitSlop() -> some View {
        padding(VSpace.s4).contentShape(Rectangle()).padding(-VSpace.s4)
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
     "training": {"fresh_label": null, "loaded_label": null, "splits": [],
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
