import AppIntents
import Foundation
import VitalisKit

/// A saved meal as Siri and Shortcuts see it, so "Log protein shake in Vitalis" needs no screen.
struct SavedMealEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Meal"
    static let defaultQuery = SavedMealQuery()
    let id: String
    let name: String
    let kcal: Double?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: kcal.map { "\(Int($0.rounded())) kcal" }.map { LocalizedStringResource(stringLiteral: $0) })
    }
}

struct SavedMealQuery: EntityStringQuery {
    /// The saved meals the app last saw, refreshed from the server when nothing is loaded yet (bounded like other intents).
    @MainActor static func meals() async -> [SavedMealInfo] {
        let store = EatStore.shared
        if store.quick.value == nil {
            let load = Task { @MainActor in await store.loadQuick(slot: nil) }
            let timer = Task { try? await Task.sleep(for: IntentData.fetchTimeout); load.cancel() }
            await load.value
            timer.cancel()
        }
        return store.savedMeals
    }
    private static func entity(_ m: SavedMealInfo) -> SavedMealEntity { SavedMealEntity(id: m.id, name: m.name, kcal: m.kcal) }

    @MainActor func entities(for identifiers: [String]) async throws -> [SavedMealEntity] {
        await Self.meals().filter { identifiers.contains($0.id) }.map(Self.entity)
    }
    @MainActor func entities(matching string: String) async throws -> [SavedMealEntity] {
        let q = string.lowercased()
        return await Self.meals().filter { $0.name.lowercased().contains(q) || q.contains($0.name.lowercased()) }.map(Self.entity)
    }
    @MainActor func suggestedEntities() async throws -> [SavedMealEntity] { await Self.meals().map(Self.entity) }
}

struct LogSavedMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Saved Meal"
    static let description = IntentDescription("Adds one of your saved meals to today in Vitalis and Apple Health.")

    @Parameter(title: "Meal", requestValueDialog: "Which saved meal?")
    var meal: SavedMealEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try IntentData.api()
        guard let m = await SavedMealQuery.meals().first(where: { $0.id == meal.id }) else { throw IntentFailure.noSavedMeal }
        let store = EatStore.shared
        let slot = store.slotNow
        await store.logSaved(m, slot: slot)
        return .result(dialog: IntentDialog(stringLiteral: "Added \(m.name) to \(slot), \(FoodFormat.kcal(m.kcal)) calories."))
    }
}
