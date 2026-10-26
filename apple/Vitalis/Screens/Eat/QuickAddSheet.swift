import SwiftUI
import VitalisKit
import VitalisUI

/// Quick add (frame 13) and the Search / Describe modes (frames 14, 15) in one sheet; Scan opens full screen.
struct QuickAddSheet: View {
    var slot: String?
    let store: EatStore
    @Environment(Router.self) private var router
    @State private var chosenSlot: String?
    @State private var mode: FoodAddMode = .home
    @State private var search = FoodSearchStore.live()
    @State private var describe: DescribeStore?
    @State private var scanning = false
    @State private var savedForm: SavedFormTarget?

    init(slot: String?, store: EatStore = .shared) {
        self.slot = slot; self.store = store
        // Open straight in the mode an Eat tile asked for, without a frame of the home list first.
        switch store.requestedMode {
        case .search?: _mode = State(initialValue: .search(text: ""))
        case .describe(let text, let barcode)?:
            _mode = State(initialValue: .describe(text: text, barcode: barcode))
            _describe = State(initialValue: DescribeStore.live(text: text, barcode: barcode))
        default: break
        }
    }

    private var currentSlot: String { chosenSlot ?? slot ?? store.quick.value?.slot ?? store.day.value?.nextSlot ?? store.defaultSlot }

    var body: some View {
        SheetChrome {
            VStack(alignment: .leading, spacing: 0) {
                header
                switch mode {
                case .home: home
                case .search: FoodSearchView(search: search, store: store) { add($0, source: $1, sourceRef: $2, estimate: $3) } describe: { text in
                    go(.describe(text: text, barcode: nil))
                }
                case .describe:
                    if let describe { DescribeView(describe: describe, store: store, slot: currentSlot) { drafts in finishDescribe(drafts, describe) } }
                }
            }
            .padding(.horizontal, VSpace.edge)
        }
        .presentationDetents([.custom(BelowPulseDetent.self)])
        .task {
            store.requestedMode = nil
            await store.loadQuick(slot: slot)
        }
        .sheet(item: $savedForm) { t in SavedMealForm(store: store, meal: t.meal) }
        .fullScreenCover(isPresented: $scanning) {
            ScanScreen(store: store, slot: currentSlot, onDescribe: { code in scanning = false; go(.describe(text: "", barcode: code)) },
                       onDone: { scanning = false; router.sheet = nil })
        }
    }

    private func go(_ next: FoodAddMode) {
        if case .describe(let text, let barcode) = next { describe = DescribeStore.live(text: text, barcode: barcode) }
        if case .search(let text) = next, !text.isEmpty { search.update(query: text) }
        mode = next
    }

    /// Every plus logs immediately; the toast shows on Eat once the sheet is gone.
    private func add(_ drafts: [FoodDraft], source: String, sourceRef: String? = nil, estimate: Bool? = nil) {
        let slot = currentSlot
        // Stay where the add started; the Undo toast follows to any tab (RootView).
        router.sheet = nil
        Task { await store.log(drafts, slot: slot, source: source, sourceRef: sourceRef, estimate: estimate) }
    }

    private func finishDescribe(_ drafts: [FoodDraft], _ describe: DescribeStore) {
        if let code = describe.barcode, let item = BarcodeItem(describing: drafts, words: describe.text) {
            Task { await store.rememberBarcode(code, item: item) }
        }
        add(drafts, source: "describe", estimate: true)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Button { if mode == .home { router.sheet = nil } else { mode = .home } } label: {
                        HStack(spacing: VSpace.s1) {
                            if mode != .home { Image(systemName: "chevron.left").font(.body.weight(.semibold)) }
                            Text(mode == .home ? "Cancel" : "Back").vText(.headline, color: VColor.text2)
                        }
                        .foregroundStyle(VColor.text2).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                slotMenu
            }
            .padding(.top, VSpace.s3)
            if mode != .home { segments.padding(.top, VSpace.s3) }
        }
    }

    private var slotMenu: some View {
        Menu {
            ForEach(["breakfast", "lunch", "snack", "dinner"], id: \.self) { s in
                Button(s.capitalized) { chosenSlot = s; Task { await store.loadQuick(slot: s) } }
            }
        } label: {
            HStack(spacing: VSpace.s1) {
                Text("Add to \(currentSlot.slotTitle)").vText(.title)
                if mode == .home { Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(VColor.text2) }
            }
        }
        .disabled(mode != .home)
        .accessibilityLabel("Add to \(currentSlot.slotTitle), change meal")
    }

    private var segments: some View {
        HStack(spacing: 0) {
            segment("Search", active: { if case .search = mode { true } else { false } }()) { go(.search(text: "")) }
            segment("Scan", active: false) { scanning = true }
            if store.describeAvailable || { if case .describe = mode { true } else { false } }() {
                segment("Describe", active: { if case .describe = mode { true } else { false } }()) { go(.describe(text: search.query, barcode: nil)) }
            }
        }
        .padding(VSpace.s1)
        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
    }

    private func segment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).vText(.headline, color: active ? VColor.text : VColor.text2)
                .frame(maxWidth: .infinity).padding(.vertical, VSpace.s2)
                .background(active ? VColor.segmentOn : .clear, in: RoundedRectangle(cornerRadius: VRadius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: Home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: VSpace.s3) {
                    FoodTile(kind: .search) { go(.search(text: "")) }
                    FoodTile(kind: .scan) { scanning = true }
                    if store.describeAvailable { FoodTile(kind: .describe) { go(.describe(text: "", barcode: nil)) } }
                }
                .padding(.top, VSpace.s5)
                if let quick = store.quick.value { lists(quick) }
                else if let error = store.quick.error {
                    Text((error as? APIError)?.statusLine ?? "Couldn't update").vText(.secondary, color: VColor.watch).padding(.top, VSpace.s5)
                }
            }
            .padding(.bottom, VSpace.s5)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func lists(_ quick: FoodQuick) -> some View {
        if let usual = quick.usual {
            SheetLabel("Your usual at \(currentSlot.slotTitle)")
            VCard {
                HStack(alignment: .center, spacing: VSpace.s3) {
                    VStack(alignment: .leading, spacing: VSpace.s1) {
                        Text(usual.name).vText(.title).lineLimit(2)
                        Text(["\(FoodFormat.kcal(usual.kcal)) kcal", usual.proteinG.map { "\(FoodFormat.grams($0)) g protein" }].compactMap { $0 }.joined(separator: " · "))
                            .vText(.secondary)
                    }
                    Spacer(minLength: VSpace.s2)
                    Button { add(usual.items.map(FoodDraft.init), source: "usual") } label: {
                        Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(VColor.onEat)
                            .frame(width: VSpace.buttonHeight, height: VSpace.buttonHeight)
                            .background(VColor.eat, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add usual: \(usual.name)")
                }
            }
        }
        if !quick.recent.isEmpty {
            SheetLabel("Recent")
            ListCard {
                ForEach(Array(quick.recent.enumerated()), id: \.offset) { _, r in
                    FoodRow(name: r.name, detail: [r.portionText, r.lastDay.flatMap(dayWord)].compactMap { $0 }.joined(separator: " · "), kcal: r.kcal) {
                        add([FoodDraft(r)], source: "recent")
                    }
                }
            }
        }
        SheetLabel("Saved meals")
        ListCard {
            ForEach(store.savedMeals, id: \.id) { s in
                FoodRow(name: s.name, detail: s.items.map(\.name).joined(separator: " · "), kcal: s.kcal) {
                    add(s.items.map(FoodDraft.init), source: "saved", sourceRef: s.id)
                }
                .contextMenu {
                    Button { savedForm = SavedFormTarget(meal: s) } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { Task { await store.deleteSavedMeal(s.id) } } label: { Label("Delete", systemImage: "trash") }
                }
            }
            Button { savedForm = SavedFormTarget(meal: nil) } label: {
                ListRow("New saved meal", chevron: false) {
                    Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(VColor.eat)
                }
            }
            .buttonStyle(.plain)
        }
        if quick.usual == nil && quick.recent.isEmpty && store.savedMeals.isEmpty {
            Text("Meals you repeat become one tap after a few days.").vText(.body).padding(.top, VSpace.s5)
        }
    }

    /// Today / Yesterday / weekday within a week / 12 Oct.
    private func dayWord(_ day: String) -> String? {
        let cal = Calendar.current
        guard let date = EatStore.date(day, calendar: cal) else { return nil }
        let days = cal.dateComponents([.day], from: date, to: cal.startOfDay(for: Date())).day ?? 99
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = days < 7 ? "EEEE" : "d MMM"
        return f.string(from: date)
    }
}

extension BarcodeItem {
    /// One item as described, else the owner's words with the confirmed totals, so the next scan finds a single serving.
    init?(describing drafts: [FoodDraft], words: String) {
        guard !drafts.isEmpty else { return nil }
        let name = drafts.count == 1 ? drafts[0].name : words.trimmingCharacters(in: .whitespacesAndNewlines)
        func sum(_ k: KeyPath<FoodDraft, Double?>) -> Double? {
            let v = drafts.compactMap { $0[keyPath: k] }; return v.isEmpty ? nil : v.reduce(0, +)
        }
        let label = drafts.count == 1 ? (drafts[0].portionText ?? "1 SERVING") : "1 SERVING"
        self.init(name: name.isEmpty ? drafts[0].name : name,
                  serving: Serving(label: label.uppercased(), grams: sum(\.grams), kcal: drafts.reduce(0) { $0 + $1.kcal },
                                   proteinG: sum(\.proteinG), carbsG: sum(\.carbsG), fatG: sum(\.fatG)))
    }
}

#if DEBUG
#Preview("Quick add") {
    Color.black.sheet(isPresented: .constant(true)) {
        QuickAddSheet(slot: "lunch", store: EatPreview.store()).environment(Router())
    }
    .onAppear { VFont.register() }
}

#Preview("Quick add · nothing yet") {
    Color.black.sheet(isPresented: .constant(true)) {
        QuickAddSheet(slot: "lunch", store: EatPreview.store(quick: try? APICoding.decoder().decode(FoodQuick.self, from: Data(#"{"slot":"lunch","usual":null,"recent":[],"saved":[]}"#.utf8))))
            .environment(Router())
    }
    .onAppear { VFont.register() }
}
#endif
