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
                field.padding(.top, VSpace.s4)
                summary.padding(.top, VSpace.s4).padding(.bottom, VSpace.s2)
                if !search.results.isEmpty {
                    ListCard {
                        ForEach(search.results, id: \.key) { r in
                            FoodRow(name: r.name, detail: r.label ?? r.serving.label, kcal: r.serving.kcal) {
                                add([FoodDraft(name: r.name, serving: r.serving)], r.source, r.sourceRef, r.estimate)
                            }
                        }
                    }
                }
                if store.describeAvailable { describeLink.padding(.top, VSpace.s5) }
            }
            .padding(.bottom, VSpace.s5)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: VSpace.s3) {
            Image(systemName: "magnifyingglass").font(.body.weight(.medium)).foregroundStyle(VColor.text2)
            TextField("", text: Binding(get: { search.query }, set: { search.update(query: $0) }),
                      prompt: Text("Search food").foregroundStyle(VColor.text3))
                .vText(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .tint(VColor.eat)
        }
        .padding(.horizontal, VSpace.s4)
        .frame(minHeight: VSpace.rowMin)
        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
    }

    @ViewBuilder private var summary: some View {
        if let line = search.errorLine { Text(line).vText(.secondary, color: VColor.watch) }
        else if let busy = search.remoteLine { Text(busy).vText(.secondary, color: VColor.watch) }
        else if search.response != nil { Text("\(search.results.count) result\(search.results.count == 1 ? "" : "s")").vText(.secondary) }
        else if search.isSearching { Text("Searching").vText(.secondary) }
        else if FoodSearchStore.normalized(search.query).count < FoodSearchStore.minimumLength, !search.query.isEmpty {
            Text("Type \(FoodSearchStore.minimumLength) letters or more").vText(.secondary)
        }
    }

    private var describeLink: some View {
        ListCard {
            Button { describe(search.query) } label: {
                ListRow("Describe the meal", subtitle: "Not quite it? We fill in the macros")
            }
            .buttonStyle(.plain)
        }
    }
}

#if DEBUG
#Preview("Search") {
    let search = FoodSearchStore(debounce: .zero) { _ in EatPreview.decode(FoodSearchResponse.self, "food-search")! }
    search.update(query: "paneer")
    return FoodSearchView(search: search, store: EatPreview.store(), add: { _, _, _, _ in }, describe: { _ in })
        .padding(.horizontal, VSpace.edge).vScreen().onAppear { VFont.register() }
}

#Preview("Search · online busy") {
    let search = FoodSearchStore(debounce: .zero) { _ in EatPreview.decode(FoodSearchResponse.self, "food-search")!.busyCopy }
    search.update(query: "paneer")
    return FoodSearchView(search: search, store: EatPreview.store(), add: { _, _, _, _ in }, describe: { _ in })
        .padding(.horizontal, VSpace.edge).vScreen().onAppear { VFont.register() }
}

private extension FoodSearchResponse {
    /// The same body as the server sends when its Open Food Facts budget is spent.
    var busyCopy: FoodSearchResponse {
        let json = #"{"q":"paneer","page":1,"remote":"rate_limited","count":1,"results":[{"key":"recent:Paneer tikka","name":"Paneer tikka","brand":null,"source":"recent","source_ref":null,"estimate":true,"per_100g":null,"serving":{"label":"1 PLATE","grams":200,"kcal":420,"protein_g":28,"carbs_g":12,"fat_g":29},"label":"1 PLATE · ESTIMATE"}],"next_page":null}"#
        return (try? APICoding.decoder().decode(FoodSearchResponse.self, from: Data(json.utf8))) ?? self
    }
}
#endif
