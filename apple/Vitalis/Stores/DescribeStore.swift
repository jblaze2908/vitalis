import Foundation
import Observation
import VitalisKit

/// Describe & confirm: the server parses the words; the owner only picks one of the server's portion options per item.
@MainActor @Observable
final class DescribeStore {
    typealias Describe = @MainActor (DescribeRequest) async throws -> DescribeResponse

    var text: String
    /// Set when Describe came from a barcode miss, so the confirmed item is remembered for that code.
    let barcode: String?
    private(set) var response: DescribeResponse?
    /// Index into each item's `portion_options`.
    private(set) var choices: [Int] = []
    private(set) var isLoading = false
    private(set) var errorLine: String?
    private(set) var unavailable = false
    private var describedText: String?

    private let describe: Describe

    init(text: String = "", barcode: String? = nil, describe: @escaping Describe) {
        self.text = text; self.barcode = barcode; self.describe = describe
    }

    static func live(text: String = "", barcode: String? = nil) -> DescribeStore {
        DescribeStore(text: text, barcode: barcode) { request in
            guard let api = Services.shared.api else { throw APIError.transport(URLError(.notConnectedToInternet)) }
            return try await api.describe(request)
        }
    }

    var canSubmit: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && !isLoading }
    var isStale: Bool { response == nil || describedText != text }

    func submit(slot: String) async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 3 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await describe(DescribeRequest(text: String(words.prefix(500)), slot: slot))
            response = r
            choices = r.items.map(Self.initialChoice)
            describedText = text
            errorLine = nil
        } catch APIError.unavailable {
            unavailable = true
            errorLine = "DESCRIBE ISN'T SET UP ON YOUR SERVER"
        } catch APIError.rateLimited {
            errorLine = "TOO MANY DESCRIBES · TRY AGAIN LATER"
        } catch {
            errorLine = (error as? APIError)?.statusLine ?? "COULDN'T DESCRIBE"
        }
    }

    var items: [DescribeResponse.Item] { response?.items ?? [] }

    func option(_ i: Int) -> DescribeResponse.PortionOption? {
        guard items.indices.contains(i), choices.indices.contains(i) else { return nil }
        let options = items[i].portionOptions
        return options.indices.contains(choices[i]) ? options[choices[i]] : nil
    }

    func factor(_ i: Int) -> Double { option(i)?.factor ?? 1 }

    func canStep(_ i: Int, by delta: Int) -> Bool {
        guard items.indices.contains(i) else { return false }
        return items[i].portionOptions.indices.contains(choices[i] + delta)
    }

    func step(_ i: Int, by delta: Int) {
        guard canStep(i, by: delta) else { return }
        choices[i] += delta
    }

    /// The server's numbers × the chosen server factor (spec 10 §7: display of a server-given option).
    func draft(_ i: Int) -> FoodDraft {
        let item = items[i], f = factor(i)
        return FoodDraft(name: item.name, portionText: option(i)?.label ?? item.portionText, grams: item.grams.map { $0 * f },
                         kcal: item.kcal * f, proteinG: item.proteinG.map { $0 * f }, carbsG: item.carbsG.map { $0 * f },
                         fatG: item.fatG.map { $0 * f })
    }

    var drafts: [FoodDraft] { items.indices.map(draft) }

    /// Totals of what will be posted; nil when no item carries that macro.
    var totals: (kcal: Double, protein: Double?, carbs: Double?, fat: Double?) {
        let d = drafts
        func sum(_ k: KeyPath<FoodDraft, Double?>) -> Double? {
            let v = d.compactMap { $0[keyPath: k] }
            return v.isEmpty ? nil : v.reduce(0, +)
        }
        return (d.reduce(0) { $0 + $1.kcal }, sum(\.proteinG), sum(\.carbsG), sum(\.fatG))
    }

    /// The option the server marked as the described portion (factor 1), else the middle one.
    private static func initialChoice(_ item: DescribeResponse.Item) -> Int {
        item.portionOptions.firstIndex { $0.factor == 1 } ?? item.portionOptions.count / 2
    }
}
