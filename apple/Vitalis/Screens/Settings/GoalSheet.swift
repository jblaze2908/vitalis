import SwiftUI
import VitalisKit
import VitalisUI

/// Goal + target weight → calorie target (11 §8.2). Saves directly so the resulting number and its reasons show at once.
struct GoalSheet: View {
    enum Goal: String, CaseIterable { case lose, maintain, gain
        var title: String { rawValue.capitalized }
    }

    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var targets: TargetsResponse?
    @State private var goal: Goal?
    @State private var weight = ""
    @State private var error: String?
    @State private var saving = false
    @State private var saved = false

    init(targets: TargetsResponse? = nil) { _targets = State(initialValue: targets) }

    var body: some View {
        SheetChrome {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HeadlineLines([saved ? "Your target" : "Your goal"], size: 30)
                    if saved, let plan = targets?.plan { result(plan) } else { form }
                }
                .padding(.horizontal, VSpace.gutter)
                .padding(.top, 20)
                .padding(.bottom, VSpace.gutter)
            }
        }
        .presentationDetents([.large])
        .task { await load() }
    }

    // MARK: Ask

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your calorie target starts from this and adjusts weekly from what you eat and weigh.")
                .vBody().fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            MonoLabel("Goal").padding(.top, 24)
            HStack(spacing: 8) {
                ForEach(Goal.allCases, id: \.self) { g in
                    SecondaryButton(g.title, size: .compact) { goal = g; error = nil }
                        .overlay(goal == g ? RoundedRectangle(cornerRadius: VRadius.button).stroke(VColor.bone, lineWidth: 1.5) : nil)
                        .accessibilityAddTraits(goal == g ? .isSelected : [])
                }
            }
            .padding(.top, 10)
            if goal != .maintain {
                MonoLabel("Target weight · KG").padding(.top, 24)
                TextField("", text: $weight, prompt: Text(nowText ?? "80.0").foregroundStyle(VColor.disabled))
                    .vNumber(40).keyboardType(.decimalPad).padding(.top, 8)
                    .onChange(of: weight) { error = nil }
                Rule()
                if let nowText { MonoLabel("Now \(nowText) KG").padding(.top, 8) }
            }
            if let error { MonoLabel(error, tint: .watch).padding(.top, 12) }
            PrimaryButton(saving ? "Saving" : "Set my target") { Task { await save() } }
                .disabled(saving || goal == nil)
                .padding(.top, 28)
        }
    }

    private var nowText: String? { targets?.plan?.trendKg.map { String(format: "%.1f", $0) } }

    // MARK: Result

    private func result(_ plan: TargetsResponse.Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(FoodFormat.kcal(plan.kcal.map(Double.init))).vNumber(72)
                MonoLabel("KCAL A DAY")
            }
            .padding(.top, 16)
            VStack(spacing: 0) {
                ForEach(Self.lines(plan), id: \.self) { line in
                    Rule()
                    Text(line).vBody(15, color: VColor.bone).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
                }
                Rule()
            }
            .padding(.top, 20)
            PrimaryButton("Done") { dismiss() }.padding(.top, 28)
            SecondaryButton("Change goal", size: .full) { saved = false }.padding(.top, 12)
        }
    }

    /// Why the number is what it is, one reason per line.
    static func lines(_ p: TargetsResponse.Plan) -> [String] {
        var out: [String] = []
        let m = FoodFormat.kcal(p.maintenanceKcal.map(Double.init))
        switch p.basis {
        case "adaptive": out.append("Maintenance \(m) kcal, from the food and weight you've logged")
        case "watch": out.append("Maintenance \(m) kcal, from your Watch's resting + active energy over 28 days")
        default: out.append("Maintenance \(m) kcal, estimated at 30 kcal per kg until your Watch has 14 days")
        }
        let perDay = FoodFormat.kcal(abs(p.rateKgWeek) * 7700 / 7)
        let rate = String(format: "%.2f", abs(p.rateKgWeek))
        if p.reached { out.append("You're at your target weight, so it holds steady") }
        else if p.rateKgWeek < 0 { out.append("−\(perDay) kcal a day to lose \(rate) kg a week") }
        else if p.rateKgWeek > 0 { out.append("+\(perDay) kcal a day to gain \(rate) kg a week") }
        else { out.append("No deficit or surplus: maintain") }
        if let kg = p.goalWeightKg, p.goal != "maintain", let now = p.trendKg, !p.reached, p.rateKgWeek != 0 {
            let weeks = Int((abs(kg - now) / abs(p.rateKgWeek)).rounded(.up))
            out.append("\(String(format: "%.1f", now)) → \(String(format: "%.1f", kg)) kg in about \(weeks) weeks")
        }
        if p.basis != "adaptive" { out.append("Adjusts weekly once you've logged 14 days of food and 8 weigh-ins") }
        return out
    }

    // MARK: Data

    private func load() async {
        guard let api = services.api else { return }
        if targets == nil { targets = await api.cached(TargetsResponse.self, path: "v2/targets")?.value }
        if let fresh = try? await api.targets().value { targets = fresh }
        guard goal == nil, let t = targets else { return }
        goal = (t.values.goal ?? t.plan?.goal).flatMap(Goal.init(rawValue:))
        if let kg = t.values.goalWeightKg { weight = String(format: "%.1f", kg) }
    }

    private func save() async {
        guard let goal, let api = services.api else { return }
        var patch = TargetsPatch()
        patch.goal = .set(goal.rawValue)
        if goal != .maintain {
            guard let kg = Double(weight.replacingOccurrences(of: ",", with: ".")), (30...300).contains(kg) else {
                error = "Enter a target weight between 30 and 300 kg"; return
            }
            if let now = targets?.plan?.trendKg, (goal == .lose && kg >= now) || (goal == .gain && kg <= now) {
                error = "To \(goal.rawValue), the target has to be \(goal == .lose ? "below" : "above") \(String(format: "%.1f", now)) kg"; return
            }
            patch.goalWeightKg = .set(kg)
        }
        saving = true; defer { saving = false }
        do {
            targets = try await api.putTargets(patch)
            services.noteWrite()
            saved = true
        } catch { self.error = (error as? APIError)?.statusLine ?? error.localizedDescription }
    }
}
