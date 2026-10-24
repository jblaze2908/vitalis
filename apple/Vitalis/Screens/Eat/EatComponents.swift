import SwiftUI
import VitalisKit
import VitalisUI

/// Status row + PulseLine pinned above an Eat screen's content (spec 30 spacing: 18 top, line 14 below).
struct EatChrome<Content: View>: View {
    let status: String
    var tint: VTint = .steel
    let pulse: Pulse?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            StatusRow(status, tint: tint).padding(.top, VSpace.statusTop)
            EatPulse(pulse: pulse).padding(.top, 14)
            content
        }
    }
}

/// Eat isn't a timeline: a flat line with only the now-dot (spec 30 → PulseLine, tabs other than Today).
struct EatPulse: View {
    let pulse: Pulse?
    var body: some View { PulseLine(events: [], now: 0.64).frame(height: PulseLine.Style.phone.height) }
}

/// SEARCH / SCAN / DESCRIBE (and USUAL on Eat): an outlined square or tile with an icon and a mono label.
struct FoodTile: View {
    enum Kind: CaseIterable { case usual, search, scan, describe
        var title: String { switch self { case .usual: "Usual"; case .search: "Search"; case .scan: "Scan"; case .describe: "Describe" } }
        var icon: String { switch self { case .usual: "bookmark"; case .search: "magnifyingglass"; case .scan: "barcode.viewfinder"; case .describe: "pencil" } }
    }
    enum Style { case square, tile(height: CGFloat) }
    let kind: Kind
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch style {
            case .square:
                VStack(spacing: 12) {
                    icon.frame(width: 56, height: 52).overlay(ring)
                    MonoLabel(kind.title, size: .small).lineLimit(1).fixedSize()
                }
                .frame(maxWidth: .infinity)
            case .tile(let height):
                VStack(spacing: 10) {
                    icon
                    MonoLabel(kind.title, tint: .bone).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, minHeight: height).overlay(ring)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }

    private var icon: some View { Image(systemName: kind.icon).font(.title3).foregroundStyle(VColor.bone) }
    private var ring: some View {
        RoundedRectangle(cornerRadius: VRadius.button, style: .continuous).inset(by: 0.75).stroke(VColor.future, lineWidth: 1.5)
    }
}

/// 34×34 outlined plus on food rows; logs immediately.
struct RowPlus: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(VColor.bone)
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: VRadius.mini, style: .continuous).inset(by: 0.75).stroke(VColor.future, lineWidth: 1.5))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(label)")
    }
}

/// A food row (54–58 tall): name, mono detail, kcal, plus.
struct FoodRow: View {
    let name: String
    let detail: String?
    let kcal: Double?
    let add: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).vReading(14).textCase(.uppercase).lineLimit(1)
                    if let detail { MonoLabel(detail, size: .small).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Text(FoodFormat.kcal(kcal)).vNumber(19, color: kcal == nil ? VColor.steel : nil)
                RowPlus(label: name, action: add)
            }
            .frame(minHeight: 56)
            Rule()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Add", add)
    }
}

/// PROTEIN / CARBS / FAT in three columns.
struct MacroColumns: View {
    let protein: Double?, carbs: Double?, fat: Double?
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column("Protein", protein); column("Carbs", carbs); column("Fat", fat)
        }
    }
    private func column(_ title: String, _ g: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoLabel(title)
            Text(g == nil ? FoodFormat.dash : "\(FoodFormat.grams(g)) G").vReading(14, tint: g == nil ? .steel : .bone)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Sheet height with its top at 104 pt (spec 30), so the pulse line stays visible above it.
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
