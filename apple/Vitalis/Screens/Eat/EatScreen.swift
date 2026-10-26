import SwiftUI
import VitalisKit
import VitalisUI

/// Eat tab: the server's food day as a headline, calories and macros, saved meals one tap away, then every food logged.
struct EatScreen: View {
    let store: EatStore
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanning = false
    /// Barcode handed to Describe; the sheet opens only after the scan cover has gone.
    @State private var describeCode: String?
    /// Asked once until answered: the calorie target starts from the goal (11 §8.2).
    @State private var needsGoal = false
    @State private var settingGoal = false
    @State private var editing: EditTarget?
    @State private var savedForm: SavedFormTarget?

    struct EditTarget: Identifiable { let entry: FoodDayEntry; let slot: String; let time: String?; let day: String; var id: String { entry.id } }

    init(store: EatStore = .shared) { self.store = store }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VHeader("Eat", freshness: DataFreshness(fetchedAt: store.day.fetchedAt, refreshing: store.day.isLoading)) {
                        PillButton("+ Add", fill: VColor.eat, ink: VColor.onEat) { open(.usual) }.accessibilityLabel("Add food")
                    }
                    Group {
                        if needsGoal { goalPrompt }
                        if let day = store.day.value {
                            if day.empty && !store.pending.contains(where: { $0.day == day.day }) {
                                EmptyEat(day: day, store: store, open: open)
                                SavedStrip(store: store, form: $savedForm)
                            } else { loaded(day) }
                        } else { placeholder }
                    }
                    .padding(.bottom, store.toast == nil ? VSpace.s5 : VSpace.s7 + VSpace.s7)
                }
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
            if let toast = store.toast {
                Toast(toast.text) { Task { await store.undo() } }
                    .padding(.bottom, VSpace.s4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .sensoryFeedback(.success, trigger: store.toast?.mealID) { _, new in new != nil }
        // Runs on every appear and on every return to the foreground.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await store.refresh()
        }
        .sheet(item: $savedForm) { t in SavedMealForm(store: store, meal: t.meal) }
        .task(id: Services.shared.writesVersion) { await checkGoal() }
        .sheet(isPresented: $settingGoal) { GoalSheet() }
        .sheet(item: $editing) { t in FoodEditSheet(entry: t.entry, day: t.day, slot: t.slot, mealTime: t.time, store: store) }
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

    private var goalPrompt: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Your goal")
            VCard {
                VStack(alignment: .leading, spacing: VSpace.s3) {
                    Text("Lose, maintain or gain? Your calorie target starts from your goal and target weight.").vText(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    SecondaryButton("Set my goal", size: .compact) { settingGoal = true }
                }
            }
            .padding(.horizontal, VSpace.edge)
        }
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

    /// The day in words, calories on the clock, macros against their targets, then every food (tap to edit, swipe to delete).
    @ViewBuilder private func loaded(_ day: FoodDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            EatHeadline(lines: EatCopy.headline(day)).padding(.horizontal, VSpace.edge).padding(.top, VSpace.s4)
            DayStepper(day: day, store: store)
            calories(day).padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5)
            macros(day).padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
            SavedStrip(store: store, form: $savedForm)
            SectionLabel(day.nextDay == nil ? "Logged today" : "Logged")
            ListCard {
                let rows = store.meals.flatMap { m in store.entries(m).map { (m, $0) } }
                ForEach(rows, id: \.1.id) { row in
                    // Bleeds to the card's edges so Edit and Delete fill the row; the card clips the corners.
                    SwipeRow(onDelete: { Task { await store.delete(row.1) } }, onEdit: { edit(row.1, row.0, day) }) {
                        entryRow(row.1, meal: row.0).padding(.horizontal, VSpace.s4)
                    }
                    .padding(.horizontal, -VSpace.s4)
                }
                ForEach(store.pending.filter { $0.day == day.day }) { p in pendingRow(p.entry) }
                if nextSlotOpen(day), let next = day.nextSlot { nextRow(next, day) }
            }
            .clipShape(RoundedRectangle(cornerRadius: VRadius.card, style: .continuous))
            .padding(.horizontal, VSpace.edge)
            if let note = day.targetNote {
                Text(note).vText(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
            }
            errorLine.padding(.horizontal, VSpace.edge)
        }
    }

    private func calories(_ day: FoodDay) -> some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.s3) {
                CardHeader("Calories", status: day.over ? ("Over", .watch) : nil)
                HStack(alignment: .lastTextBaseline) {
                    Figure(FoodFormat.kcal(day.kcalEaten), unit: "kcal", size: 40, color: day.over ? VColor.watch : nil)
                    Spacer(minLength: VSpace.s2)
                    if let t = day.kcalTarget { Text("of \(FoodFormat.kcal(t))").vText(.secondary) }
                }
                if let t = day.kcalTarget {
                    Meter(fraction: day.kcalEaten / max(t, 1), fill: day.over ? VColor.watch : VColor.eat)
                }
                DayCurve(meals: store.meals, target: day.kcalTarget, eaten: day.kcalEaten, isToday: day.nextDay == nil, nextSlot: day.nextSlot)
                    .padding(.top, VSpace.s2)
            }
        }
    }

    private func macros(_ day: FoodDay) -> some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.s4) {
                macroRow("Protein", day.macros.protein,
                         status: day.macros.protein.targetG == nil ? nil : EatCopy.proteinBehind(day) ? ("Behind", .watch) : ("On track", .good))
                macroRow("Carbs", day.macros.carbs, status: nil)
                macroRow("Fat", day.macros.fat, status: nil)
            }
        }
    }

    private func macroRow(_ name: String, _ m: FoodDay.Macro, status: (String, VTone)?) -> some View {
        VStack(alignment: .leading, spacing: VSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: VSpace.s2) {
                Text(name).vText(.headline)
                if let status { StatusWord(status.0, tone: status.1) }
                Spacer(minLength: VSpace.s2)
                Figure(FoodFormat.grams(m.g), unit: m.targetG.map { "/ \(FoodFormat.grams($0)) g" } ?? "g", size: 20)
            }
            if let t = m.targetG { Meter(fraction: m.g / max(t, 1), fill: VColor.eat) }
        }
        .accessibilityElement(children: .combine)
    }

    private func nextSlotOpen(_ day: FoodDay) -> Bool {
        guard day.nextDay == nil, let next = day.nextSlot else { return false }
        return !store.meals.contains { $0.slot == next }
    }

    private func edit(_ e: FoodDayEntry, _ meal: FoodDay.Meal, _ day: FoodDay) { editing = EditTarget(entry: e, slot: meal.slot, time: meal.time, day: day.day) }

    private func entryRow(_ e: FoodDayEntry, meal: FoodDay.Meal) -> some View {
        let time = e.eatenAt.flatMap(APIDate.clockText) ?? meal.time
        return ListRow(e.name, subtitle: [time, meal.slot.capitalized, e.portionText].compactMap { $0 }.joined(separator: " · "),
                       value: "\(FoodFormat.kcal(e.kcal)) kcal", chevron: false)
            .onTapGesture { if let day = store.day.value { edit(e, meal, day) } }
            .accessibilityHint("Opens to change the amount, meal or time")
    }

    private func pendingRow(_ e: FoodEntry) -> some View {
        ListRow(e.name, subtitle: e.portionText, value: "\(FoodFormat.kcal(e.kcal)) kcal", chevron: false) {
            StatusWord("Waiting to sync", tone: .watch)
        }
        .opacity(0.7)
    }

    private func nextRow(_ next: String, _ day: FoodDay) -> some View {
        Button { open(.usual) } label: {
            ListRow(next.capitalized, subtitle: day.usualNext.map { "Usually \($0.name.lowercased())" } ?? "Nothing yet", chevron: false) {
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(VColor.eat)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Add")
    }

    @ViewBuilder private var errorLine: some View {
        if let error = store.day.error as? APIError, store.day.fromCache || store.day.value != nil {
            Text(error.statusLine).vText(.secondary, color: VColor.watch).padding(.top, VSpace.s3)
        }
    }

    // MARK: Loading / no cache

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            Figure(FoodFormat.dash, unit: "kcal left", size: 56, color: VColor.text3)
            if store.day.error != nil {
                Text("Connect to your server to see today.").vText(.body).padding(.top, VSpace.s5)
                SecondaryButton("Try again") { Task { await store.load() } }.padding(.top, VSpace.s4)
            }
        }
        .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5)
    }
}

/// Eat's headline: one condensed display line per sentence.
private struct EatHeadline: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.self) { Text($0).vText(.display).lineLimit(1).minimumScaleFactor(0.7) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// ‹ Today › under the headline, only when there is another day to go to.
private struct DayStepper: View {
    let day: FoodDay
    let store: EatStore
    var body: some View {
        if day.nextDay != nil || day.prevDay != nil {
            PeriodStepper(day.nextDay == nil ? "Today" : (day.dateLabel ?? day.day).capitalized,
                          back: day.prevDay == nil ? nil : { Task { await store.goBack() } },
                          forward: day.nextDay == nil ? nil : { Task { await store.goForward() } })
                .padding(.horizontal, VSpace.s2).padding(.top, VSpace.s2)
        }
    }
}

/// Which saved meal the form opens on: nil = a new one.
struct SavedFormTarget: Identifiable {
    let meal: SavedMealInfo?
    var id: String { meal?.id ?? "new" }
}

/// Saved meals one tap from the day: tap adds to the next meal, hold to edit or delete, New to type one in.
struct SavedStrip: View {
    let store: EatStore
    @Binding var form: SavedFormTarget?
    private static let chipHeight = VSpace.s7 + VSpace.s3

    var body: some View {
        let meals = store.savedMeals
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Saved", note: meals.isEmpty ? nil : "Tap to add · hold to edit")
            ScrollView(.horizontal) {
                HStack(spacing: VSpace.s2) {
                    ForEach(meals, id: \.id) { m in
                        Button { Task { await store.logSaved(m) } } label: { chip(m) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { form = SavedFormTarget(meal: m) } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { Task { await store.deleteSavedMeal(m.id) } } label: { Label("Delete", systemImage: "trash") }
                            }
                            .accessibilityLabel("Add \(m.name), \(FoodFormat.kcal(m.kcal)) kilocalories")
                    }
                    Button { form = SavedFormTarget(meal: nil) } label: {
                        HStack(spacing: VSpace.s2) {
                            Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(VColor.eat)
                            Text(meals.isEmpty ? "Save a meal you repeat" : "New").vText(.headline)
                        }
                        .padding(.horizontal, VSpace.s4).frame(height: Self.chipHeight)
                        .overlay(RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous)
                            .strokeBorder(VColor.dashed, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New saved meal")
                }
                .padding(.horizontal, VSpace.edge)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func chip(_ m: SavedMealInfo) -> some View {
        let protein = m.items.compactMap(\.proteinG).reduce(0, +)
        return HStack(spacing: VSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).vText(.headline).lineLimit(1)
                Text([FoodFormat.kcal(m.kcal) + " kcal", protein > 0 ? "\(FoodFormat.grams(protein)) g protein" : nil].compactMap { $0 }.joined(separator: " · "))
                    .vText(.secondary).lineLimit(1)
            }
            Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(VColor.eat)
        }
        .padding(.horizontal, VSpace.s4).frame(height: Self.chipHeight)
        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
    }
}

/// Nothing logged yet: what's left to eat, the ways to add, and the usual as the one primary action.
private struct EmptyEat: View {
    let day: FoodDay
    let store: EatStore
    let open: (FoodTile.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EatHeadline(lines: [day.kcalTarget.map { "\(FoodFormat.kcal($0)) kcal to go." } ?? "Nothing logged yet.",
                                "Start with \(day.nextSlot ?? store.defaultSlot)."])
                .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s4)
            DayStepper(day: day, store: store)
            VStack(alignment: .leading, spacing: 0) {
                if let protein = day.macros.protein.targetG {
                    Text("\(FoodFormat.grams(protein)) g protein to go").vText(.secondary).padding(.top, VSpace.s2)
                }
                Text("Meals you repeat become one tap after a few days.").vText(.secondary).padding(.top, VSpace.s1)
                HStack(spacing: VSpace.s3) {
                    ForEach([FoodTile.Kind.search, .scan, .describe].filter { $0 != .describe || store.describeAvailable }, id: \.self) { kind in
                        FoodTile(kind: kind) { open(kind) }
                    }
                }
                .padding(.top, VSpace.s5)
                if let usual = day.usualNext {
                    PrimaryButton("Add usual: \(usual.name)", value: "\(FoodFormat.kcal(usual.kcal)) kcal", fill: VColor.eat, ink: VColor.onEat) {
                        Task { await store.logUsual() }
                    }
                    .padding(.top, VSpace.s3)
                }
            }
            .padding(.horizontal, VSpace.edge)
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
