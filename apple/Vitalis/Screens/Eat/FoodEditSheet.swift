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
                    Figure(Self.grams(g * factor), unit: "g", size: 56)
                } else {
                    Figure(Self.factorText(factor), unit: baseName, size: 56)
                }
                Spacer()
                Figure(FoodFormat.kcal(kcal), unit: "kcal", size: 28, color: VColor.eat)
            }
            HStack(spacing: VSpace.s2) {
                ForEach(fractions, id: \.0) { f, label in
                    let on = abs(factor - f) < 0.001
                    Button { factor = f } label: {
                        Text(f == 1 ? baseName.capitalized : label).vText(.headline, color: on ? VColor.onEat : VColor.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity).padding(.vertical, VSpace.s3)
                            .background(on ? VColor.eat : VColor.surface2, in: RoundedRectangle(cornerRadius: VRadius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.top, VSpace.s5)
            Slider(value: $factor, in: 0.05...maxFactor, step: 0.05).tint(VColor.eat).padding(.top, VSpace.s4)
            HStack {
                Text("0").vText(.secondary)
                Spacer()
                Text(baseGrams.map { "\(Self.grams($0 * maxFactor)) g" } ?? "\(Self.factorText(maxFactor)) \(baseName)").vText(.secondary)
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
    @State private var savedNow = false

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
                    SheetBar(title: "Edit food") { dismiss() }
                    Text(entry.name).vText(.headline).lineLimit(2).padding(.top, VSpace.s4)
                    if let p = entry.portionText ?? entry.grams.map({ "\(AmountControl.grams($0)) g" }) {
                        Text("Logged · \(p)").vText(.secondary).padding(.top, VSpace.s1)
                    }
                    AmountControl(factor: $factor, baseGrams: entry.grams, baseName: entry.grams == nil ? (entry.portionText ?? "portion") : "as logged",
                                  kcal: scaled).padding(.top, VSpace.s4)
                    ReadoutRow([
                        Readout("Protein", macro(entry.proteinG)), Readout("Carbs", macro(entry.carbsG)), Readout("Fat", macro(entry.fatG)),
                    ]).padding(.top, VSpace.s5)
                    SheetLabel("Meal")
                    PillPicker(["breakfast", "lunch", "snack", "dinner"].map { ($0, $0.capitalized) }, selection: $slot)
                    DatePicker(selection: $time, displayedComponents: .hourAndMinute) { Text("Eaten at").vText(.body) }
                        .tint(VColor.eat)
                        .padding(.horizontal, VSpace.s4).frame(minHeight: VSpace.rowMin)
                        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
                        .padding(.top, VSpace.s3)
                    PrimaryButton("Save", value: "\(FoodFormat.kcal(scaled)) kcal", fill: VColor.eat, ink: VColor.onEat) {
                        Task {
                            await store.update(entry, factor: factor, grams: entry.grams.map { ($0 * factor * 10).rounded() / 10 },
                                               portion: portion, slot: slot, eatenAt: EatStore.iso(time, calendar: .current))
                        }
                        dismiss()
                    }
                    .padding(.top, VSpace.s5)
                    let already = savedNow || store.savedMeals.contains { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
                    // This food at the amount shown becomes a saved meal: one tap from Eat next time.
                    SecondaryButton(already ? "In your saved meals" : "Save for one tap", systemImage: already ? "checkmark" : "bookmark",
                                    size: .full, enabled: !already) {
                        let f = { (v: Double?) in v.map { ($0 * factor * 10).rounded() / 10 } }
                        Task { await store.saveMeal(name: entry.name, items: [SavedMeal.Item(name: entry.name, portionText: portion, grams: f(entry.grams),
                                                                                              kcal: scaled.rounded(), proteinG: f(entry.proteinG), carbsG: f(entry.carbsG), fatG: f(entry.fatG))]) }
                        savedNow = true
                    }
                    .padding(.top, VSpace.s3)
                    Button { Task { await store.delete(entry) }; dismiss() } label: {
                        Text("Delete from \(day == today ? "today" : "this day")").vText(.headline, color: VColor.accent).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain).padding(.top, VSpace.s2)
                }
                .padding(.horizontal, VSpace.edge).padding(.bottom, VSpace.s5)
            }
        }
        .presentationDetents([.large])
    }

    private var today: String { EatStore.iso(Date(), calendar: .current).prefix(10).description }

    private func macro(_ g: Double?) -> String { g.map { String(format: "%.1f g", $0 * factor) } ?? FoodFormat.dash }

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
                action("pencil", "Edit", VColor.text, VColor.segmentOn) { offset = 0; onEdit() }
                action("trash", "Delete", VColor.onAccent, VColor.accent) { offset = 0; onDelete() }
            }
            .opacity(offset < 0 ? 1 : 0)
            content
                .background(VColor.surface)
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
            VStack(spacing: VSpace.s1) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                Text(title).vText(.secondary, color: fg)
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
    private static let plotHeight: CGFloat = 112

    /// Hour and running total → a point in a plot of this size.
    private struct Scale {
        /// Room above the highest step for its label.
        static let headroom = VSpace.s5
        let size: CGSize
        let maxK: Double
        func x(_ h: Double) -> CGFloat { size.width * CGFloat(min(max((h - 6) / 18, 0), 1)) }
        func y(_ k: Double) -> CGFloat { size.height - (size.height - Self.headroom) * CGFloat(k / maxK) }
    }

    private var maxK: Double { max(target ?? 0, eaten, 1) * 1.02 }

    /// Each meal's step: where it lands and its label (the first meal's total, then "+" what each added).
    private func steps(_ s: Scale) -> [(point: CGPoint, label: String)] {
        var total = 0.0
        return meals.sorted { (Self.hours($0.time) ?? 0) < (Self.hours($1.time) ?? 0) }.compactMap { m in
            guard let h = Self.hours(m.time) else { return nil }
            total += m.kcal
            return (CGPoint(x: s.x(h), y: s.y(total)), total == m.kcal ? FoodFormat.kcal(m.kcal) : "+\(FoodFormat.kcal(m.kcal))")
        }
    }

    var body: some View {
        VStack(spacing: VSpace.s2) {
            GeometryReader { g in
                let s = Scale(size: g.size, maxK: maxK)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in draw(ctx, s) }
                    ForEach(Array(steps(s).enumerated()), id: \.offset) { _, step in
                        Text(step.label).vText(.secondary, color: VColor.text).fixedSize()
                            .frame(width: 0, height: 0, alignment: .bottomTrailing)
                            .position(x: step.point.x - VSpace.s1, y: step.point.y - VSpace.s2)
                    }
                    if let sx {
                        let h = 6 + 18 * sx
                        let k = meals.filter { (Self.hours($0.time) ?? 99) <= h }.reduce(0) { $0 + $1.kcal }
                        Rectangle().fill(VColor.text.opacity(0.5)).frame(width: 1, height: g.size.height).offset(x: g.size.width * sx)
                        ChartCallout(String(format: "%02d:%02d", Int(h), Int((h - floor(h)) * 60)) + " · \(FoodFormat.kcal(k)) kcal")
                            .position(x: min(max(g.size.width * sx, 70), g.size.width - 70), y: VSpace.s1)
                    }
                }
            }
            .frame(height: Self.plotHeight)
            .scrub($sx)
            axis
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calories through the day")
    }

    private var axis: some View {
        GeometryReader { g in
            let s = Scale(size: g.size, maxK: maxK)
            ForEach([(6.0, "06"), (12.0, "12"), (18.0, "18"), (24.0, "24")], id: \.0) { h, label in
                Text(label).vText(.axis).fixedSize()
                    .frame(width: 0, alignment: h == 6 ? .leading : h == 24 ? .trailing : .center)
                    .position(x: s.x(h), y: g.size.height / 2)
            }
        }
        .frame(height: VSpace.s3)
    }

    private func draw(_ ctx: GraphicsContext, _ s: Scale) {
        let bottom = s.size.height, top = Scale.headroom
        for h in [12.0, 18.0] {
            var p = Path(); p.move(to: CGPoint(x: s.x(h), y: top - 6)); p.addLine(to: CGPoint(x: s.x(h), y: bottom))
            ctx.stroke(p, with: .color(VColor.grid), lineWidth: 1)
        }
        if let target {
            var p = Path(); p.move(to: CGPoint(x: 0, y: s.y(target))); p.addLine(to: CGPoint(x: s.size.width, y: s.y(target)))
            ctx.stroke(p, with: .color(VColor.dashed), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        var step = Path(), area = Path(), last = CGPoint(x: 0, y: bottom)
        step.move(to: last); area.move(to: last)
        let dots = steps(s)
        for d in dots {
            step.addLine(to: CGPoint(x: d.point.x, y: last.y)); area.addLine(to: CGPoint(x: d.point.x, y: last.y))
            last = d.point
            step.addLine(to: last); area.addLine(to: last)
        }
        let total = meals.filter { Self.hours($0.time) != nil }.reduce(0) { $0 + $1.kcal }
        let nowH = isToday ? Self.nowHours() : 24
        let end = CGPoint(x: s.x(nowH), y: last.y)
        step.addLine(to: end); area.addLine(to: end); area.addLine(to: CGPoint(x: end.x, y: bottom)); area.closeSubpath()
        ctx.fill(area, with: .color(VColor.eat.opacity(0.14)))
        ctx.stroke(step, with: .color(VColor.eat), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
        if isToday, let target, total < target {
            let rest = ["breakfast", "lunch", "snack", "dinner"].compactMap { slot -> Double? in
                guard let t = Self.usualTime[slot], t > nowH, !meals.contains(where: { $0.slot == slot }) else { return nil }; return t
            }
            if !rest.isEmpty {
                var ghost = Path(); ghost.move(to: end)
                for (i, t) in rest.enumerated() {
                    let k = total + (target - total) * Double(i + 1) / Double(rest.count)
                    ghost.addLine(to: CGPoint(x: s.x(t), y: s.y(k)))
                    ctx.stroke(Path(ellipseIn: CGRect(x: s.x(t) - 4, y: s.y(k) - 4, width: 8, height: 8)), with: .color(VColor.text3), lineWidth: 1.5)
                }
                ctx.stroke(ghost, with: .color(VColor.text3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
        for d in dots {
            ctx.fill(Path(ellipseIn: CGRect(x: d.point.x - 5, y: d.point.y - 5, width: 10, height: 10)), with: .color(VColor.eat))
        }
        if isToday {
            var now = Path(); now.move(to: CGPoint(x: end.x, y: top - 8)); now.addLine(to: CGPoint(x: end.x, y: bottom))
            ctx.stroke(now, with: .color(VColor.text), lineWidth: 1.2)
        }
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
}
