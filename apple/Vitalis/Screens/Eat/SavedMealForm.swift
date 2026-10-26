import SwiftUI
import VitalisKit
import VitalisUI

/// Type a meal's numbers once (a daily protein shake), then add it in one tap. Editing a saved meal reuses its id.
struct SavedMealForm: View {
    let store: EatStore
    /// nil = a new saved meal; otherwise the one being edited.
    let meal: SavedMealInfo?
    /// Logs it straight away after saving, into this meal of the day.
    let addTo: String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var portion: String
    @State private var kcal: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String
    @State private var confirmDelete = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, portion, kcal, protein, carbs, fat }

    /// Prefill from a saved meal, or from a logged food ("Save for one tap" on an entry).
    init(store: EatStore, meal: SavedMealInfo? = nil, from item: FoodItem? = nil, addTo: String? = nil) {
        self.store = store; self.meal = meal; self.addTo = addTo
        let one = meal?.items.count == 1 ? meal?.items.first : item
        func text(_ v: Double?) -> String { v.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" }
        _name = State(initialValue: meal?.name ?? item?.name ?? "")
        _portion = State(initialValue: one?.portionText ?? "")
        _kcal = State(initialValue: text(one?.kcal ?? meal?.kcal))
        _protein = State(initialValue: text(one?.proteinG))
        _carbs = State(initialValue: text(one?.carbsG))
        _fat = State(initialValue: text(one?.fatG))
    }

    /// A saved meal of several foods keeps them; only its name changes here.
    private var multi: Bool { (meal?.items.count ?? 1) > 1 }

    var body: some View {
        SheetChrome {
            VStack(alignment: .leading, spacing: 0) {
                SheetBar(title: meal == nil ? "New saved meal" : "Saved meal") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(multi ? "\(meal!.items.map(\.name).joined(separator: " · ")) · \(FoodFormat.kcal(meal?.kcal)) kcal"
                             : "Enter it once. It then sits under Saved on Eat and in Add, one tap to log.")
                            .vText(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s4).padding(.bottom, VSpace.s3)
                        ListCard {
                            FormFieldRow(title: "Name", text: $name, focus: $focus, field: .name, prompt: "Protein shake", keyboard: .default)
                            if !multi {
                                FormFieldRow(title: "Portion", text: $portion, focus: $focus, field: .portion, prompt: "1 scoop + 300 ml milk", keyboard: .default)
                                FormFieldRow(title: "Calories (kcal)", text: $kcal, focus: $focus, field: .kcal)
                                FormFieldRow(title: "Protein (g)", text: $protein, focus: $focus, field: .protein)
                                FormFieldRow(title: "Carbs (g)", text: $carbs, focus: $focus, field: .carbs)
                                FormFieldRow(title: "Fat (g)", text: $fat, focus: $focus, field: .fat)
                            }
                        }
                        if meal != nil {
                            Button { confirmDelete = true } label: {
                                Text("Delete saved meal").vText(.headline, color: VColor.watch).frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain).padding(.top, VSpace.s4)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                PrimaryButton(addTo.map { "Save and add to \($0.slotTitle)" } ?? "Save", fill: VColor.eat, ink: VColor.onEat) { save() }
                    .opacity(isValid ? 1 : 0.4).disabled(!isValid)
                    .padding(.top, VSpace.s3).padding(.bottom, VSpace.s6)
            }
            .padding(.horizontal, VSpace.edge)
        }
        .presentationDetents([.custom(BelowPulseDetent.self)])
        .onAppear { if meal == nil { focus = .name } }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = meal?.id { Task { await store.deleteSavedMeal(id) } }
                dismiss()
            }
        } message: { Text("Food you already logged with it stays logged.") }
    }

    private static func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { !trimmedName.isEmpty && (multi || (Self.number(kcal) ?? -1) >= 0) }

    private func save() {
        let items: [SavedMeal.Item]
        if multi, let meal {
            items = meal.items.map { SavedMeal.Item(name: $0.name, portionText: $0.portionText, grams: $0.grams, kcal: $0.kcal,
                                                    proteinG: $0.proteinG, carbsG: $0.carbsG, fatG: $0.fatG) }
        } else {
            guard let k = Self.number(kcal) else { return }
            let p = portion.trimmingCharacters(in: .whitespaces)
            items = [SavedMeal.Item(name: trimmedName, portionText: p.isEmpty ? nil : p, kcal: k,
                                    proteinG: Self.number(protein), carbsG: Self.number(carbs), fatG: Self.number(fat))]
        }
        let id = meal?.id ?? UUID().uuidString.lowercased(), slot = addTo
        Task {
            await store.saveMeal(id: id, name: trimmedName, items: items)
            if let slot, let saved = store.savedMeals.first(where: { $0.id == id }) { await store.logSaved(saved, slot: slot) }
        }
        dismiss()
    }
}

#if DEBUG
#Preview("New saved meal") {
    Color.black.sheet(isPresented: .constant(true)) { SavedMealForm(store: EatPreview.store(), addTo: "breakfast") }
        .onAppear { VFont.register() }
}
#endif
