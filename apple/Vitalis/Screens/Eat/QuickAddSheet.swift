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
            .padding(.horizontal, VSpace.gutter)
        }
        .presentationDetents([.custom(BelowPulseDetent.self)])
        .task {
            store.requestedMode = nil
            await store.loadQuick(slot: slot)
        }
        .fullScreenCover(isPresented: $scanning) {
            ScanScreen(store: store, slot: currentSlot, onDescribe: { code in scanning = false; go(.describe(text: "", barcode: code)) },
                       onDone: { scanning = false; router.tab = .eat; router.sheet = nil })
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
        router.tab = .eat
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
                        HStack(spacing: 6) {
                            if mode != .home { Image(systemName: "chevron.left").font(.body.weight(.semibold)).foregroundStyle(VColor.bone) }
                            MonoLabel(mode == .home ? "Cancel" : "Back", tint: .bone)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                slotMenu
            }
            .padding(.top, 14)
            if mode != .home { segments.padding(.top, 10) }
        }
    }

    private var slotMenu: some View {
        Menu {
            ForEach(["breakfast", "lunch", "snack", "dinner"], id: \.self) { s in
                Button(s.capitalized) { chosenSlot = s; Task { await store.loadQuick(slot: s) } }
            }
        } label: {
            HStack(spacing: 8) {
                Text("Add to \(currentSlot.slotTitle)").vHeadline(22)
                if mode == .home { Image(systemName: "chevron.down").font(.callout.weight(.semibold)).foregroundStyle(VColor.steel) }
            }
        }
        .disabled(mode != .home)
        .accessibilityLabel("Add to \(currentSlot.slotTitle), change meal")
    }

    private var segments: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                segment("Search", active: { if case .search = mode { true } else { false } }()) { go(.search(text: "")) }
                segment("Scan", active: false) { scanning = true }
                if store.describeAvailable || { if case .describe = mode { true } else { false } }() {
                    segment("Describe", active: { if case .describe = mode { true } else { false } }()) { go(.describe(text: search.query, barcode: nil)) }
                }
            }
            Rule()
        }
    }

    private func segment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                MonoLabel(title, tint: active ? .bone : .steel)
                GeometryReader { g in
                    Rectangle().fill(active ? VColor.bone : .clear).frame(width: g.size.width * 0.4, height: 2).frame(maxWidth: .infinity)
                }
                .frame(height: 2)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottom).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: Home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    FoodTile(kind: .search, style: .tile(height: 80)) { go(.search(text: "")) }
                    FoodTile(kind: .scan, style: .tile(height: 80)) { scanning = true }
                    if store.describeAvailable { FoodTile(kind: .describe, style: .tile(height: 80)) { go(.describe(text: "", barcode: nil)) } }
                }
                .padding(.top, 20)
                if let quick = store.quick.value { lists(quick) }
                else if store.quick.error != nil { MonoLabel((store.quick.error as? APIError)?.statusLine ?? "COULDN'T UPDATE", tint: .watch).padding(.top, 24) }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func lists(_ quick: FoodQuick) -> some View {
        if let usual = quick.usual {
            MonoLabel("Your usual at \(currentSlot.slotTitle)").padding(.top, 26)
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HeadlineLines(HeadlineLines.split(usual.name, maxChars: 20), size: 26)
                    MonoLabel([FoodFormat.kcal(usual.kcal) + " KCAL", usual.proteinG.map { "\(FoodFormat.grams($0)) G PROTEIN" }].compactMap { $0 }.joined(separator: " · "))
                }
                Spacer(minLength: 8)
                Button { add(usual.items.map(FoodDraft.init), source: "usual") } label: {
                    Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(VColor.ground)
                        .frame(width: 52, height: 52)
                        .background(VColor.pulse, in: RoundedRectangle(cornerRadius: VRadius.button, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add usual: \(usual.name)")
            }
            .padding(.top, 12).padding(.bottom, 18)
            Rule()
        }
        if !quick.recent.isEmpty {
            MonoLabel("Recent").padding(.top, 24).padding(.bottom, 4)
            ForEach(Array(quick.recent.enumerated()), id: \.offset) { _, r in
                FoodRow(name: r.name, detail: [r.portionText, r.lastDay.flatMap(dayWord)].compactMap { $0 }.joined(separator: " · "), kcal: r.kcal) {
                    add([FoodDraft(r)], source: "recent")
                }
            }
        }
        if !quick.saved.isEmpty {
            MonoLabel("Saved meals").padding(.top, 24).padding(.bottom, 4)
            ForEach(quick.saved, id: \.id) { s in
                FoodRow(name: s.name, detail: s.items.map(\.name).joined(separator: " · "), kcal: s.kcal) {
                    add(s.items.map(FoodDraft.init), source: "saved", sourceRef: s.id)
                }
            }
        }
        if quick.usual == nil && quick.recent.isEmpty && quick.saved.isEmpty {
            Text("Meals you repeat become one tap after a few days.").vBody().padding(.top, 26)
        }
    }

    /// TODAY / YESTERDAY / weekday within a week / 12 OCT.
    private func dayWord(_ day: String) -> String? {
        let cal = Calendar.current
        guard let date = EatStore.date(day, calendar: cal) else { return nil }
        let days = cal.dateComponents([.day], from: date, to: cal.startOfDay(for: Date())).day ?? 99
        if days == 0 { return "TODAY" }
        if days == 1 { return "YESTERDAY" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = days < 7 ? "EEEE" : "d MMM"
        return f.string(from: date).uppercased()
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
