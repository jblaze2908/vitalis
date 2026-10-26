import SwiftUI
import VitalisKit
import VitalisUI

/// Settings → Splits (11 §7.2): the owner's own splits, name + muscles. Workout names logged elsewhere show up on their own.
struct SplitsScreen: View {
    @Environment(Router.self) private var router
    @Environment(Services.self) private var services
    @State private var splits: Loadable<SplitsResponse>
    @State private var editing: SplitDraft?

    init(splits: SplitsResponse? = nil) { _splits = State(initialValue: Loadable(splits)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsBar(title: "Splits", back: { if !router.settingsPath.isEmpty { router.settingsPath.removeLast() } })
                FreshnessLine(DataFreshness(fetchedAt: splits.fetchedAt, refreshing: splits.isLoading))
                    .frame(maxWidth: .infinity).padding(.top, VSpace.s1)
                Text("Vitalis offers these when you start a workout and never picks one for you. Any other workout name you log is offered too.")
                    .vText(.body).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s4)

                SettingsGroup(title: "Your splits") {
                    ForEach(splits.value?.splits ?? []) { split in
                        SettingsRow(key: split.name, value: Self.summary(split.muscles)) { editing = SplitDraft(split) }
                    }
                    if splits.value?.splits.isEmpty ?? false {
                        Text("None yet").vText(.secondary).frame(maxWidth: .infinity, minHeight: VSpace.rowMin, alignment: .leading)
                    }
                }
                SecondaryButton("Add split", systemImage: "plus", size: .full) { editing = SplitDraft() }
                    .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
                if let error = splits.error as? APIError {
                    Text(error.statusLine).vText(.secondary, color: VColor.watch).padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
                }
            }
            .padding(.bottom, VSpace.s6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await load() }
        .vScreen()
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(item: $editing) { draft in
            SplitEditSheet(draft: draft) { await save($0) } onDelete: { await delete($0) }
        }
    }

    static func summary(_ muscles: [String]) -> String {
        let names = muscles.compactMap { Muscle(rawValue: $0)?.displayName }
        switch names.count {
        case 0: return "Any muscles"
        case 1...2: return names.joined(separator: ", ")
        default: return "\(names[0]), \(names[1]) +\(names.count - 2)"
        }
    }

    private func load() async {
        guard let api = services.api else { return }
        await splits.load(cached: { await api.cached(SplitsResponse.self, path: "v2/splits") }) { try await api.splits() }
    }

    /// Direct, not queued: a duplicate name (409) has to come back to the sheet.
    private func save(_ draft: SplitDraft) async -> String? {
        guard let api = services.api else { return "Not connected" }
        do {
            splits.set(try await api.putSplit(id: draft.id, SplitPut(name: draft.name, muscles: draft.muscles.sorted())))
            services.noteWrite()
            return nil
        } catch { return (error as? APIError)?.statusLine ?? error.localizedDescription }
    }

    private func delete(_ id: String) async -> String? {
        guard let api = services.api else { return "Not connected" }
        do {
            splits.set(try await api.deleteSplit(id: id))
            services.noteWrite()
            return nil
        } catch { return (error as? APIError)?.statusLine ?? error.localizedDescription }
    }
}

struct SplitDraft: Identifiable {
    let id: String
    let isNew: Bool
    var name: String
    var muscles: Set<String>

    init() { id = UUID().uuidString.lowercased(); isNew = true; name = ""; muscles = [] }
    init(_ split: DefinedSplit) { id = split.id; isNew = false; name = split.name; muscles = Set(split.muscles) }
}

/// Name + muscle toggles. A split with no muscles is always offered as fresh.
struct SplitEditSheet: View {
    @State var draft: SplitDraft
    let onSave: (SplitDraft) async -> String?
    let onDelete: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        SheetChrome {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(draft.isNew ? "New split" : "Edit split").vText(.title)
                    Text("Name").vText(.secondary).padding(.top, VSpace.s5)
                    UnderlinedField(text: $draft.name, prompt: "Push", style: .title, keyboard: .default)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                        .padding(.top, VSpace.s2)
                    Text("Muscles it needs fresh").vText(.secondary).padding(.top, VSpace.s5)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: VSpace.s2)], alignment: .leading, spacing: VSpace.s2) {
                        ForEach(Muscle.allCases, id: \.rawValue) { m in
                            let on = draft.muscles.contains(m.rawValue)
                            ChoiceChip(m.displayName, on: on) {
                                if on { draft.muscles.remove(m.rawValue) } else { draft.muscles.insert(m.rawValue) }
                            }
                        }
                    }
                    .padding(.top, VSpace.s3)
                    if let error { Text(error).vText(.secondary, color: VColor.watch).padding(.top, VSpace.s3) }
                    PrimaryButton(busy ? "Saving" : "Save") { Task { await save() } }
                        .disabled(busy || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.top, VSpace.s5)
                    if !draft.isNew {
                        SecondaryButton("Delete split", size: .full) { Task { await delete() } }.padding(.top, VSpace.s3)
                    }
                }
                .padding(.horizontal, VSpace.edge)
                .padding(.top, VSpace.s5)
                .padding(.bottom, VSpace.edge)
            }
        }
        .presentationDetents([.large])
    }

    private func save() async {
        busy = true; defer { busy = false }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if let message = await onSave(draft) { error = message } else { dismiss() }
    }

    private func delete() async {
        busy = true; defer { busy = false }
        if let message = await onDelete(draft.id) { error = message } else { dismiss() }
    }
}
