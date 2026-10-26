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
                    Text(saved ? "Your target" : "Your goal").vText(.title)
                    if saved, let plan = targets?.plan { result(plan) } else { form }
                }
                .padding(.horizontal, VSpace.edge)
                .padding(.top, VSpace.s5)
                .padding(.bottom, VSpace.edge)
            }
        }
        .presentationDetents([.large])
        .task { await load() }
    }

    // MARK: Ask

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your calorie target starts from this and adjusts weekly from what you eat and weigh.")
                .vText(.body).fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s2)
            Text("Goal").vText(.secondary).padding(.top, VSpace.s5)
            HStack(spacing: VSpace.s2) {
                ForEach(Goal.allCases, id: \.self) { g in
                    ChoiceChip(g.title, on: goal == g) { goal = g; error = nil }
                }
            }
            .padding(.top, VSpace.s2)
            if goal != .maintain {
                Text("Target weight (kg)").vText(.secondary).padding(.top, VSpace.s5)
                UnderlinedField(text: $weight, prompt: nowText ?? "80.0").padding(.top, VSpace.s2)
                    .onChange(of: weight) { error = nil }
                if let nowText { Text("Now \(nowText) kg").vText(.secondary).padding(.top, VSpace.s2) }
            }
            if let error { Text(error).vText(.secondary, color: VColor.watch).padding(.top, VSpace.s3) }
            PrimaryButton(saving ? "Saving" : "Set my target") { Task { await save() } }
                .disabled(saving || goal == nil)
                .padding(.top, VSpace.s5)
        }
    }

    private var nowText: String? { targets?.plan?.trendKg.map { String(format: "%.1f", $0) } }

    // MARK: Result

    private func result(_ plan: TargetsResponse.Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Figure(FoodFormat.kcal(plan.kcal.map(Double.init)), unit: "kcal a day", size: 56).padding(.top, VSpace.s4)
            ListCard {
                ForEach(Self.lines(plan), id: \.self) { line in
                    Text(line).vText(.body).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, VSpace.s3)
                }
            }
            .padding(.top, VSpace.s5)
            PrimaryButton("Done") { dismiss() }.padding(.top, VSpace.s5)
            SecondaryButton("Change goal", size: .full) { saved = false }.padding(.top, VSpace.s3)
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
