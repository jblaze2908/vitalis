import Foundation
import Observation
import VitalisKit

/// Barcode lookup for the scan screen; the server talks to Open Food Facts, never the app.
@MainActor @Observable
final class BarcodeStore {
    typealias Lookup = @MainActor (String) async throws -> BarcodeResponse

    enum Phase: Equatable {
        case scanning
        case looking(String)
        case found(BarcodeResponse)
        case notFound(String)
        case failed(String, line: String)
    }

    private(set) var phase: Phase = .scanning
    private let lookup: Lookup

    init(lookup: @escaping Lookup) { self.lookup = lookup }

    static func live() -> BarcodeStore {
        BarcodeStore { code in
            guard let api = Services.shared.api else { throw APIError.transport(URLError(.notConnectedToInternet)) }
            return try await api.barcode(code: code).value
        }
    }

    /// The scanner reports a code many times a second; only the first one while scanning counts.
    func scanned(_ raw: String) async {
        guard case .scanning = phase else { return }
        let code = raw.filter(\.isNumber)
        guard (8...14).contains(code.count) else { return }
        phase = .looking(code)
        do {
            let r = try await lookup(code)
            phase = r.found && r.item != nil ? .found(r) : .notFound(code)
        } catch {
            phase = .failed(code, line: (error as? APIError)?.statusLine ?? "COULDN'T LOOK UP")
        }
    }

    func rescan() { phase = .scanning }

    /// `8 901 063 152 207`: EAN-13 as printed (1 + 4 × 3); other lengths in threes.
    nonisolated static func grouped(_ code: String) -> String {
        var groups: [String] = []
        var rest = Substring(code)
        if code.count == 13 { groups.append(String(rest.prefix(1))); rest = rest.dropFirst() }
        while !rest.isEmpty { groups.append(String(rest.prefix(3))); rest = rest.dropFirst(3) }
        return groups.joined(separator: " ")
    }
}
