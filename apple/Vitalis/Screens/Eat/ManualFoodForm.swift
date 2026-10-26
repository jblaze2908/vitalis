import SwiftUI
import VitalisKit
import VitalisUI

/// What the manual form starts from: the scanned code and any numbers read off the label.
struct ManualFood: Identifiable {
    let code: String
    let values: LabelParser.Values
    let fromPhoto: Bool
    var id: String { code + (fromPhoto ? "-photo" : "-typed") }
}

/// Per-serving numbers for an unknown barcode, prefilled from the label photo when there is one; the owner confirms.
struct ManualFoodForm: View {
    let food: ManualFood
    let slot: String
    let confirm: (BarcodeItem, FoodDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var serving = "1 serving"
    @State private var grams = ""
    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, serving, grams, kcal, protein, carbs, fat }

    init(food: ManualFood, slot: String, confirm: @escaping (BarcodeItem, FoodDraft) -> Void) {
        self.food = food; self.slot = slot; self.confirm = confirm
        func text(_ v: Double?) -> String { v.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" }
        _kcal = State(initialValue: text(food.values.kcal))
        _protein = State(initialValue: text(food.values.proteinG))
        _carbs = State(initialValue: text(food.values.carbsG))
        _fat = State(initialValue: text(food.values.fatG))
    }

    var body: some View {
        SheetChrome {
            VStack(alignment: .leading, spacing: 0) {
                SheetBar(title: "Per serving") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(caption).vText(.secondary, color: food.fromPhoto && food.values.isEmpty ? VColor.watch : nil)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s4).padding(.bottom, VSpace.s3)
                        ListCard {
                            FormFieldRow(title: "Name", text: $name, focus: $focus, field: .name, keyboard: .default)
                            FormFieldRow(title: "Serving", text: $serving, focus: $focus, field: .serving, keyboard: .default)
                            FormFieldRow(title: "Grams", text: $grams, focus: $focus, field: .grams)
                            FormFieldRow(title: "Calories (kcal)", text: $kcal, focus: $focus, field: .kcal)
                            FormFieldRow(title: "Protein (g)", text: $protein, focus: $focus, field: .protein)
                            FormFieldRow(title: "Carbs (g)", text: $carbs, focus: $focus, field: .carbs)
                            FormFieldRow(title: "Fat (g)", text: $fat, focus: $focus, field: .fat)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                PrimaryButton("Add to \(slot.slotTitle)", fill: VColor.eat, ink: VColor.onEat) { save() }
                    .opacity(isValid ? 1 : 0.4).disabled(!isValid)
                    .padding(.top, VSpace.s3).padding(.bottom, VSpace.s6)
            }
            .padding(.horizontal, VSpace.edge)
        }
        .presentationDetents([.custom(BelowPulseDetent.self)])
        .onAppear { focus = .name }
    }

    private var caption: String {
        if !food.fromPhoto { return "Barcode \(BarcodeStore.grouped(food.code)) · we'll remember it" }
        return food.values.isEmpty ? "Couldn't read the label · type the numbers" : "Read from the label · check each number"
    }

    private static func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && Self.number(kcal) != nil }

    private func save() {
        guard let k = Self.number(kcal) else { return }
        let label = serving.trimmingCharacters(in: .whitespaces).isEmpty ? "1 SERVING" : serving.uppercased()
        let s = Serving(label: label, grams: Self.number(grams), kcal: k, proteinG: Self.number(protein), carbsG: Self.number(carbs), fatG: Self.number(fat))
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        confirm(BarcodeItem(name: trimmed, serving: s), FoodDraft(name: trimmed, serving: s))
    }
}

#if DEBUG
#Preview("Label form · from photo") {
    Color.black.sheet(isPresented: .constant(true)) {
        ManualFoodForm(food: ManualFood(code: "8904109450018", values: .init(kcal: 190, proteinG: 10, carbsG: 20, fatG: 7), fromPhoto: true), slot: "snack") { _, _ in }
    }
    .onAppear { VFont.register() }
}
#endif
