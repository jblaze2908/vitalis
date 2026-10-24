import SwiftUI
import VitalisKit
import VitalisUI

/// Frame 15: the server turns words into items; steppers move between the server's portion options.
struct DescribeView: View {
    let describe: DescribeStore
    let store: EatStore
    let slot: String
    let add: ([FoodDraft]) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    textBox.padding(.top, 16)
                    if describe.isStale && describe.canSubmit && !describe.unavailable {
                        SecondaryButton(describe.response == nil ? "Estimate" : "Estimate again") { submit() }.padding(.top, 12)
                    }
                    if let line = describe.errorLine { MonoLabel(line, tint: .watch).padding(.top, 14) }
                    else if describe.isLoading { MonoLabel("Estimating").padding(.top, 14) }
                    if let r = describe.response { items(r) }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            if describe.response != nil { footer }
        }
        .onAppear { if describe.text.isEmpty { focused = true } else if describe.response == nil { submit() } }
    }

    private func submit() {
        focused = false
        Task {
            await describe.submit(slot: slot)
            if describe.unavailable { store.describeAvailable = false }
        }
    }

    private var textBox: some View {
        TextField("", text: Binding(get: { describe.text }, set: { describe.text = $0 }),
                  prompt: Text("2 rotis with dal makhani and a bowl of curd").foregroundStyle(VColor.steel), axis: .vertical)
            .vReading(14)
            .lineLimit(2...5)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit(submit)
            .tint(VColor.bone)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(minHeight: 70, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: VRadius.button, style: .continuous).inset(by: 0.75).stroke(VColor.future, lineWidth: 1.5))
    }

    @ViewBuilder private func items(_ r: DescribeResponse) -> some View {
        HStack {
            MonoLabel("We found \(r.items.count) item\(r.items.count == 1 ? "" : "s")")
            Spacer()
            MonoLabel("Tap to adjust", size: .small)
        }
        .padding(.top, 22)
        ForEach(Array(r.items.enumerated()), id: \.offset) { i, item in itemRow(i, item) }
        MonoLabel(r.note ?? "ESTIMATED FROM YOUR WORDS · CHECK PORTIONS BEFORE ADDING", size: .small)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 16)
    }

    private func itemRow(_ i: Int, _ item: DescribeResponse.Item) -> some View {
        let d = describe.draft(i)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).vHeadline(21).lineLimit(1)
                Spacer()
                Text(FoodFormat.kcal(d.kcal)).vNumber(20)
            }
            HStack(spacing: 12) {
                stepButton("minus", enabled: describe.canStep(i, by: -1)) { describe.step(i, by: -1) }
                Text(describe.option(i)?.label ?? item.portionText ?? FoodFormat.dash).vReading(14).textCase(.uppercase).lineLimit(1)
                stepButton("plus", enabled: describe.canStep(i, by: 1)) { describe.step(i, by: 1) }
                Spacer(minLength: 8)
                MonoLabel("P \(FoodFormat.grams(d.proteinG)) · C \(FoodFormat.grams(d.carbsG)) · F \(FoodFormat.grams(d.fatG))").lineLimit(1)
            }
            .accessibilityElement(children: .contain)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rule() }
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.footnote.weight(.bold)).foregroundStyle(enabled ? VColor.bone : VColor.disabled)
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: VRadius.field, style: .continuous).inset(by: 0.75).stroke(VColor.future, lineWidth: 1.5))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(icon == "plus" ? "More" : "Less")
        .padding(.horizontal, -8)
    }

    private var footer: some View {
        let t = describe.totals
        return VStack(spacing: 14) {
            Rule()
            MacroColumns(protein: t.protein, carbs: t.carbs, fat: t.fat)
            PrimaryButton("Add to \(slot.slotTitle) · \(FoodFormat.kcal(t.kcal)) kcal") { add(describe.drafts) }
        }
        .padding(.bottom, 38)
    }
}

#if DEBUG
#Preview("Describe") {
    let d = DescribeStore(text: "paneer tikka, 2 rotis and a bowl of dal") { _ in EatPreview.decode(DescribeResponse.self, "describe")! }
    return DescribeView(describe: d, store: EatPreview.store(), slot: "lunch") { _ in }
        .padding(.horizontal, VSpace.gutter).vScreen().onAppear { VFont.register() }
}

#Preview("Describe · not set up") {
    let d = DescribeStore(text: "paneer tikka") { _ in throw APIError.unavailable }
    return DescribeView(describe: d, store: EatPreview.store(), slot: "lunch") { _ in }
        .padding(.horizontal, VSpace.gutter).vScreen().onAppear { VFont.register() }
}
#endif
