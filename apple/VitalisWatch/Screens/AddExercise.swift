import SwiftUI
import VitalisKit
import VitalisUI

/// Add exercise (spec 21 §2.6, no frame): from Start (`Choose exercises`), the handoff `+`, or Set entry.
/// Plan exercises not done yet, then recent ones, then Search over the catalog the phone sent.
struct AddExerciseScreen: View {
    let model: WorkoutModel
    let catalog: WatchCatalog
    @State private var query: String

    init(model: WorkoutModel, catalog: WatchCatalog = .shared, query: String = "") {
        self.model = model
        self.catalog = catalog
        _query = State(initialValue: query)
    }

    private var planIDs: [String] {
        let plan = model.record?.exerciseIDs ?? []
        // The exercise being logged is excluded: picking it would insert a second copy.
        let done = Set((model.record?.allSets.map(\.exerciseID) ?? []) + [model.currentExerciseID].compactMap { $0 })
        return Self.unique(plan.filter { !done.contains($0) })
    }

    private var recentIDs: [String] {
        let shown = Set(planIDs)
        return Self.unique((model.pack?.recentExerciseIDs ?? []).filter { !shown.contains($0) })
    }

    /// The phone's catalog, plus pack exercises it doesn't list (a catalog file may not have arrived yet).
    private var entries: [ExerciseSearch.Entry] {
        var out = catalog.exercises.map(ExerciseSearch.Entry.init)
        let known = Set(out.map(\.id))
        for (id, e) in model.pack?.exercises ?? [:] where !known.contains(id) {
            out.append(.init(id: id, name: e.name, equipment: e.equipment, aliases: e.aliases ?? [], custom: false))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    searchRow
                    if query.isEmpty {
                        ForEach(planIDs + recentIDs, id: \.self) { id in
                            row(id: id, name: model.name(of: id), equipment: model.exercise(id)?.equipment)
                        }
                        if planIDs.isEmpty, recentIDs.isEmpty {
                            Text("Open Vitalis on your iPhone to bring your exercises here.").vBody(14, color: VColor.steel)
                                .padding(.top, AddLayout.bodyTop)
                        }
                    } else {
                        let results = ExerciseSearch.rank(query, in: entries)
                        ForEach(results, id: \.id) { e in row(id: e.id, name: e.name, equipment: e.equipment) }
                        if results.isEmpty {
                            MonoLabel("No match").padding(.top, AddLayout.bodyTop)
                        }
                    }
                }
                .padding(.horizontal, WatchLayout.side)
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { MonoLabel("Add exercise") } }
            .vScreen()
        }
        .task { await catalog.loadIfNeeded() }
    }

    /// The system text input (dictation, Scribble, keyboard); results replace the lists until cleared.
    @ViewBuilder private var searchRow: some View {
        let title = query.isEmpty ? "Search" : query
        #if os(watchOS)
        TextFieldLink(prompt: Text("Exercise")) {
            rowLabel(title: title, detail: query.isEmpty ? nil : "Change")
        } onSubmit: { query = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .buttonStyle(.plain)
        #else
        TextField("Search", text: $query).vHeadline(17).frame(height: WatchLayout.rowHeight)
        #endif
        if !query.isEmpty {
            Button { query = "" } label: { rowLabel(title: "Show plan", detail: nil) }.buttonStyle(.plain)
        }
    }

    private func row(id: String, name: String, equipment: String?) -> some View {
        Button { select(id) } label: { rowLabel(title: name, detail: equipment) }
            .buttonStyle(.plain)
    }

    /// 35 pt, rule on top: Headline 17 name, MonoLabel 10 equipment.
    private func rowLabel(title: String, detail: String?) -> some View {
        VStack(spacing: 0) {
            Rule()
            HStack(alignment: .firstTextBaseline) {
                Text(title).vHeadline(17).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: AddLayout.detailGap)
                if let detail { MonoLabel(detail, size: .small).lineLimit(1) }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: WatchLayout.rowHeight)
        .contentShape(Rectangle())
    }

    /// A catalog-only pick is added to the local pack first, so names, muscles and summary lighting know it.
    private func select(_ id: String) {
        if model.exercise(id) == nil, let info = catalog.exercises.first(where: { $0.id == id }) {
            var pack = model.pack ?? WatchPack(generatedAt: "")
            pack.exercises[id] = WatchPack.Exercise(name: info.name, equipment: info.equipment, primary: info.primary,
                                                    secondary: info.secondary, aliases: info.aliases)
            model.apply(pack: pack)
        }
        model.addExercise(id)
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

private enum AddLayout {
    static let bodyTop: CGFloat = 10
    static let detailGap: CGFloat = 6
}

/// The server's `findExercises()` ranking (app/src/exercises.ts) over catalog names and aliases: string matching only.
enum ExerciseSearch {
    struct Entry: Equatable {
        let id: String
        let name: String
        let equipment: String?
        let aliases: [String]
        let custom: Bool

        init(id: String, name: String, equipment: String?, aliases: [String], custom: Bool) {
            self.id = id; self.name = name; self.equipment = equipment; self.aliases = aliases; self.custom = custom
        }
        init(_ info: ExerciseInfo) {
            self.init(id: info.id, name: info.name, equipment: info.equipment, aliases: info.aliases ?? [], custom: info.custom ?? false)
        }
    }

    static let limit = 25

    static func norm(_ s: String) -> String {
        s.lowercased().replacing(/[^a-z0-9]+/, with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func rank(_ query: String, in entries: [Entry], limit: Int = limit) -> [Entry] {
        let q = norm(query), words = q.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let slug = q.replacingOccurrences(of: " ", with: "-")
        let scored: [(entry: Entry, score: Int)] = entries.map { e in
            let names = [norm(e.name)] + e.aliases.map(norm)
            if e.id == slug || names.contains(q) { return (e, 100) }
            let hay = Set(names.joined(separator: " ").split(separator: " ").map(String.init))
            let hit = words.filter { w in hay.contains(w) || (w.count >= 3 && hay.contains { $0.hasPrefix(w) }) }.count
            guard hit > 0 else { return (e, 0) }
            let raw = Double(hit) / Double(words.count) * 70 - Double(norm(e.name).split(separator: " ").count)
                + (e.aliases.isEmpty ? 0 : 6) + (e.custom ? 8 : 0)
            return (e, Int(raw.rounded()))
        }
        return scored.filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.name.localizedCompare($1.entry.name) == .orderedAscending }
            .prefix(limit).map(\.entry)
    }
}

#if DEBUG
private let previewCatalog: [ExerciseInfo] = (try? APICoding.decoder().decode([ExerciseInfo].self, from: Data("""
[{"id":"barbell-squat","name":"Barbell Squat","equipment":"barbell","primary":["quadriceps"],"secondary":["glutes"],"aliases":["squat","back squat","squats"],"custom":false},
 {"id":"front-barbell-squat","name":"Front Barbell Squat","equipment":"barbell","primary":["quadriceps"],"secondary":["glutes"],"aliases":[],"custom":false},
 {"id":"hack-squat","name":"Hack Squat","equipment":"machine","primary":["quadriceps"],"secondary":["glutes"],"aliases":[],"custom":false},
 {"id":"goblet-squat","name":"Goblet Squat","equipment":"kettlebells","primary":["quadriceps"],"secondary":["glutes"],"aliases":[],"custom":false}]
""".utf8))) ?? []
#endif

#Preview("Add exercise · during a workout") {
    AddExerciseScreen(model: .preview(.setEntry), catalog: WatchCatalog(exercises: previewCatalog)).onAppear { VFont.register() }
}

#Preview("Add exercise · search results") {
    AddExerciseScreen(model: .preview(.setEntry), catalog: WatchCatalog(exercises: previewCatalog), query: "squat")
        .onAppear { VFont.register() }
}

#Preview("Add exercise · no pack yet") {
    AddExerciseScreen(model: .preview(.startNoPack), catalog: WatchCatalog(exercises: [])).onAppear { VFont.register() }
}
