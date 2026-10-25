import SwiftUI
import VitalisKit
import VitalisUI

/// Sleep tab (frame 04, brief 03 → Sleep): one night by wake day, its score parts, the week and tonight's bed-by.
struct SleepScreen: View {
    @State private var store: SleepStore
    @State private var showsStages = false
    private let live: Bool

    init() { _store = State(initialValue: SleepStore.shared); live = true }
    /// Previews: a preloaded store and no fetching.
    init(store: SleepStore) { _store = State(initialValue: store); live = false }

    private var v: SleepResponse? { store.value }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TabTopChrome(status: TabTopChrome.status(store.night, freshness: v?.freshness))
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.top, 2)
                    if v == nil, store.night.error != nil, !store.night.isLoading {
                        unreachable
                    } else {
                        hero.padding(.top, 14)
                        if v?.hasNight == false { noNight } else if v != nil { parts }
                        week
                        tonight
                    }
                }
                .padding(.horizontal, VSpace.gutter)
                .padding(.bottom, 32)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { if live { await store.load(force: true) } }
        .task { if live { await store.load() } }
        .sheet(isPresented: $showsStages) { SleepStagesSheet(stages: v?.stages) }
    }

    // MARK: Header

    private var header: some View {
        ScreenHeader(context: context, title: "Sleep") {
            HStack(spacing: 0) {
                SecondaryButton("Previous night", systemImage: "chevron.left", size: .icon, enabled: store.canGoBack) {
                    Task { await store.back() }
                }
                SecondaryButton("Next night", systemImage: "chevron.right", size: .icon, enabled: store.canGoForward) {
                    Task { await store.forward() }
                }
            }
            .padding(.trailing, -4)
        }
    }

    /// `LAST NIGHT · 23:02 TO 06:51` on the latest night, the wake day otherwise.
    private var context: String {
        guard let v else { return "LAST NIGHT" }
        let day = v.nextDay == nil ? "LAST NIGHT" : SleepBodyFormat.dayTitle(v.day)
        guard let n = v.night, let a = APIDate.clockText(n.sleepStart), let b = APIDate.clockText(n.sleepEnd) else { return day }
        return "\(day) · \(a) TO \(b)"
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(v?.score.map(String.init) ?? SleepBodyFormat.dash)
                    .vNumber(88, color: v?.score == nil ? VColor.steel : nil)
                    .lineLimit(1).minimumScaleFactor(0.6)
                MonoLabel(v?.label.map { "SCORE · \($0)" } ?? "SCORE")
            }
            .frame(width: 138, alignment: .leading)
            VStack(spacing: 0) {
                ReadingRow("Duration", value: v?.duration?.asleepLabel ?? SleepBodyFormat.dash, tint: tint(v?.duration?.asleepLabel))
                ReadingRow("VS usual", value: v?.duration?.vsUsualLabel ?? SleepBodyFormat.dash, tint: vsUsualTint)
                ReadingRow("Need", value: v?.duration?.needLabel ?? SleepBodyFormat.dash, tint: tint(v?.duration?.needLabel), showsRule: false)
            }
            .padding(.top, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture { if v?.stages != nil { showsStages = true } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(v?.stages != nil ? .isButton : [])
        .accessibilityHint(v?.stages != nil ? "Shows sleep stages" : "")
    }

    /// The server sends the signed label but no tint; more sleep than usual reads `good`, less `watch`.
    private var vsUsualTint: VTint {
        guard let m = v?.duration?.vsUsualMin else { return .steel }
        return m > 0 ? .good : m < 0 ? .watch : .bone
    }

    private func tint(_ value: String?) -> VTint { value == nil ? .steel : .bone }

    // MARK: Parts

    private var parts: some View {
        VSection(top: 18) {
            VStack(alignment: .leading, spacing: 0) {
                MonoLabel(v?.score.map { "What made it \($0)" } ?? "What made it")
                let items = v?.parts ?? []
                ForEach(Array(items.enumerated()), id: \.element.key) { i, part in
                    partRow(part)
                    if i < items.count - 1 { Rule() }
                }
            }
        }
    }

    private func partRow(_ part: SleepResponse.Part) -> some View {
        let flagged = part.flagged == true
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(part.label).vReading(13).textCase(.uppercase).lineLimit(1)
                if let detail = part.detail { MonoLabel(detail, size: .small).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ProgressTrack(Double(part.score ?? 0) / 100, flagged: flagged).frame(width: 96)
            Text(part.score.map(String.init) ?? SleepBodyFormat.dash)
                .vNumber(28, color: part.score == nil ? VColor.steel : flagged ? VColor.watch : nil)
                .lineLimit(1).fixedSize()
                .frame(minWidth: 56, alignment: .trailing)
        }
        .frame(minHeight: 42)
        .accessibilityElement(children: .combine)
    }

    private var noNight: some View {
        VSection(top: 18) {
            VStack(alignment: .leading, spacing: 6) {
                MonoLabel("No night")
                Text("No sleep recorded").vBody()
            }
        }
    }

    // MARK: Week

    private var week: some View {
        VSection(top: 22) {
            VStack(spacing: 18) {
                HStack {
                    MonoLabel("This week")
                    Spacer()
                    if let label = store.week?.label { MonoLabel(label) }
                }
                WeekBars(weekBars, maxHeight: Self.weekBarMax)
            }
        }
    }

    /// Design default bar height `max(4, (score − 46) × 8/7)` pt (brief 03), so a 100 maps to the tallest bar.
    private static let weekBarMax: CGFloat = (100 - 46) * 8 / 7

    private var weekBars: [WeekBars.Bar] {
        (store.week?.nights ?? []).map { night in
            let pt = night.score.map { max(4, (Double($0) - 46) * 8 / 7) } ?? 0
            return WeekBars.Bar(id: night.day, letter: SleepBodyFormat.letter(night.day), height: pt / Self.weekBarMax,
                                value: night.score.map(String.init) ?? SleepBodyFormat.dash, isToday: night.day == v?.day)
        }
    }

    // MARK: Tonight

    private var tonight: some View {
        VSection(top: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        MonoLabel("Tonight")
                        Text("Bed by \(v?.tonight?.bedBy ?? SleepBodyFormat.dash)").vHeadline(26).lineLimit(1).minimumScaleFactor(0.7)
                        if let label = v?.tonight?.label { MonoLabel(label, size: .small).lineLimit(1).minimumScaleFactor(0.8) }
                    }
                    Spacer(minLength: 0)
                    if v?.tonight?.bedBy != nil {
                        SecondaryButton(store.reminder == .set ? "Reminder set" : "Remind me", enabled: store.reminder != .set) {
                            Task { await store.remindMe() }
                        }
                    }
                }
                if store.reminder == .denied { MonoLabel("Notifications are off for Vitalis", size: .small, tint: .watch) }
            }
        }
    }

    // MARK: Error without cache

    private var unreachable: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to your server to see your sleep.").vBody()
            SecondaryButton("Try again") { Task { await store.load(force: true) } }
        }
        .padding(.top, 24)
    }
}

/// Stages one tap down from the hero, with the server's note that they are estimates.
private struct SleepStagesSheet: View {
    let stages: SleepResponse.Stages?

    var body: some View {
        SheetChrome {
            VStack(alignment: .leading, spacing: 0) {
                Text("Stages").vHeadline(22).padding(.top, 20).padding(.bottom, 12)
                ReadingRow("Core", value: SleepBodyFormat.hours(stages?.coreH))
                ReadingRow("Deep", value: SleepBodyFormat.hours(stages?.deepH))
                ReadingRow("REM", value: SleepBodyFormat.hours(stages?.remH))
                ReadingRow("Awake", value: SleepBodyFormat.hours(stages?.awakeH), showsRule: false)
                if let note = stages?.note { Text(note).vBody().padding(.top, 16) }
            }
            .padding(.horizontal, VSpace.gutter)
        }
        .presentationDetents([.height(340)])
    }
}

@MainActor private func previewStore(_ value: SleepResponse?, week: SleepWeekResponse? = SleepBodyPreviewData.week) -> SleepStore {
    let store = SleepStore(api: { nil })
    store.preload(value, week: week)
    return store
}

#Preview("Sleep · loaded") {
    SleepScreen(store: previewStore(SleepBodyPreviewData.sleep)).vScreen().onAppear { VFont.register() }
}

#Preview("Sleep · flagged part, earlier night") {
    SleepScreen(store: previewStore(SleepBodyPreviewData.flagged, week: nil)).vScreen().onAppear { VFont.register() }
}

#Preview("Sleep · no sleep recorded") {
    SleepScreen(store: previewStore(SleepBodyPreviewData.noNight)).vScreen().onAppear { VFont.register() }
}

#Preview("Sleep · loading") {
    SleepScreen(store: previewStore(nil, week: nil)).vScreen().onAppear { VFont.register() }
}

#Preview("Sleep · stages sheet") {
    Color.clear.sheet(isPresented: .constant(true)) { SleepStagesSheet(stages: SleepBodyPreviewData.sleep?.stages) }
        .vScreen().onAppear { VFont.register() }
}
