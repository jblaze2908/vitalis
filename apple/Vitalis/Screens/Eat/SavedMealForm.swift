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
                ZStack {
                    HStack {
                        Button { dismiss() } label: { MonoLabel("Cancel", tint: .bone).frame(minHeight: 44) }.buttonStyle(.plain)
                        Spacer()
                    }
                    Text(meal == nil ? "New saved meal" : "Saved meal").vHeadline(22)
                }
                .padding(.top, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(multi ? "\(meal!.items.map(\.name).joined(separator: " · ")) · \(FoodFormat.kcal(meal?.kcal)) kcal"
                             : "Enter it once. It then sits under Saved on Eat and in Add, one tap to log.")
                            .vUI(13, weight: 400, color: VColor.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 16).padding(.bottom, 6)
                        row("Name", $name, .name, keyboard: .default, prompt: "Protein shake")
                        if !multi {
                            row("Portion", $portion, .portion, keyboard: .default, prompt: "1 scoop + 300 ml milk")
                            row("Kcal", $kcal, .kcal)
                            row("Protein g", $protein, .protein)
                            row("Carbs g", $carbs, .carbs)
                            row("Fat g", $fat, .fat)
                        }
                        if meal != nil {
                            Button { confirmDelete = true } label: {
                                Text("Delete saved meal").vUI(15, weight: 600, color: VColor.watch).frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.plain).padding(.top, 18)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                PrimaryButton(addTo.map { "Save and add to \($0.slotTitle)" } ?? "Save") { save() }
                    .opacity(isValid ? 1 : 0.4).disabled(!isValid)
                    .padding(.bottom, 38)
            }
            .padding(.horizontal, VSpace.gutter)
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

    private func row(_ title: String, _ text: Binding<String>, _ field: Field, keyboard: UIKeyboardType = .decimalPad, prompt: String = FoodFormat.dash) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).vReading(13, tint: .steel).textCase(.uppercase)
                Spacer(minLength: 16)
                TextField("", text: text, prompt: Text(prompt).foregroundStyle(VColor.steel))
                    .vReading(14).multilineTextAlignment(.trailing).keyboardType(keyboard)
                    .focused($focus, equals: field).tint(VColor.bone)
            }
            .frame(minHeight: 52)
            Rule()
        }
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
