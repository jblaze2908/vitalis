import SwiftUI
import VitalisKit
import VitalisUI

/// How much of a food: a factor of a base amount (a pack, a serving, or what was logged), shown in grams when known.
/// Quick fractions for the common "I ate half the pack", a slider for anything else.
struct AmountControl: View {
    @Binding var factor: Double
    let baseGrams: Double?
    /// "pack", "serving" or the logged portion ("1 bowl").
    let baseName: String
    let kcal: Double
    var maxFactor: Double = 2

    private let fractions: [(Double, String)] = [(0.25, "¼"), (0.5, "½"), (0.75, "¾"), (1, "1")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                if let g = baseGrams {
                    Figure(Self.grams(g * factor), unit: "g", size: 54)
                } else {
                    Figure(Self.factorText(factor), unit: baseName, size: 54)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(FoodFormat.kcal(kcal)).vFigure(30, color: VColor.eat)
                    Text("kcal").vLabel()
                }
            }
            HStack(spacing: 8) {
                ForEach(fractions, id: \.0) { f, label in
                    Button { factor = f } label: {
                        Text(f == 1 ? baseName.capitalized : label).vUI(15, weight: 600, color: abs(factor - f) < 0.001 ? Color(hex: 0x1A0C02) : VColor.bone)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(abs(factor - f) < 0.001 ? VColor.eat : VColor.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 20)
            Slider(value: $factor, in: 0.05...maxFactor, step: 0.05).tint(VColor.eat).padding(.top, 16)
            HStack {
                Text("0").vLabel()
                Spacer()
                Text(baseGrams.map { "\(Self.grams($0 * maxFactor)) g" } ?? "\(Self.factorText(maxFactor)) \(baseName)").vLabel()
            }
        }
        .accessibilityElement(children: .contain)
    }

    static func grams(_ g: Double) -> String { g < 10 ? String(format: "%.1f", g) : String(Int(g.rounded())) }
    static func factorText(_ f: Double) -> String {
        switch f { case 0.25: "¼"; case 0.5: "½"; case 0.75: "¾"; default: f.rounded() == f ? String(Int(f)) : String(format: "%.2g", f) }
    }
}

/// Tap a logged food: change how much, which meal, or when; or delete it.
struct FoodEditSheet: View {
    let entry: FoodDayEntry
    let day: String
    let mealTime: String?
    let store: EatStore
    @Environment(\.dismiss) private var dismiss
    @State private var factor: Double = 1
    @State private var slot: String
    @State private var time: Date

    init(entry: FoodDayEntry, day: String, slot: String, mealTime: String?, store: EatStore) {
        self.entry = entry; self.day = day; self.mealTime = mealTime; self.store = store
        _slot = State(initialValue: entry.slot ?? slot)
        _time = State(initialValue: APIDate.parse(entry.eatenAt) ?? Date())
    }

    private var scaled: Double { entry.kcal * factor }

    var body: some View {
        SheetChrome {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(VColor.muted)
                        Spacer()
                        Text("Edit food").vUI(15, weight: 600)
                        Spacer()
                        Color.clear.frame(width: 50)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    Text(entry.name).vHeadline(28).lineLimit(2).padding(.top, 18)
                    if let p = entry.portionText ?? entry.grams.map({ "\(AmountControl.grams($0)) g" }) {
                        Text("Logged · \(p)").vLabel().padding(.top, 8)
                    }
                    AmountControl(factor: $factor, baseGrams: entry.grams, baseName: entry.grams == nil ? (entry.portionText ?? "portion") : "as logged",
                                  kcal: scaled).padding(.top, 24)
                    ReadoutRow([
                        Readout("Protein", macro(entry.proteinG)), Readout("Carbs", macro(entry.carbsG)), Readout("Fat", macro(entry.fatG)),
                    ]).padding(.top, 20)
                    Text("Meal").vUI(13, weight: 400, color: VColor.muted).padding(.top, 20).padding(.bottom, 8)
                    PillPicker(["breakfast", "lunch", "snack", "dinner"].map { ($0, $0.capitalized) }, selection: $slot)
                    DatePicker("Eaten at", selection: $time, displayedComponents: .hourAndMinute)
                        .font(.system(size: 15)).tint(VColor.eat)
                        .padding(.horizontal, 14).frame(height: 46)
                        .background(VColor.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 10)
                    Button {
                        Task {
                            await store.update(entry, factor: factor, grams: entry.grams.map { ($0 * factor * 10).rounded() / 10 },
                                               portion: portion, slot: slot, eatenAt: EatStore.iso(time, calendar: .current))
                        }
                        dismiss()
                    } label: {
                        Text("Save · \(FoodFormat.kcal(scaled)) kcal").vUI(17, weight: 700, color: Color(hex: 0x1A0C02))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(VColor.eat, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain).padding(.top, 24)
                    Button { Task { await store.delete(entry) }; dismiss() } label: {
                        Text("Delete from \(day == today ? "today" : "this day")").vUI(15, weight: 600, color: VColor.pulse).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain).padding(.top, 8)
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24)
            }
        }
        .presentationDetents([.large])
    }

    private var today: String { EatStore.iso(Date(), calendar: .current).prefix(10).description }

    private func macro(_ g: Double?) -> String { g.map { String(format: "%.1f g", $0 * factor) } ?? "–" }

    /// Keeps the portion words honest once the amount changes ("½ × 1 bowl").
    private var portion: String? {
        guard abs(factor - 1) > 0.001 else { return entry.portionText }
        if let g = entry.grams { return "\(AmountControl.grams(g * factor)) g" }
        return entry.portionText.map { "\(AmountControl.factorText(factor)) × \($0)" }
    }
}

/// Swipe left for Edit and Delete, like Mail; a tap elsewhere closes it.
struct SwipeRow<Content: View>: View {
    let onDelete: () -> Void
    let onEdit: () -> Void
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0
    private let reveal: CGFloat = 148

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                action("pencil", "Edit", VColor.bone, Color(hex: 0x3A3A3A)) { offset = 0; onEdit() }
                action("trash", "Delete", Color(hex: 0x1A0503), VColor.pulse) { offset = 0; onDelete() }
            }
            .opacity(offset < 0 ? 1 : 0)
            content
                .background(VColor.card)
                .offset(x: offset)
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { v in offset = min(0, max(-reveal - 20, v.translation.width + (offset < -1 ? -reveal : 0))) }
                    .onEnded { v in withAnimation(.easeOut(duration: 0.18)) { offset = v.translation.width < -50 ? -reveal : 0 } })
        }
        .clipped()
        .accessibilityAction(named: "Edit", onEdit)
        .accessibilityAction(named: "Delete", onDelete)
    }

    private func action(_ icon: String, _ title: String, _ fg: Color, _ bg: Color, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                Text(title).vUI(13, weight: 600, color: fg)
            }
            .foregroundStyle(fg).frame(width: reveal / 2).frame(maxHeight: .infinity).background(bg)
        }
        .buttonStyle(.plain)
    }
}

/// The day on a 06–24 clock: calories step up at each meal, a now line, and a dashed path to the target through what's left.
struct DayCurve: View {
    let meals: [FoodDay.Meal]
    let target: Double?
    let eaten: Double
    let isToday: Bool
    let nextSlot: String?
    @State private var sx: Double?

    private static let usualTime: [String: Double] = ["breakfast": 8.5, "lunch": 13.5, "snack": 17.5, "dinner": 21]

    var body: some View {
        Canvas { ctx, size in
            let top: CGFloat = 20, bottom = size.height - 20
            let maxK = max(target ?? 0, eaten, 1) * 1.02
            let x = { (h: Double) in size.width * CGFloat(min(max((h - 6) / 18, 0), 1)) }
            let y = { (k: Double) in bottom - (bottom - top) * CGFloat(k / maxK) }
            for h in [12.0, 18.0] {
                var p = Path(); p.move(to: CGPoint(x: x(h), y: top - 6)); p.addLine(to: CGPoint(x: x(h), y: bottom))
                ctx.stroke(p, with: .color(Color(hex: 0x1C1C1C)), lineWidth: 1)
            }
            if let target {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y(target))); p.addLine(to: CGPoint(x: size.width, y: y(target)))
                ctx.stroke(p, with: .color(Color(hex: 0x3A3A3A)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            var step = Path(), area = Path(), total = 0.0, last = CGPoint(x: 0, y: bottom)
            step.move(to: last); area.move(to: last)
            var dots: [(CGPoint, String)] = []
            for m in meals.sorted(by: { (Self.hours($0.time) ?? 0) < (Self.hours($1.time) ?? 0) }) {
                guard let h = Self.hours(m.time) else { continue }
                let px = x(h)
                step.addLine(to: CGPoint(x: px, y: last.y)); area.addLine(to: CGPoint(x: px, y: last.y))
                total += m.kcal
                last = CGPoint(x: px, y: y(total))
                step.addLine(to: last); area.addLine(to: last)
                dots.append((last, total == m.kcal ? FoodFormat.kcal(m.kcal) : "+\(FoodFormat.kcal(m.kcal))"))
            }
            let nowH = isToday ? Self.nowHours() : 24
            let end = CGPoint(x: x(nowH), y: last.y)
            step.addLine(to: end); area.addLine(to: end); area.addLine(to: CGPoint(x: end.x, y: bottom)); area.closeSubpath()
            ctx.fill(area, with: .color(VColor.eat.opacity(0.14)))
            ctx.stroke(step, with: .color(VColor.eat), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
            if isToday, let target, total < target {
                let rest = ["breakfast", "lunch", "snack", "dinner"].compactMap { s -> Double? in
                    guard let t = Self.usualTime[s], t > nowH, !meals.contains(where: { $0.slot == s }) else { return nil }; return t
                }
                if let lastT = rest.last {
                    var ghost = Path(); ghost.move(to: end)
                    for (i, t) in rest.enumerated() {
                        let k = total + (target - total) * Double(i + 1) / Double(rest.count)
                        ghost.addLine(to: CGPoint(x: x(t), y: y(k)))
                        ctx.stroke(Path(ellipseIn: CGRect(x: x(t) - 4, y: y(k) - 4, width: 8, height: 8)), with: .color(Color(hex: 0x6E6E6E)), lineWidth: 1.5)
                    }
                    _ = lastT
                    ctx.stroke(ghost, with: .color(Color(hex: 0x6E6E6E)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
            }
            for (pt, label) in dots {
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)), with: .color(VColor.eat))
                ctx.draw(Text(label).font(VFont.mono(11, weight: 600)).foregroundStyle(VColor.bone), at: CGPoint(x: pt.x - 4, y: pt.y - 12), anchor: .bottomTrailing)
            }
            if isToday {
                var now = Path(); now.move(to: CGPoint(x: end.x, y: top - 8)); now.addLine(to: CGPoint(x: end.x, y: bottom))
                ctx.stroke(now, with: .color(VColor.bone), lineWidth: 1.2)
            }
            for (h, label) in [(6.0, "06"), (12.0, "12"), (18.0, "18"), (24.0, "24")] {
                let anchor: UnitPoint = h == 6 ? .leading : h == 24 ? .trailing : .center
                ctx.draw(Text(label).font(VFont.mono(11, weight: 600)).foregroundStyle(Color(hex: 0x7A7A7A)), at: CGPoint(x: x(h), y: size.height - 6), anchor: anchor)
            }
        }
        .overlay {
            GeometryReader { g in
                if let sx {
                    let h = 6 + 18 * sx
                    let k = meals.filter { (Self.hours($0.time) ?? 99) <= h }.reduce(0) { $0 + $1.kcal }
                    Rectangle().fill(VColor.bone.opacity(0.5)).frame(width: 1, height: g.size.height - 20).offset(x: g.size.width * sx)
                    ChartCallout(String(format: "%02d:%02d", Int(h), Int((h - floor(h)) * 60)) + " · \(FoodFormat.kcal(k)) kcal")
                        .position(x: min(max(g.size.width * sx, 70), g.size.width - 70), y: 6)
                }
            }
        }
        .scrub($sx)
        .accessibilityLabel("Calories through the day")
    }

    static func hours(_ hm: String?) -> Double? {
        guard let hm else { return nil }
        let p = hm.split(separator: ":").compactMap { Double($0) }
        return p.count == 2 ? p[0] + p[1] / 60 : nil
    }
    static func nowHours() -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
    }
}

/// Eat's words, apart from layout.
enum EatCopy {
    static func headline(_ d: FoodDay) -> [String] {
        let left = d.kcalLeft ?? 0
        let first = d.kcalTarget == nil ? "\(FoodFormat.kcal(d.kcalEaten)) kcal eaten." : left >= 0 ? "\(FoodFormat.kcal(left)) kcal left." : "\(FoodFormat.kcal(-left)) kcal over."
        return [first, proteinBehind(d) ? "Protein first." : "On track."]
    }

    /// Behind when protein's share of its target trails calories' share by more than 10 points.
    static func proteinBehind(_ d: FoodDay) -> Bool {
        guard let pt = d.macros.protein.targetG, pt > 0, let kt = d.kcalTarget, kt > 0 else { return false }
        return d.macros.protein.g / pt + 0.1 < d.kcalEaten / kt
    }

    static func macros(_ d: FoodDay) -> [Readout] {
        let p = d.macros.protein
        return [Readout("Protein", "\(Int(p.g.rounded()))" + (p.targetG.map { "/\(Int($0.rounded())) g" } ?? " g"),
                        status: p.targetG == nil ? nil : proteinBehind(d) ? ("Behind", .watch) : ("On track", .good)),
                Readout("Carbs", "\(Int(d.macros.carbs.g.rounded())) g"),
                Readout("Fat", "\(Int(d.macros.fat.g.rounded())) g")]
    }
}
