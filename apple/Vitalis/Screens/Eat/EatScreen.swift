import SwiftUI
import VitalisKit
import VitalisUI

/// Eat tab (frames 07, 18, 27): the server's food day, quick actions, meals, and the usual as the one red action.
struct EatScreen: View {
    let store: EatStore
    @Environment(Router.self) private var router
    @State private var scanning = false
    /// Barcode handed to Describe; the sheet opens only after the scan cover has gone.
    @State private var describeCode: String?
    /// Asked once until answered: the calorie target starts from the goal (11 §8.2).
    @State private var needsGoal = false
    @State private var settingGoal = false

    init(store: EatStore = .shared) { self.store = store }

    var body: some View {
        ZStack(alignment: .bottom) {
            EatChrome(status: status.label, tint: status.tint, pulse: store.todayPulse) {
                ScrollView {
                    Group {
                        if needsGoal { goalPrompt }
                        if let day = store.day.value {
                            if day.empty && !store.pending.contains(where: { $0.day == day.day }) { EmptyEat(day: day, store: store, open: open) }
                            else { loaded(day) }
                        } else { placeholder }
                    }
                    .padding(.horizontal, VSpace.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, store.toast == nil ? 24 : 96)
                }
                .scrollIndicators(.hidden)
            }
            if let toast = store.toast {
                Toast(toast.text) { Task { await store.undo() } }
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .sensoryFeedback(.success, trigger: store.toast?.mealID) { _, new in new != nil }
        .task { await store.load() }
        .task(id: Services.shared.writesVersion) { await checkGoal() }
        .sheet(isPresented: $settingGoal) { GoalSheet() }
        .onChange(of: Services.shared.writesVersion) { Task { await store.writesDelivered() } }
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            guard let code = describeCode else { return }
            describeCode = nil
            store.requestedMode = .describe(text: "", barcode: code)
            router.sheet = .quickAdd(slot: store.day.value?.nextSlot)
        }) {
            ScanScreen(store: store, slot: store.day.value?.nextSlot ?? store.defaultSlot,
                       onDescribe: { code in describeCode = code; scanning = false }, onDone: { scanning = false })
        }
    }

    private var status: (label: String, tint: VTint) {
        guard let day = store.day.value else { return (store.day.error == nil ? "" : "OFFLINE", .steel) }
        if day.empty, store.pending.isEmpty { return ("NOTHING LOGGED", .steel) }
        let stale = StaleState(lastSync: APIDate.parse(day.freshness?.lastSync), lastSuccess: nil, failure: nil,
                               cachedAt: store.day.fetchedAt, refreshFailed: store.day.error != nil, now: Date())
        switch stale.status {
        case .synced(let label): return (label, .steel)
        case .offline(let label): return (label, .steel)
        case .stale(let label, _, _): return (label, .watch)
        }
    }

    private var goalPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel("Your goal", tint: .watch)
            Text("Lose, maintain or gain? Your calorie target starts from your goal and target weight.").vBody()
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton("Set my goal", size: .compact) { settingGoal = true }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rule() }
    }

    private func checkGoal() async {
        guard let api = Services.shared.api else { return }
        let t = try? await api.targets().value
        // Old servers send no `goal` flag: don't nag there.
        needsGoal = t.map { $0.isSet?.goal == false } ?? false
    }

    private func open(_ kind: FoodTile.Kind) {
        switch kind {
        case .scan: scanning = true
        case .search: store.requestedMode = .search(text: ""); router.sheet = .quickAdd(slot: store.day.value?.nextSlot)
        case .describe: store.requestedMode = .describe(text: "", barcode: nil); router.sheet = .quickAdd(slot: store.day.value?.nextSlot)
        case .usual: store.requestedMode = .home; router.sheet = .quickAdd(slot: store.day.value?.nextSlot)
        }
    }

    // MARK: Loaded

    /// While the Undo toast shows, frame 18: the just-added meal open, other meals collapsed, no quick actions.
    @ViewBuilder private func loaded(_ day: FoodDay) -> some View {
        let focus = store.toast != nil && store.meals.contains(where: \.justAdded)
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(context: day.dateLabel ?? day.day, title: "Eat") { dayNav(day) }
            hero(day)
            if !focus {
                VSection(top: 30) {
                    HStack(spacing: 0) {
                        ForEach(FoodTile.Kind.allCases.filter { $0 != .describe || store.describeAvailable }, id: \.self) { kind in
                            FoodTile(kind: kind, style: .square) { open(kind) }
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
            ForEach(store.meals, id: \.slot) { meal in mealSection(meal, day: day, focus: focus) }
            ForEach(waitingOnlySlots(day), id: \.self) { slot in pendingSection(slot: slot, day: day) }
            if !focus, let next = day.nextSlot, !store.meals.contains(where: { $0.slot == next }), !waitingOnlySlots(day).contains(next) {
                VSection(top: 22) {
                    slotHeader(title: next, detail: nil, kcal: nil, day: day, slot: next)
                    usualButton(day)
                }
            }
            if !focus, let note = day.targetNote { MonoLabel(note, size: .small).padding(.top, 22).fixedSize(horizontal: false, vertical: true) }
            errorLine
        }
    }

    private func dayNav(_ day: FoodDay) -> some View {
        HStack(spacing: 0) {
            SecondaryButton("Previous day", systemImage: "chevron.left", size: .icon, enabled: day.prevDay != nil) { Task { await store.goBack() } }
            SecondaryButton("Next day", systemImage: "chevron.right", size: .icon, enabled: day.nextDay != nil) { Task { await store.goForward() } }
        }
        .offset(x: 4)
    }

    private func hero(_ day: FoodDay) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                Text(FoodFormat.kcal(day.kcalLeft.map(abs))).vNumber(64, color: day.kcalLeft == nil ? VColor.steel : nil)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    MonoLabel(day.over ? "KCAL OVER" : "KCAL LEFT", tint: day.over ? .watch : .steel)
                    MonoLabel("\(FoodFormat.kcal(day.kcalEaten)) OF \(FoodFormat.kcal(day.kcalTarget))")
                }
            }
            ProgressTrack(day.kcalTarget.map { day.kcalEaten / max($0, 1) } ?? 0, flagged: day.over)
            HStack(alignment: .top, spacing: 32) {
                macro("Protein", day.macros.protein)
                macro("Carbs", day.macros.carbs)
                macro("Fat", day.macros.fat)
            }
            .padding(.top, 14)
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
    }

    private func macro(_ title: String, _ m: FoodDay.Macro) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel(title)
            HStack(spacing: 0) {
                Text(FoodFormat.grams(m.g)).vReading(14)
                Text(m.targetG.map { " / \(FoodFormat.grams($0)) G" } ?? " G").vReading(14, tint: .steel)
            }
            ProgressTrack(m.targetG.map { m.g / max($0, 1) } ?? 0).opacity(m.targetG == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Meals

    private func mealSection(_ meal: FoodDay.Meal, day: FoodDay, focus: Bool) -> some View {
        let collapsed = focus && !meal.justAdded
        let waiting = store.pendingEntries(slot: meal.slot)
        return VSection(top: collapsed ? 16 : 22) {
            slotHeader(title: meal.label, detail: meal.justAdded ? ("JUST NOW", VTint.bone) : meal.time.map { ($0, VTint.steel) },
                       kcal: meal.kcal, dim: collapsed, day: day, slot: meal.slot)
            if !collapsed {
                entryRows(store.entries(meal).map { ($0.id, $0.name, $0.portionText, $0.kcal) }, ruleLast: !waiting.isEmpty)
                if !waiting.isEmpty { waitingRows(waiting) }
                if meal.slot == day.nextSlot && !focus { usualButton(day) }
            }
        }
    }

    /// Slots with unsent entries and no server meal yet.
    private func waitingOnlySlots(_ day: FoodDay) -> [String] {
        ["breakfast", "lunch", "snack", "dinner"].filter { slot in
            !store.pendingEntries(slot: slot).isEmpty && !store.meals.contains { $0.slot == slot }
        }
    }

    private func pendingSection(slot: String, day: FoodDay) -> some View {
        VSection(top: 22) {
            slotHeader(title: slot, detail: ("WAITING TO SYNC", .steel), kcal: nil, day: day, slot: slot)
            waitingRows(store.pendingEntries(slot: slot), withLabel: false)
        }
    }

    private func slotHeader(title: String, detail: (String, VTint)?, kcal: Double?, dim: Bool = false, day: FoodDay, slot: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).vHeadline(22)
            if let detail { MonoLabel(detail.0, tint: detail.1) }
            Spacer(minLength: 8)
            if let kcal { Text(FoodFormat.kcal(kcal)).vNumber(20, color: dim ? VColor.steel : nil) }
            else if slot == day.nextSlot {
                Button { store.requestedMode = .home; router.sheet = .quickAdd(slot: slot) } label: { MonoLabel("+ Add", tint: .bone) }
                    .buttonStyle(.plain).accessibilityLabel("Add to \(slot.slotTitle)")
            }
        }
        .padding(.bottom, 4)
    }

    private func entryRows(_ rows: [(id: String, name: String, portion: String?, kcal: Double)], ruleLast: Bool = false) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
            ReadingRow([row.name, row.portion].compactMap { $0 }.joined(separator: " · "), value: FoodFormat.kcal(row.kcal),
                       showsRule: ruleLast || i < rows.count - 1, size: 13)
        }
    }

    @ViewBuilder private func waitingRows(_ entries: [FoodEntry], withLabel: Bool = true) -> some View {
        if withLabel { MonoLabel("Waiting to sync", size: .small).padding(.top, 8) }
        entryRows(entries.map { ($0.id, $0.name, $0.portionText, $0.kcal) }).opacity(0.7)
    }

    @ViewBuilder private func usualButton(_ day: FoodDay) -> some View {
        if let usual = day.usualNext {
            PrimaryButton("Add usual: \(usual.name)", value: FoodFormat.kcal(usual.kcal)) { Task { await store.logUsual() } }
                .padding(.top, 14)
        }
    }

    @ViewBuilder private var errorLine: some View {
        if let error = store.day.error as? APIError, store.day.fromCache || store.day.value != nil {
            MonoLabel(error.statusLine, tint: .watch).padding(.top, 14)
        }
    }

    // MARK: Loading / no cache

    @ViewBuilder private var placeholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(context: "Today", title: "Eat")
            Text(FoodFormat.dash).vNumber(64, color: VColor.steel).padding(.top, 18)
            MonoLabel("KCAL LEFT").padding(.top, 6)
            if store.day.error != nil {
                Text("Connect to your server to see today.").vBody().padding(.top, 24)
                SecondaryButton("Try again") { Task { await store.load() } }.padding(.top, 16)
            }
        }
    }
}

/// Frame 27: nothing logged yet. Day navigation stays (the frame omits it) so earlier days remain reachable.
private struct EmptyEat: View {
    let day: FoodDay
    let store: EatStore
    let open: (FoodTile.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                HeadlineLines(["Eat"], size: 46)
                Spacer()
                if day.nextDay != nil || day.prevDay != nil {
                    HStack(spacing: 0) {
                        SecondaryButton("Previous day", systemImage: "chevron.left", size: .icon, enabled: day.prevDay != nil) { Task { await store.goBack() } }
                        SecondaryButton("Next day", systemImage: "chevron.right", size: .icon, enabled: day.nextDay != nil) { Task { await store.goForward() } }
                    }
                    .offset(x: 4)
                }
            }
            .padding(.top, 14)
            Text(FoodFormat.kcal(day.kcalTarget)).vNumber(96, color: day.kcalTarget == nil ? VColor.steel : nil)
                .lineLimit(1).minimumScaleFactor(0.6).padding(.top, 30)
            MonoLabel(["KCAL TO GO", day.macros.protein.targetG.map { "\(FoodFormat.grams($0)) G PROTEIN" }].compactMap { $0 }.joined(separator: " · "))
                .padding(.top, 4)
            VSection(top: 30) {
                Text("Start with \(day.nextSlot ?? store.defaultSlot)").vHeadline(30)
                Text("Meals you repeat become one tap after a few days.").vBody(14.5).padding(.top, 8)
                HStack(spacing: 10) {
                    ForEach([FoodTile.Kind.search, .scan, .describe].filter { $0 != .describe || store.describeAvailable }, id: \.self) { kind in
                        FoodTile(kind: kind, style: .tile(height: 84)) { open(kind) }
                    }
                }
                .padding(.top, 26)
                if let usual = day.usualNext {
                    PrimaryButton("Add usual: \(usual.name)", value: FoodFormat.kcal(usual.kcal)) { Task { await store.logUsual() } }
                        .padding(.top, 20)
                }
            }
        }
    }
}

#if DEBUG
private let justAddedJSON = """
{"day":"2026-10-24","date_label":"TODAY · SAT 24 OCT","prev_day":"2026-10-23","next_day":null,"kcal_target":2300,"kcal_eaten":1185,
"kcal_left":1115,"over":false,"macros":{"protein":{"g":62,"target_g":160},"carbs":{"g":133,"target_g":null},"fat":{"g":45,"target_g":null}},
"target_note":"TARGET 2,300 KCAL ADJUSTS WEEKLY FROM YOUR WEIGHT TREND","meals":[
{"slot":"breakfast","label":"BREAKFAST","time":"08:10","kcal":520,"just_added":false,"entries":[{"id":"e1","meal_id":"m1","name":"Masala omelette","portion_text":"3 eggs","grams":null,"kcal":310,"protein_g":21,"carbs_g":6,"fat_g":22,"estimate":false,"source":"recent"}]},
{"slot":"lunch","label":"LUNCH","time":"13:05","kcal":665,"just_added":true,"entries":[
{"id":"e2","meal_id":"m2","name":"Roti","portion_text":"2 pieces","grams":80,"kcal":240,"protein_g":7,"carbs_g":44,"fat_g":4,"estimate":true,"source":"describe"},
{"id":"e3","meal_id":"m2","name":"Dal makhani","portion_text":"1 bowl","grams":200,"kcal":330,"protein_g":12,"carbs_g":30,"fat_g":18,"estimate":true,"source":"describe"},
{"id":"e4","meal_id":"m2","name":"Curd","portion_text":"1 bowl","grams":150,"kcal":95,"protein_g":5,"carbs_g":7,"fat_g":5,"estimate":true,"source":"describe"}]}],
"next_slot":"snack","usual_next":null,"empty":false,"freshness":{"last_sync":"2026-10-24T13:06:00+05:30","data_through":null,"today":"2026-10-24"}}
"""

private let emptyJSON = """
{"day":"2026-10-24","date_label":"TODAY · SAT 24 OCT","prev_day":"2026-10-23","next_day":null,"kcal_target":2300,"kcal_eaten":0,
"kcal_left":2300,"over":false,"macros":{"protein":{"g":0,"target_g":160},"carbs":{"g":0,"target_g":null},"fat":{"g":0,"target_g":null}},
"target_note":null,"meals":[],"next_slot":"breakfast","usual_next":null,"empty":true,"freshness":null}
"""

private func previewDay(_ json: String) -> FoodDay? { try? APICoding.decoder().decode(FoodDay.self, from: Data(json.utf8)) }

#Preview("Eat · loaded") {
    EatScreen(store: EatPreview.store()).vScreen().environment(Router()).onAppear { VFont.register() }
}

#Preview("Eat · just added + Undo") {
    let store = EatPreview.store(day: previewDay(justAddedJSON))
    store.previewToast("ADDED TO LUNCH · 665 KCAL")
    return EatScreen(store: store).vScreen().environment(Router()).onAppear { VFont.register() }
}

#Preview("Eat · waiting to sync") {
    let store = EatPreview.store()
    store.previewPending([FoodEntry(id: "p1", mealId: "pm", slot: "snack", eatenAt: "2026-10-24T16:05:00+05:30", name: "Protein lassi",
                                    portionText: "200 ml", kcal: 152, source: "barcode")])
    return EatScreen(store: store).vScreen().environment(Router()).onAppear { VFont.register() }
}

#Preview("Eat · empty") {
    EatScreen(store: EatPreview.store(day: previewDay(emptyJSON))).vScreen().environment(Router()).onAppear { VFont.register() }
}

#Preview("Eat · offline, cached") {
    let store = EatPreview.store()
    return EatScreen(store: store).vScreen().environment(Router()).onAppear { VFont.register() }
        .task { await store.day.load { throw APIError.transport(URLError(.notConnectedToInternet)) } }
}

#Preview("Eat · offline, no cache") {
    // No value and no server: the load fails, showing the body line and Try again.
    EatScreen(store: EatPreview.store(day: nil)).vScreen().environment(Router()).onAppear { VFont.register() }
}
#endif
