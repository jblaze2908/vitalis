import SwiftUI
import VitalisKit
import VitalisUI

/// Catalog search for the logger (no approved frame; system sheet pattern in Vital line tokens).
/// `GET /v2/exercises?q=` after a 300 ms pause; offline it filters the cached catalog instead.
struct AddExerciseSheet: View {
    let api: VitalisAPI?
    let pick: (ExerciseInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ExerciseInfo] = []
    @State private var note: String?
    @FocusState private var searching: Bool

    var body: some View {
        SheetChrome {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { dismiss() } label: { MonoLabel("Cancel", tint: .bone).frame(minHeight: 44) }.buttonStyle(.plain)
                    Spacer()
                    Text("Add exercise").vHeadline(22)
                    Spacer()
                    MonoLabel("Cancel").hidden()
                }
                .padding(.top, 10)
                TextField("", text: $query, prompt: Text("Search exercises").foregroundStyle(VColor.steel))
                    .focused($searching)
                    .vReading(14)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .padding(.horizontal, 14)
                    .frame(height: VSpace.buttonHeight)
                    .overlay(RoundedRectangle(cornerRadius: VRadius.button, style: .continuous).inset(by: 0.75).stroke(VColor.future, lineWidth: 1.5))
                    .padding(.top, VSpace.sectionPad)
                if let note { MonoLabel(note, tint: .watch).padding(.top, VSpace.sectionPad) }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results, id: \.id) { e in
                            Button { pick(e); dismiss() } label: { row(e) }.buttonStyle(.plain)
                            Rule()
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .padding(.top, VSpace.sectionPad)
            }
            .padding(.horizontal, VSpace.gutter)
        }
        .presentationDetents([.large])
        .onAppear { searching = true }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(query.trimmingCharacters(in: .whitespaces))
        }
    }

    private func row(_ e: ExerciseInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(e.name).vHeadline(20).lineLimit(1).minimumScaleFactor(0.7)
            MonoLabel([e.equipment, e.primary.joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), size: .small)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func search(_ q: String) async {
        guard let api else { note = "Connect to your server to search"; return }
        guard !q.isEmpty else { results = []; note = nil; return }
        do {
            results = try await api.exercises(q: q).value.exercises
            note = nil
        } catch {
            results = await Self.offline(api: api, q: q)
            note = (error as? APIError)?.statusLine.appending(" · showing saved catalog") ?? "Showing saved catalog"
        }
    }

    /// Cached results for this query, else the cached full catalog matched on name and aliases.
    static func offline(api: VitalisAPI, q: String) async -> [ExerciseInfo] {
        if let hit = await api.cached(ExerciseList.self, path: "v2/exercises", query: VitalisAPI.query(["q": q]))?.value.exercises { return hit }
        let catalog = await api.cached(ExerciseList.self, path: "v2/exercises")?.value.exercises ?? []
        let needle = q.lowercased()
        return catalog.filter { e in e.name.lowercased().contains(needle) || (e.aliases ?? []).contains { $0.lowercased().contains(needle) } }
            .prefix(25).map { $0 }
    }
}

#if DEBUG
#Preview("Add exercise") {
    Color.clear.sheet(isPresented: .constant(true)) { AddExerciseSheet(api: nil) { _ in } }.vScreen().onAppear { VFont.register() }
}
#endif
