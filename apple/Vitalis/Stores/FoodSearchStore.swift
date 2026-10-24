import Foundation
import Observation
import VitalisKit

/// Food search (spec 20 §4 Eat): 500 ms debounce, at least 3 characters, never more than one request in flight,
/// because the server's Open Food Facts budget is 8 searches a minute.
@MainActor @Observable
final class FoodSearchStore {
    typealias Search = @MainActor (String) async throws -> FoodSearchResponse

    static let minimumLength = 3

    private(set) var query = ""
    private(set) var response: FoodSearchResponse?
    private(set) var isSearching = false
    private(set) var errorLine: String?

    private let search: Search
    private let debounce: Duration
    private var debounceTask: Task<Void, Never>?
    private var inFlight = false
    /// The newest query that matured while a request was running; sent once that one returns.
    private var queued: String?

    init(debounce: Duration = .milliseconds(500), search: @escaping Search) {
        self.debounce = debounce; self.search = search
    }

    static func live() -> FoodSearchStore {
        FoodSearchStore { q in
            guard let api = Services.shared.api else { throw APIError.transport(URLError(.notConnectedToInternet)) }
            return try await api.foodSearch(q: q).value
        }
    }

    var results: [FoodSearchResponse.Result] { response?.results ?? [] }

    /// `ONLINE SEARCH BUSY · SHOWING YOURS` when the server fell back to the owner's own items.
    var remoteLine: String? {
        guard let remote = response?.remote, remote == "rate_limited" || remote == "unavailable" else { return nil }
        return "ONLINE SEARCH BUSY · SHOWING YOURS"
    }

    /// Called per keystroke; only a query that stays unchanged for the debounce is sent.
    func update(query text: String) {
        query = text
        debounceTask?.cancel()
        let q = Self.normalized(text)
        guard q.count >= Self.minimumLength else {
            queued = nil; response = nil; errorLine = nil
            return
        }
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.submit(q)
        }
    }

    private func submit(_ q: String) async {
        guard !inFlight else { queued = q; return }
        guard q != response?.q || errorLine != nil else { return }
        inFlight = true; isSearching = true
        do {
            let r = try await search(q)
            if Self.normalized(query).count >= Self.minimumLength { response = r }
            errorLine = nil
        } catch {
            errorLine = (error as? APIError)?.statusLine ?? "COULDN'T SEARCH"
        }
        inFlight = false; isSearching = false
        if let next = queued {
            queued = nil
            if next == Self.normalized(query) { await submit(next) }
        }
    }

    /// Same normalisation the server applies (trim, lower-case, single spaces), so equal queries aren't resent.
    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
