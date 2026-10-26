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
                    textBox.padding(.top, VSpace.s4)
                    if describe.isStale && describe.canSubmit && !describe.unavailable {
                        SecondaryButton(describe.response == nil ? "Estimate" : "Estimate again") { submit() }.padding(.top, VSpace.s3)
                    }
                    if let line = describe.errorLine { Text(line).vText(.secondary, color: VColor.watch).padding(.top, VSpace.s3) }
                    else if describe.isLoading { Text("Estimating").vText(.secondary).padding(.top, VSpace.s3) }
                    if let r = describe.response { items(r) }
                }
                .padding(.bottom, VSpace.s5)
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
                  prompt: Text("2 rotis with dal makhani and a bowl of curd").foregroundStyle(VColor.text3), axis: .vertical)
            .vText(.body)
            .lineLimit(2...5)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit(submit)
            .tint(VColor.eat)
            .padding(VSpace.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
    }

    @ViewBuilder private func items(_ r: DescribeResponse) -> some View {
        SheetLabel("We found \(r.items.count) item\(r.items.count == 1 ? "" : "s")", note: "Tap to adjust")
        ListCard {
            ForEach(Array(r.items.enumerated()), id: \.offset) { i, item in itemRow(i, item) }
        }
        Text(r.note ?? "Estimated from your words · check portions before adding").vText(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s3)
    }

    private func itemRow(_ i: Int, _ item: DescribeResponse.Item) -> some View {
        let d = describe.draft(i)
        return VStack(alignment: .leading, spacing: VSpace.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).vText(.headline).lineLimit(1)
                Spacer()
                Figure(FoodFormat.kcal(d.kcal), unit: "kcal", size: 20)
            }
            HStack(spacing: VSpace.s3) {
                stepButton("minus", enabled: describe.canStep(i, by: -1)) { describe.step(i, by: -1) }
                Text(describe.option(i)?.label ?? item.portionText ?? FoodFormat.dash).vText(.body).lineLimit(1)
                stepButton("plus", enabled: describe.canStep(i, by: 1)) { describe.step(i, by: 1) }
                Spacer(minLength: VSpace.s2)
                Text("P \(FoodFormat.grams(d.proteinG)) · C \(FoodFormat.grams(d.carbsG)) · F \(FoodFormat.grams(d.fatG))").vText(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .contain)
        }
        .padding(.vertical, VSpace.s3)
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.footnote.weight(.bold)).foregroundStyle(enabled ? VColor.text : VColor.chevron)
                .frame(width: 28, height: 28)
                .background(VColor.surface2, in: RoundedRectangle(cornerRadius: VRadius.control, style: .continuous))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(icon == "plus" ? "More" : "Less")
        .padding(.horizontal, -VSpace.s2)
    }

    private var footer: some View {
        let t = describe.totals
        return VStack(spacing: VSpace.s3) {
            MacroColumns(protein: t.protein, carbs: t.carbs, fat: t.fat)
            PrimaryButton("Add to \(slot.slotTitle)", value: "\(FoodFormat.kcal(t.kcal)) kcal", fill: VColor.eat, ink: VColor.onEat) { add(describe.drafts) }
        }
        .padding(.bottom, VSpace.s6)
    }
}

#if DEBUG
#Preview("Describe") {
    let d = DescribeStore(text: "paneer tikka, 2 rotis and a bowl of dal") { _ in EatPreview.decode(DescribeResponse.self, "describe")! }
    return DescribeView(describe: d, store: EatPreview.store(), slot: "lunch") { _ in }
        .padding(.horizontal, VSpace.edge).vScreen().onAppear { VFont.register() }
}

#Preview("Describe · not set up") {
    let d = DescribeStore(text: "paneer tikka") { _ in throw APIError.unavailable }
    return DescribeView(describe: d, store: EatPreview.store(), slot: "lunch") { _ in }
        .padding(.horizontal, VSpace.edge).vScreen().onAppear { VFont.register() }
}
#endif
