import AppIntents
import Foundation

/// Speaks last night's sleep score, band, time asleep and need from `GET /v2/sleep`.
struct HowDidISleepIntent: AppIntent {
    static let title: LocalizedStringResource = "How Did I Sleep"
    static let description = IntentDescription("Tells you last night's sleep score and how long you slept.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = SpokenSummary.sleep(try await IntentData.sleep())
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Speaks today's recovery score, band and verdict headline from `GET /v2/today`.
struct RecoveryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Recovery"
    static let description = IntentDescription("Tells you today's recovery score and what Vitalis suggests.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = SpokenSummary.recovery(try await IntentData.today())
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}
