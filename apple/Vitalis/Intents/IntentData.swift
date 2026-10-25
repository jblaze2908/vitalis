import Foundation
import VitalisKit

/// Why an intent couldn't answer or save; Siri reads the resource aloud.
enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notConnected
    case notSaved

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected: "Vitalis isn't connected to your server yet. Open Vitalis to finish setup."
        case .notSaved: "Vitalis couldn't save that weight. Try again from the Body tab."
        }
    }
}

/// Reads for spoken answers: a fresh fetch if it lands quickly, else the cached body the screens would show.
@MainActor
enum IntentData {
    /// HTTPCore's 30 s read timeout is longer than Siri waits for a dialog.
    nonisolated static let fetchTimeout: Duration = .seconds(6)

    static func api() throws -> VitalisAPI {
        guard let api = Services.shared.api else { throw IntentFailure.notConnected }
        return api
    }

    static func sleep() async throws -> SleepResponse? {
        let api = try api()
        return await latest(cached: { await api.cached(SleepResponse.self, path: "v2/sleep") }, fetch: { try await api.sleep() })
    }

    static func today() async throws -> TodayResponse? {
        let api = try api()
        return await latest(cached: { await api.cached(TodayResponse.self, path: "v2/today") }, fetch: { try await api.today() })
    }

    private static func latest<T: Sendable>(cached: @Sendable () async -> APIResponse<T>?,
                                            fetch: @escaping @Sendable () async throws -> APIResponse<T>) async -> T? {
        let fresh: T? = await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await fetch().value }
            group.addTask { try? await Task.sleep(for: fetchTimeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let fresh { return fresh }
        return await cached()?.value
    }
}
