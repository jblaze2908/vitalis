import SwiftUI
import VitalisKit
import VitalisUI

/// One logged set as the edit sheet shows it; weight and reps stay text so the fields edit like the logger's.
struct SetEdit: Equatable {
    var exerciseID: String
    var exerciseName: String
    var kind: String
    var weight: String
    var reps: String
    var note: String

    var weightKg: Double? { LiveSessionStore.number(weight) }
    var repsValue: Int? { Int(reps.trimmingCharacters(in: .whitespaces)) }
    var isValid: Bool { (repsValue ?? 0) > 0 && (weight.trimmingCharacters(in: .whitespaces).isEmpty || (weightKg.map { $0 >= 0 && $0 <= 1000 } ?? false)) }
}

/// Edit or delete one set, live or in a finished workout: exercise, weight, reps, type and note.
struct SetEditSheet: View {
    let title: String
    let initial: SetEdit
    let save: (SetEdit) -> Void
    let delete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var edit: SetEdit
    @State private var picking = false

    init(title: String, initial: SetEdit, save: @escaping (SetEdit) -> Void, delete: @escaping () -> Void) {
        self.title = title; self.initial = initial; self.save = save; self.delete = delete
        _edit = State(initialValue: initial)
    }

    static let kinds = [("normal", "Normal"), ("warmup", "Warm-up"), ("drop", "Drop"), ("failure", "Failure")]

    var body: some View {
        SheetChrome {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SheetBar(title: title) { dismiss() }
                    SheetLabel("Exercise")
                    Button { picking = true } label: {
                        ListRow(edit.exerciseName, value: edit.exerciseID == initial.exerciseID ? "Change" : "Changed") { EmptyView() }
                            .padding(.horizontal, VSpace.s4)
                            .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    SheetLabel("Weight and reps")
                    HStack(spacing: VSpace.s3) {
                        field("kg", text: $edit.weight, keyboard: .decimalPad)
                        field("reps", text: $edit.reps, keyboard: .numberPad)
                    }
                    SheetLabel("Type")
                    PillPicker(Self.kinds, selection: $edit.kind)
                    SheetLabel("Note")
                    TextField("", text: $edit.note, prompt: Text("Seat 4, felt easy…").foregroundStyle(VColor.text3), axis: .vertical)
                        .vText(.body).lineLimit(1...3)
                        .padding(.horizontal, VSpace.s4).padding(.vertical, VSpace.s3).frame(minHeight: VSpace.rowMin)
                        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
                    if edit.isValid {
                        PrimaryButton("Save", value: TrainFormat.set(edit.weightKg, edit.repsValue)) { save(edit); dismiss() }
                            .padding(.top, VSpace.s5)
                    } else {
                        Text("A set needs at least one rep, and weight between 0 and 1000 kg.").vText(.secondary, color: VColor.watch).padding(.top, VSpace.s5)
                    }
                    Button { delete(); dismiss() } label: {
                        Text("Delete set").vText(.headline, color: VColor.accent).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain).padding(.top, VSpace.s2)
                }
                .padding(.horizontal, VSpace.edge).padding(.bottom, VSpace.s5)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.large])
        .sheet(isPresented: $picking) {
            AddExerciseSheet(api: Services.shared.api, title: "Change exercise") { info in
                edit.exerciseID = info.id; edit.exerciseName = info.name
            }
        }
    }

    private func field(_ unit: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: VSpace.s2) {
            TextField("", text: text, prompt: Text(TrainFormat.dash).foregroundStyle(VColor.text3))
                .keyboardType(keyboard).vText(.numM)
            Text(unit).vText(.secondary)
        }
        .padding(.horizontal, VSpace.s4).frame(maxWidth: .infinity, minHeight: VSpace.buttonHeight)
        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
        .accessibilityElement(children: .combine).accessibilityLabel(unit == "kg" ? "Kilograms" : "Reps")
    }
}

#if DEBUG
#Preview("Edit set") {
    Color.clear.sheet(isPresented: .constant(true)) {
        SetEditSheet(title: "Set 2", initial: SetEdit(exerciseID: "smith-machine-incline-bench-press", exerciseName: "Smith Machine Incline Bench Press",
                                                      kind: "normal", weight: "80", reps: "6", note: ""), save: { _ in }, delete: {})
    }
    .onAppear { VFont.register() }
}
#endif
