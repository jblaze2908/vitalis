import SwiftUI
import VitalisKit
import VitalisUI

/// Frame 14: debounced search; the server proxies Open Food Facts and puts the owner's own items first.
struct FoodSearchView: View {
    let search: FoodSearchStore
    let store: EatStore
    let add: (_ drafts: [FoodDraft], _ source: String, _ sourceRef: String?, _ estimate: Bool?) -> Void
    let describe: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                field.padding(.top, 16)
                summary.padding(.top, 22).padding(.bottom, 2)
                ForEach(search.results, id: \.key) { r in
                    FoodRow(name: r.name, detail: r.label ?? r.serving.label, kcal: r.serving.kcal) {
                        add([FoodDraft(name: r.name, serving: r.serving)], r.source, r.sourceRef, r.estimate)
                    }
                }
                if store.describeAvailable { describeLink.padding(.top, 36) }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.body.weight(.medium)).foregroundStyle(VColor.steel)
            TextField("", text: Binding(get: { search.query }, set: { search.update(query: $0) }),
                      prompt: Text("Search food").foregroundStyle(VColor.steel))
                .vReading(14)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .tint(VColor.bone)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .overlay(RoundedRectangle(cornerRadius: VRadius.button, style: .continuous).inset(by: 0.75).stroke(VColor.future, lineWidth: 1.5))
    }

    @ViewBuilder private var summary: some View {
        if let line = search.errorLine { MonoLabel(line, tint: .watch) }
        else if let busy = search.remoteLine { MonoLabel(busy, tint: .watch) }
        else if search.response != nil { MonoLabel("\(search.results.count) result\(search.results.count == 1 ? "" : "s")") }
        else if search.isSearching { MonoLabel("Searching") }
        else if FoodSearchStore.normalized(search.query).count < FoodSearchStore.minimumLength, !search.query.isEmpty {
            MonoLabel("Type \(FoodSearchStore.minimumLength) letters or more")
        }
    }

    private var describeLink: some View {
        VStack(spacing: 0) {
            Rule()
            Button { describe(search.query) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        MonoLabel("Not quite it?")
                        Text("Describe the meal").vHeadline(24)
                        MonoLabel("We fill in the macros")
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(VColor.bone)
                }
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rule()
        }
    }
}

#if DEBUG
#Preview("Search") {
    let search = FoodSearchStore(debounce: .zero) { _ in EatPreview.decode(FoodSearchResponse.self, "food-search")! }
    search.update(query: "paneer")
    return FoodSearchView(search: search, store: EatPreview.store(), add: { _, _, _, _ in }, describe: { _ in })
        .padding(.horizontal, VSpace.gutter).vScreen().onAppear { VFont.register() }
}

#Preview("Search · online busy") {
    let search = FoodSearchStore(debounce: .zero) { _ in EatPreview.decode(FoodSearchResponse.self, "food-search")!.busyCopy }
    search.update(query: "paneer")
    return FoodSearchView(search: search, store: EatPreview.store(), add: { _, _, _, _ in }, describe: { _ in })
        .padding(.horizontal, VSpace.gutter).vScreen().onAppear { VFont.register() }
}

private extension FoodSearchResponse {
    /// The same body as the server sends when its Open Food Facts budget is spent.
    var busyCopy: FoodSearchResponse {
        let json = #"{"q":"paneer","page":1,"remote":"rate_limited","count":1,"results":[{"key":"recent:Paneer tikka","name":"Paneer tikka","brand":null,"source":"recent","source_ref":null,"estimate":true,"per_100g":null,"serving":{"label":"1 PLATE","grams":200,"kcal":420,"protein_g":28,"carbs_g":12,"fat_g":29},"label":"1 PLATE · ESTIMATE"}],"next_page":null}"#
        return (try? APICoding.decoder().decode(FoodSearchResponse.self, from: Data(json.utf8))) ?? self
    }
}
#endif
