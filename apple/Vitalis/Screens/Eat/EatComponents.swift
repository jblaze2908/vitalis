import SwiftUI
import VitalisKit
import VitalisUI

/// Search / Scan / Describe (and Usual on Eat): a surface tile with an icon over its name.
struct FoodTile: View {
    enum Kind: CaseIterable { case usual, search, scan, describe
        var title: String { switch self { case .usual: "Usual"; case .search: "Search"; case .scan: "Scan"; case .describe: "Describe" } }
        var icon: String { switch self { case .usual: "bookmark"; case .search: "magnifyingglass"; case .scan: "barcode.viewfinder"; case .describe: "pencil" } }
    }
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: VSpace.s2) {
                Image(systemName: kind.icon).font(.title3).foregroundStyle(VColor.eat)
                Text(kind.title).vText(.headline).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, VSpace.s4)
            .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }
}

/// The plus on a food row; logs immediately.
struct RowPlus: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(VColor.eat)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(label)")
    }
}

/// A food in a Quick add or search list: name, detail, kcal, plus. Sits in a `ListCard`.
struct FoodRow: View {
    let name: String
    let detail: String?
    let kcal: Double?
    let add: () -> Void
    var body: some View {
        ListRow(name, subtitle: detail?.isEmpty == false ? detail : nil, chevron: false) {
            Text("\(FoodFormat.kcal(kcal)) kcal").vText(.secondary).lineLimit(1).fixedSize()
            RowPlus(label: name, action: add).padding(.vertical, -VSpace.s3)
        }
        .accessibilityAction(named: "Add", add)
    }
}

/// Protein / Carbs / Fat as readouts.
struct MacroColumns: View {
    let protein: Double?, carbs: Double?, fat: Double?
    var body: some View {
        ReadoutRow([Readout("Protein", grams(protein)), Readout("Carbs", grams(carbs)), Readout("Fat", grams(fat))])
    }
    private func grams(_ g: Double?) -> String { g == nil ? FoodFormat.dash : "\(FoodFormat.grams(g)) g" }
}

/// A section label inside a sheet whose content already sits on the gutter (`SectionLabel` brings its own).
struct SheetLabel: View {
    let text: String
    var note: String? = nil
    init(_ text: String, note: String? = nil) { self.text = text; self.note = note }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).vText(.label)
            Spacer(minLength: VSpace.s2)
            if let note { Text(note).vText(.label) }
        }
        .padding(.top, VSpace.s5).padding(.bottom, VSpace.s2)
    }
}

/// Sheet top bar: Cancel or Back on the left, the title centred.
struct SheetBar: View {
    let title: String
    var leading = "Cancel"
    var back = false
    let action: () -> Void
    var body: some View {
        ZStack {
            Text(title).vText(.title).lineLimit(1).padding(.horizontal, VSpace.s7)
            HStack {
                Button(action: action) {
                    HStack(spacing: VSpace.s1) {
                        if back { Image(systemName: "chevron.left").font(.body.weight(.semibold)) }
                        Text(leading).vText(.headline, color: VColor.text2)
                    }
                    .foregroundStyle(VColor.text2).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.top, VSpace.s3)
    }
}

/// A form field in a `ListCard`: label left, value typed on the right.
struct FormFieldRow<Field: Hashable>: View {
    let title: String
    @Binding var text: String
    let focus: FocusState<Field?>.Binding
    let field: Field
    var prompt: String = FoodFormat.dash
    var keyboard: UIKeyboardType = .decimalPad
    var body: some View {
        HStack {
            Text(title).vText(.secondary)
            Spacer(minLength: VSpace.s4)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(VColor.text3))
                .vText(.body).multilineTextAlignment(.trailing).keyboardType(keyboard).tint(VColor.eat)
                .focused(focus, equals: field)
        }
        .frame(minHeight: VSpace.rowMin)
    }
}

/// Sheet height with its top at 104 pt (spec 30), so the tab's header stays visible above it.
struct BelowPulseDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? { context.maxDetentValue - 47 }
}

extension String {
    /// "lunch" → "Lunch"; snack reads as "snacks" in copy ("Add to snacks").
    var slotTitle: String { EatStore.slotName(self) }
}

#if DEBUG
/// Fixture-backed stores for previews: DemoData JSON, no network, no HealthKit.
@MainActor
enum EatPreview {
    static func decode<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? APICoding.decoder().decode(T.self, from: data)
    }

    final class NoQueue: FoodWriteQueue {
        func send(_ request: APIRequest) async -> UUID? { UUID() }
        func drop(_ id: UUID) async -> Bool { true }
        func pendingItems() async -> [Outbox.Item] { [] }
    }

    static func store(day: FoodDay? = decode(FoodDay.self, "food-day"), quick: FoodQuick? = decode(FoodQuick.self, "food-quick")) -> EatStore {
        let store = EatStore(api: { nil }, queue: NoQueue(), health: FakeHealthWriter(), recheckAfter: nil)
        if let day { store.day.set(day) }
        if let quick { store.quick.set(quick) }
        return store
    }
}
#endif
