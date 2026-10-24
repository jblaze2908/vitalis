import Foundation
import Observation
import VitalisKit

/// First-run steps (spec 20 §4 Setup). Welcome has no number; the other four are "STEP n OF 4".
enum SetupStep: Int, CaseIterable, Sendable {
    case welcome, connect, health, history, targets

    var number: Int? { self == .welcome ? nil : rawValue }

    static let savedKey = "setupStep"

    /// Where setup reopens: no server → Welcome; server but no token → Connect; both → the furthest step reached (at least Health).
    static func resume(hasServer: Bool, hasToken: Bool, saved: Int?) -> SetupStep {
        guard hasServer else { return .welcome }
        guard hasToken else { return .connect }
        return max(SetupStep(rawValue: saved ?? 0) ?? .health, .health)
    }
    var statusLabel: String { number.map { "STEP \($0) OF 4" } ?? "SETUP" }

    /// PulseLine progress variant: now at step / 4.5, a dip at the previous step.
    var pulse: (events: [Double], now: Double)? {
        guard let n = number else { return nil }
        return (n > 1 ? [Double(n - 1) / 4.5] : [], Double(n) / 4.5)
    }
}

/// Result of checking the server and token on the Connect step.
enum ConnectState: Equatable, Sendable {
    case idle, checking, connected
    case invalidURL, missingToken, unreachable, rejected, readOnly
    /// `/v2/sync/status` has no `token` block (exporter-era server), so write scope can't be verified.
    case outdatedServer
    case failed(String)

    var label: String? {
        switch self {
        case .idle: nil
        case .checking: "Checking server"
        case .connected: "Connected · token can write"
        case .invalidURL: "Enter an http(s) server URL"
        case .missingToken: "Paste a write token"
        case .unreachable: "Can't reach this server"
        case .rejected: "Token rejected"
        case .readOnly: "This token can't log workouts or food"
        case .outdatedServer: "Update your server to check this token"
        case .failed(let message): message
        }
    }

    var isError: Bool {
        switch self { case .idle, .checking, .connected: false; default: true }
    }

    static func from(_ error: APIError) -> ConnectState {
        switch error {
        case .unauthorized: .rejected
        case .scope: .readOnly
        case .transport: .unreachable
        case .notFound, .decoding: .failed("No Vitalis server at this URL")
        case .unavailable, .rateLimited: .failed("Server busy · try again")
        case .server(let code): .failed("Server error \(code)")
        case .conflict, .invalid: .failed("Couldn't check this server")
        }
    }
}

/// Reading-your-history progress (spec 20 §4, brief 03 → Setup 4). Exporter progress only, never health data.
struct HistoryProgress: Equatable, Sendable {
    /// 0…100, nil before the first page lands.
    let percent: Int?
    /// Month of the page being read, e.g. "MARCH 2023".
    let reading: String?
    let samplesSent: String
    let timeLeft: String?
    let done: Bool

    /// Percent = the current page's newest sample date between the oldest date seen and now. `TypeHistory` keeps only
    /// `newestEnd`, so "oldest seen" is the earliest page date observed since this step began.
    static func make(snapshot: SyncSnapshot, oldestSeen: Date?, startedAt: Date?, now: Date,
                     typeOrder: [String] = [], calendar: Calendar = .current) -> HistoryProgress {
        let history = snapshot.history
        let sent = history.types.values.reduce(0) { $0 + $1.objectsSent }
        let pageDate = snapshot.currentType.flatMap { history.types[$0]?.newestEnd }.flatMap(APIDate.parse)
        // Idle after a successful upload is caught up, even when a relaunch lost this step's start time.
        let done = snapshot.phase == "Idle"
            && (history.lastSuccess.map { s in startedAt.map { s >= $0 } ?? true } ?? false)

        var percent: Int?
        if done {
            percent = 100
        } else if let pageDate {
            let oldest = min(oldestSeen ?? pageDate, pageDate)
            let span = now.timeIntervalSince(oldest)
            percent = span > 0 ? min(99, max(0, Int(pageDate.timeIntervalSince(oldest) / span * 100))) : 0
        } else if let current = snapshot.currentType, let i = typeOrder.firstIndex(of: current), !typeOrder.isEmpty {
            // Most Health types hold no samples, so there's usually no page date: fall back to types done in read order.
            percent = min(99, i * 100 / typeOrder.count)
        }

        var timeLeft: String?
        if done {
            timeLeft = "Done"
        } else if let p = percent, p >= 5, let startedAt {
            let minutes = Int((now.timeIntervalSince(startedAt) * Double(100 - p) / Double(p) / 60).rounded(.up))
            timeLeft = "About \(max(1, minutes)) min"
        }

        let reading = pageDate.map { date -> String in
            let f = DateFormatter()
            f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "LLLL yyyy"
            return f.string(from: date).uppercased()
        }
        return HistoryProgress(percent: percent, reading: reading, samplesSent: compact(sent), timeLeft: timeLeft, done: done)
    }

    /// 980 · 14.8K · 1.84M
    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        default: return String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }
}

/// A target the owner can set with PUT /v2/targets; ranges are the server's validation (10 §3), checked here so a
/// bad value never sits in the outbox's failed list.
enum TargetField: String, CaseIterable, Identifiable, Sendable {
    case steps, kcal, proteinG, sleepNeedH, goalWeightKg, weeklySetsMin, weeklySetsMax, restS, crownStepKg

    var id: String { rawValue }
    static let setup: [TargetField] = [.steps, .kcal, .proteinG, .sleepNeedH, .goalWeightKg]

    var title: String {
        switch self {
        case .steps: "Steps a day"
        case .kcal: "Calories"
        case .proteinG: "Protein"
        case .sleepNeedH: "Sleep need"
        case .goalWeightKg: "Goal weight"
        case .weeklySetsMin: "Fewest sets"
        case .weeklySetsMax: "Most sets"
        case .restS: "Default rest"
        case .crownStepKg: "Crown weight step"
        }
    }

    var unit: String? {
        switch self {
        case .proteinG: "G"
        case .sleepNeedH: "H"
        case .goalWeightKg, .crownStepKg: "KG"
        case .restS: "S"
        default: nil
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .steps: 1_000...50_000
        case .kcal: 1_000...6_000
        case .proteinG: 30...400
        case .sleepNeedH: 5...11
        case .goalWeightKg: 30...300
        case .weeklySetsMin, .weeklySetsMax: 0...60
        case .restS: 15...600
        case .crownStepKg: 0.5...5
        }
    }

    /// Only these values are accepted (crown step).
    var choices: [Double]? { self == .crownStepKg ? [0.5, 1, 1.25, 2, 2.5, 5] : nil }
    var isInteger: Bool { ![.proteinG, .sleepNeedH, .goalWeightKg, .crownStepKg].contains(self) }

    /// Display text without unit: 9,000 · 160 · 7.5 · 74.0 · 2:00 · 2.5
    func format(_ value: Double?) -> String {
        guard let value else { return "–" }
        switch self {
        case .restS:
            let s = Int(value.rounded())
            return String(format: "%d:%02d", s / 60, s % 60)
        case .goalWeightKg:
            return String(format: "%.1f", value)
        case .sleepNeedH, .proteinG, .crownStepKg:
            return value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
        default:
            return Int(value.rounded()).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        }
    }

    /// Text for the edit field (no grouping, rest in seconds).
    func editText(_ value: Double?) -> String {
        guard let value else { return "" }
        return isInteger ? String(Int(value.rounded())) : String(format: "%g", value)
    }

    /// nil when valid, else a mono error line.
    func validate(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return "Enter a number" }
        if let choices { return choices.contains(value) ? nil : "Choose one of the steps" }
        guard range.contains(value) else {
            if self == .restS { return "Between 15 and 600 seconds" }
            return "Between \(format(range.lowerBound)) and \(format(range.upperBound))"
        }
        if self == .sleepNeedH, (value * 4).rounded() != value * 4 { return "Quarter hours only" }
        if isInteger, value.rounded() != value { return "Whole numbers only" }
        return nil
    }

    func apply(_ value: Double, to patch: inout TargetsPatch) {
        switch self {
        case .steps: patch.steps = .set(Int(value))
        case .kcal: patch.kcal = .set(Int(value)); patch.kcalMode = .set("fixed")
        case .proteinG: patch.proteinG = .set(value)
        case .sleepNeedH: patch.sleepNeedH = .set(value)
        case .goalWeightKg: patch.goalWeightKg = .set(value)
        case .weeklySetsMin: patch.weeklySetsMin = .set(Int(value))
        case .weeklySetsMax: patch.weeklySetsMax = .set(Int(value))
        case .restS: patch.restS = .set(Int(value))
        case .crownStepKg: patch.crownStepKg = .set(value)
        }
    }

    /// A PUT for one edit sheet; nil (with the first error) when any value is invalid or the range is inverted.
    static func patch(_ values: [TargetField: Double]) -> (patch: TargetsPatch?, error: String?) {
        for (field, value) in values.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let error = field.validate(value) { return (nil, "\(field.title) · \(error)") }
        }
        if let lo = values[.weeklySetsMin], let hi = values[.weeklySetsMax], lo > hi { return (nil, "Fewest sets must not exceed most") }
        var patch = TargetsPatch()
        for (field, value) in values { field.apply(value, to: &patch) }
        return (patch, nil)
    }
}

/// The Targets step: server suggestions, the owner's edits, and the PUT that Finish sends.
struct TargetDraft: Equatable, Sendable {
    private(set) var values: [TargetField: Double] = [:]
    private(set) var basis: [TargetField: String] = [:]
    private(set) var edited: Set<TargetField> = []

    init(suggested: TargetsResponse.Suggested? = nil) {
        let pairs: [(TargetField, TargetsResponse.Suggestion?)] = [
            (.steps, suggested?.steps), (.kcal, suggested?.kcal), (.proteinG, suggested?.proteinG),
            (.sleepNeedH, suggested?.sleepNeedH), (.goalWeightKg, suggested?.goalWeightKg),
        ]
        for (field, s) in pairs {
            if let v = s?.value { values[field] = v }
            if let b = s?.basis { basis[field] = b }
        }
    }

    func value(_ field: TargetField) -> Double? { values[field] }

    mutating func set(_ field: TargetField, _ value: Double) { values[field] = value; edited.insert(field) }

    /// The values shown. Calories stay adaptive unless the owner typed a number (10 §3 `kcal_mode`).
    func patch() -> TargetsPatch {
        var patch = TargetsPatch()
        for field in TargetField.setup where field != .kcal {
            if let v = values[field] { field.apply(v, to: &patch) }
        }
        if edited.contains(.kcal), let kcal = values[.kcal] { TargetField.kcal.apply(kcal, to: &patch) }
        else if values[.kcal] != nil { patch.kcalMode = .set("adaptive") }
        return patch
    }
}

@MainActor @Observable
final class SetupStore {
    /// Everything with a side effect, so tests can drive the flow with a stub API.
    struct Dependencies {
        var makeAPI: @MainActor (ServerSettings) -> VitalisAPI
        /// Saves the URL and token (Keychain) and points the exporter at the server.
        var persist: @MainActor (ServerSettings, String) async throws -> Void
        var didConnect: @MainActor () -> Void = {}
        var authorizeHealth: @MainActor () async -> Void = {}
        var send: @MainActor (APIRequest) async -> Void = { _ in }
        var now: @MainActor () -> Date = { Date() }
    }

    private let deps: Dependencies
    /// Saved on every move so quitting mid-setup resumes at the same step instead of asking for the token again.
    var step: SetupStep { didSet { UserDefaults.standard.set(step.rawValue, forKey: SetupStep.savedKey) } }
    var serverText: String { didSet { if serverText != oldValue { connect = .idle } } }
    /// Held only until Connect succeeds; never logged or shown.
    var tokenText = "" { didSet { if tokenText != oldValue { connect = .idle } } }
    private(set) var connect: ConnectState = .idle
    private(set) var isAuthorizing = false
    private(set) var settings: ServerSettings?

    private(set) var snapshot = SyncSnapshot()
    private(set) var oldestSeen: Date?
    private(set) var historyStartedAt: Date?

    private(set) var draft = TargetDraft()
    private(set) var targetsError: APIError?
    private(set) var targetsLoaded = false
    private(set) var isFinishing = false

    init(deps: Dependencies, step: SetupStep = .welcome, serverText: String = "") {
        self.deps = deps; self.step = step; self.serverText = serverText
    }

    var canContinue: Bool { connect == .connected }

    /// Validate the URL, save the token, then `GET /v2/sync/status`; only 200 with `token.can_write` connects.
    func check() async {
        guard connect != .checking else { return }
        guard let settings = try? ServerSettings(serverText) else { connect = .invalidURL; return }
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { connect = .missingToken; return }
        connect = .checking
        do { try await deps.persist(settings, token) }
        catch is ServerSettings.SettingsError { connect = .invalidURL; return }
        catch SyncEngine.EngineError.busy { connect = .failed("Sync in progress · try again"); return }
        catch { connect = .failed("Couldn't save the token"); return }
        do {
            let status = try await deps.makeAPI(settings).syncStatus()
            guard let scope = status.token else { connect = .outdatedServer; return }
            connect = scope.canWrite ? .connected : .readOnly
            if scope.canWrite { self.settings = settings; deps.didConnect() }
        } catch let error as APIError {
            connect = .from(error)
        } catch {
            connect = .unreachable
        }
    }

    /// Continue checks first when the fields changed since the last check.
    func continueFromConnect() async {
        if connect != .connected { await check() }
        guard connect == .connected else { return }
        tokenText = ""
        connect = .connected
        step = .health
    }

    func allowHealth() async {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        await deps.authorizeHealth()
        isAuthorizing = false
        historyStartedAt = deps.now()
        step = .history
    }

    func observe(_ snapshot: SyncSnapshot) {
        self.snapshot = snapshot
        guard let type = snapshot.currentType, let date = snapshot.history.types[type]?.newestEnd.flatMap(APIDate.parse) else { return }
        oldestSeen = min(oldestSeen ?? date, date)
    }

    func progress() -> HistoryProgress {
        HistoryProgress.make(snapshot: snapshot, oldestSeen: oldestSeen, startedAt: historyStartedAt, now: deps.now(),
                             typeOrder: Self.typeOrder)
    }

    func goToTargets() { step = .targets }

    /// The exporter reads types in registry order, which is what the progress fallback counts against.
    static let typeOrder: [String] = HealthTypes().samples.map(\.identifier)

    func loadTargets() async {
        guard !targetsLoaded, let settings = settings ?? (try? ServerSettings(serverText)) else { return }
        do {
            let response = try await deps.makeAPI(settings).targets().value
            draft = TargetDraft(suggested: response.suggested)
            targetsError = nil
            targetsLoaded = true
        } catch let error as APIError {
            targetsError = error
        } catch {
            targetsError = .decoding("targets")
        }
    }

    func setTarget(_ field: TargetField, _ value: Double) { draft.set(field, value) }

    /// Sends the values shown through the outbox (so it survives offline), then leaves setup.
    func finish(done: () -> Void) async {
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        if targetsLoaded, let request = try? APIRequest.putTargets(draft.patch()) { await deps.send(request) }
        done()
    }
}

extension SetupStore {
    /// The app's wiring: AppModel for settings/HealthKit, Services for the outbox.
    static func live(model: AppModel) -> SetupStore {
        let deps = Dependencies(
            makeAPI: { VitalisAPI(settings: $0, cache: Services.shared.cache) },
            persist: { settings, token in try await model.saveSettings(url: settings.baseURL.absoluteString, token: token) },
            didConnect: { Services.shared.noteAuthOK() },
            authorizeHealth: { await model.authorize() },
            send: { _ = await Services.shared.send($0) })
        let saved = SettingsStore.baseURL
        let hasToken = ((try? TokenStore.read()) ?? nil)?.isEmpty == false
        let step = SetupStep.resume(hasServer: !saved.isEmpty, hasToken: hasToken,
                                    saved: UserDefaults.standard.object(forKey: SetupStep.savedKey) as? Int)
        return SetupStore(deps: deps, step: step, serverText: saved)
    }
}

extension SetupStep: Comparable {
    static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }
}
