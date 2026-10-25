import AppIntents
import Foundation

/// Logs a weight through `BodyStore.saveWeight`, the Log weight sheet's path: Health sample, then the outbox POST.
struct LogWeightIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Weight"
    static let description = IntentDescription("Logs your weight in kilograms to Vitalis and Apple Health.")

    @Parameter(title: "Weight (kg)", requestValueDialog: "How much do you weigh, in kilograms?")
    var kg: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try IntentData.api()
        let tenths = Int((kg * 10).rounded())
        guard WeightRuler.range.contains(tenths) else {
            let r = WeightRuler.range
            throw $kg.needsValueError(IntentDialog(stringLiteral: "Say a weight between \(r.lowerBound / 10) and \(r.upperBound / 10) kilograms."))
        }
        let store = BodyStore()
        // Same default as the sheet's "Also save to Apple Health" toggle.
        await store.saveWeight(tenths: tenths, at: Date(), alsoHealth: true, settles: false)
        guard let saved = store.lastSaved, saved.outboxID != nil else { throw IntentFailure.notSaved }
        let text = SpokenSummary.weightLogged(kg: saved.kg, waitingToSync: false, healthFailed: saved.healthFailed)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}
