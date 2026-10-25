import Foundation

public enum APIError: Error, Sendable, Equatable {
    case unauthorized, scope, notFound
    case conflict(String), invalid(String)
    case rateLimited, unavailable
    case server(Int)
    case transport(URLError)
    case decoding(String)

    /// From the status and the `{error, code}` body; falls back to the status when the body isn't ours (e.g. a proxy page).
    public static func from(status: Int, body: Data) -> APIError {
        let parsed = try? JSONDecoder().decode(APIErrorBody.self, from: body)
        let message = parsed?.error ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch parsed?.code {
        case "unauthorized": return .unauthorized
        case "scope": return .scope
        case "not_found": return .notFound
        case "conflict": return .conflict(message)
        case "invalid", "bad_request", "too_large": return .invalid(message)
        case "rate_limited": return .rateLimited
        case "unavailable": return .unavailable
        default: break
        }
        switch status {
        case 401: return .unauthorized
        case 403: return .scope
        case 404: return .notFound
        case 409: return .conflict(message)
        case 400, 413, 422: return .invalid(message)
        case 429: return .rateLimited
        case 503: return .unavailable
        default: return .server(status)
        }
    }
}

/// One HTTP call, storable in the Outbox. `path` is percent-encoded and relative to the server base URL.
public struct APIRequest: Codable, Sendable, Equatable {
    public let method: String
    public let path: String
    public let body: Data?
    public init(method: String, path: String, body: Data? = nil) {
        self.method = method; self.path = path; self.body = body
    }
    static func json<B: Encodable>(_ method: String, _ path: String, _ body: B) throws -> APIRequest {
        APIRequest(method: method, path: path, body: try APICoding.encoder().encode(body))
    }
    private static func seg(_ raw: String) -> String { HTTPCore.pathSegment(raw) }

    public static func putTargets(_ patch: TargetsPatch) throws -> APIRequest { try json("PUT", "v2/targets", patch) }
    public static func postWeight(_ entry: WeightEntry) throws -> APIRequest { try json("POST", "v2/weight", entry) }
    public static func putSplit(id: String, _ split: SplitPut) throws -> APIRequest { try json("PUT", "v2/splits/\(seg(id))", split) }
    public static func deleteSplit(id: String) -> APIRequest { APIRequest(method: "DELETE", path: "v2/splits/\(seg(id))") }
    public static func deleteWeight(id: String) -> APIRequest { APIRequest(method: "DELETE", path: "v2/weight/\(seg(id))") }
    public static func createExercise(_ exercise: NewExercise) throws -> APIRequest { try json("POST", "v2/exercises", exercise) }
    public static func postWorkout(_ workout: WorkoutUpsert) throws -> APIRequest { try json("POST", "v2/workouts", workout) }
    public static func postFoodEntries(_ entries: [FoodEntry]) throws -> APIRequest {
        try json("POST", "v2/food/entries", FoodEntriesRequest(entries: entries))
    }
    public static func deleteFoodEntry(id: String) -> APIRequest { APIRequest(method: "DELETE", path: "v2/food/entries/\(seg(id))") }
    public static func deleteMeal(mealId: String) -> APIRequest { APIRequest(method: "DELETE", path: "v2/food/meals/\(seg(mealId))") }
    public static func postSavedMeal(_ meal: SavedMeal) throws -> APIRequest { try json("POST", "v2/food/saved", meal) }
    public static func deleteSavedMeal(id: String) -> APIRequest { APIRequest(method: "DELETE", path: "v2/food/saved/\(seg(id))") }
    public static func putBarcode(code: String, item: BarcodeItem) throws -> APIRequest {
        try json("PUT", "v2/food/barcode/\(seg(code))", BarcodePut(item: item))
    }
    public static func describe(_ request: DescribeRequest) throws -> APIRequest { try json("POST", "v2/food/describe", request) }
}

/// A decoded read plus where it came from; stores show `OFFLINE · UPDATED HH:MM` from `fetchedAt`.
public struct APIResponse<Value: Sendable>: Sendable {
    public enum Source: Sendable, Equatable {
        /// 200 from the server.
        case network
        /// 304: the cached body is current.
        case notModified
        /// Read from the cache without contacting the server (`VitalisAPI.cached`).
        case cache
    }
    public let value: Value
    public let source: Source
    public let fetchedAt: Date
    public let etag: String?
    public var fromCache: Bool { source != .network }
}

/// Sends an `APIRequest` and returns the raw status/body; the Outbox depends only on this.
public protocol OutboxTransport: Sendable {
    func perform(_ request: APIRequest) async throws -> (status: Int, body: Data)
}

/// Typed client for every route in 10 §9. Reads revalidate through `ResponseCache`; writes return the server's body.
public struct VitalisAPI: OutboxTransport {
    private let core: HTTPCore
    public let cache: ResponseCache?
    private let now: @Sendable () -> Date

    public init(baseURL: URL, cache: ResponseCache?, token: @escaping HTTPCore.TokenProvider = { try TokenStore.read() },
                protocolClasses: [AnyClass] = [], now: @escaping @Sendable () -> Date = { Date() }) {
        core = HTTPCore(baseURL: baseURL, token: token, protocolClasses: protocolClasses)
        self.cache = cache
        self.now = now
    }

    public init(settings: ServerSettings, cache: ResponseCache?) {
        self.init(baseURL: settings.baseURL, cache: cache)
    }

    // MARK: Reads

    /// Setup must see the live token state, so this read bypasses the cache.
    public func syncStatus() async throws -> SyncStatus {
        try await get(SyncStatus.self, "v2/sync/status", cached: false).value
    }
    public func targets() async throws -> APIResponse<TargetsResponse> { try await get(TargetsResponse.self, "v2/targets") }
    public func splits() async throws -> APIResponse<SplitsResponse> { try await get(SplitsResponse.self, "v2/splits") }
    public func today(date: String? = nil) async throws -> APIResponse<TodayResponse> {
        try await get(TodayResponse.self, "v2/today", query: Self.query(["date": date]))
    }
    public func digest(date: String? = nil) async throws -> APIResponse<DigestResponse> {
        try await get(DigestResponse.self, "v2/digest", query: Self.query(["date": date]))
    }
    public func sleep(date: String? = nil) async throws -> APIResponse<SleepResponse> {
        try await get(SleepResponse.self, "v2/sleep", query: Self.query(["date": date]))
    }
    public func sleepWeek(end: String? = nil) async throws -> APIResponse<SleepWeekResponse> {
        try await get(SleepWeekResponse.self, "v2/sleep/week", query: Self.query(["end": end]))
    }

    /// `month` = `YYYY-MM`; nil = this month.
    public func sleepMonth(month: String? = nil) async throws -> APIResponse<SleepMonthResponse> {
        try await get(SleepMonthResponse.self, "v2/sleep/month", query: Self.query(["month": month]))
    }
    public func body(date: String? = nil) async throws -> APIResponse<BodyResponse> {
        try await get(BodyResponse.self, "v2/body", query: Self.query(["date": date]))
    }
    public func training(week: String? = nil) async throws -> APIResponse<TrainingResponse> {
        try await get(TrainingResponse.self, "v2/training", query: Self.query(["week": week]))
    }
    public func sessions(before: String? = nil, limit: Int? = nil) async throws -> APIResponse<SessionsPage> {
        try await get(SessionsPage.self, "v2/training/sessions", query: Self.query(["before": before, "limit": limit.map(String.init)]))
    }
    public func session(id: String) async throws -> APIResponse<SessionDetail> {
        try await get(SessionDetail.self, "v2/training/sessions/\(HTTPCore.pathSegment(id))")
    }
    public func exercises(since: String? = nil, q: String? = nil) async throws -> APIResponse<ExerciseList> {
        try await get(ExerciseList.self, "v2/exercises", query: Self.query(["since": since, "q": q]))
    }
    public func exercise(id: String) async throws -> APIResponse<ExerciseDetail> {
        try await get(ExerciseDetail.self, "v2/exercises/\(HTTPCore.pathSegment(id))")
    }
    public func foodDay(date: String? = nil) async throws -> APIResponse<FoodDay> {
        try await get(FoodDay.self, "v2/food/day", query: Self.query(["date": date]))
    }
    public func foodQuick(slot: String? = nil) async throws -> APIResponse<FoodQuick> {
        try await get(FoodQuick.self, "v2/food/quick", query: Self.query(["slot": slot]))
    }
    /// Search-as-you-type results are not worth a cache file each.
    public func foodSearch(q: String, page: Int? = nil) async throws -> APIResponse<FoodSearchResponse> {
        try await get(FoodSearchResponse.self, "v2/food/search", query: Self.query(["q": q, "page": page.map(String.init)]), cached: false)
    }
    public func barcode(code: String) async throws -> APIResponse<BarcodeResponse> {
        try await get(BarcodeResponse.self, "v2/food/barcode/\(HTTPCore.pathSegment(code))")
    }

    // MARK: Writes (direct; durable writes go through `Outbox` with the matching `APIRequest`)

    public func putTargets(_ patch: TargetsPatch) async throws -> TargetsResponse {
        try await send(.putTargets(patch), as: TargetsResponse.self)
    }
    public func putSplit(id: String, _ split: SplitPut) async throws -> SplitsResponse {
        try await send(.putSplit(id: id, split), as: SplitsResponse.self)
    }
    public func deleteSplit(id: String) async throws -> SplitsResponse {
        try await send(.deleteSplit(id: id), as: SplitsResponse.self)
    }
    public func postWeight(_ entry: WeightEntry) async throws -> WeightPostResponse {
        try await send(.postWeight(entry), as: WeightPostResponse.self)
    }
    public func deleteWeight(id: String) async throws -> WeightDeleteResponse {
        try await send(.deleteWeight(id: id), as: WeightDeleteResponse.self)
    }
    public func createExercise(_ exercise: NewExercise) async throws -> ExerciseCreated {
        try await send(.createExercise(exercise), as: ExerciseCreated.self)
    }
    public func postWorkout(_ workout: WorkoutUpsert) async throws -> WorkoutPostResponse {
        try await send(.postWorkout(workout), as: WorkoutPostResponse.self)
    }
    public func postFoodEntries(_ entries: [FoodEntry]) async throws -> FoodEntriesResponse {
        try await send(.postFoodEntries(entries), as: FoodEntriesResponse.self)
    }
    public func deleteFoodEntry(id: String) async throws -> FoodDeleteResponse {
        try await send(.deleteFoodEntry(id: id), as: FoodDeleteResponse.self)
    }
    public func deleteMeal(mealId: String) async throws -> FoodDeleteResponse {
        try await send(.deleteMeal(mealId: mealId), as: FoodDeleteResponse.self)
    }
    public func postSavedMeal(_ meal: SavedMeal) async throws -> SavedMealPostResponse {
        try await send(.postSavedMeal(meal), as: SavedMealPostResponse.self)
    }
    public func deleteSavedMeal(id: String) async throws -> SavedMealsResponse {
        try await send(.deleteSavedMeal(id: id), as: SavedMealsResponse.self)
    }
    public func putBarcode(code: String, item: BarcodeItem) async throws -> BarcodeResponse {
        try await send(.putBarcode(code: code, item: item), as: BarcodeResponse.self)
    }
    /// Not queued: nothing is stored server-side, and 503 means Describe is off.
    public func describe(_ request: DescribeRequest) async throws -> DescribeResponse {
        try await send(.describe(request), as: DescribeResponse.self)
    }

    // MARK: Cache access for stores

    /// The last cached body for a read, for offline rendering after a failed refresh.
    public func cached<T: Decodable & Sendable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async -> APIResponse<T>? {
        guard let cache, let entry = await cache.entry(path: path, query: query),
              let value = try? APICoding.decoder().decode(T.self, from: entry.body) else { return nil }
        return APIResponse(value: value, source: .cache, fetchedAt: entry.fetchedAt, etag: entry.etag)
    }

    // MARK: Core

    public func perform(_ request: APIRequest) async throws -> (status: Int, body: Data) {
        let result = try await core.send(method: request.method, path: request.path, body: request.body)
        return (result.status, result.data)
    }

    /// Builds a query from non-nil values, in a stable order.
    public static func query(_ values: KeyValuePairs<String, String?>) -> [URLQueryItem] {
        values.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    }

    public func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [],
                                             cached useCache: Bool = true) async throws -> APIResponse<T> {
        let cache = useCache ? self.cache : nil
        let entry = await cache?.entry(path: path, query: query)
        var headers: [String: String] = [:]
        if let etag = entry?.etag { headers["If-None-Match"] = etag }
        let result: (status: Int, data: Data, response: HTTPURLResponse)
        do { result = try await core.send(method: "GET", path: path, query: query, headers: headers) }
        catch { throw Self.map(error) }

        if result.status == 304, let entry, let cache {
            let touched = (try? await cache.touch(entry, at: now())) ?? entry
            return APIResponse(value: try Self.decode(T.self, touched.body), source: .notModified,
                               fetchedAt: touched.fetchedAt, etag: touched.etag)
        }
        guard (200..<300).contains(result.status) else { throw APIError.from(status: result.status, body: result.data) }
        let value = try Self.decode(T.self, result.data)
        let etag = result.response.value(forHTTPHeaderField: "ETag")
        let fetchedAt = now()
        // A cache write failure (e.g. protected data unavailable) must not fail a good read.
        _ = try? await cache?.store(path: path, query: query, etag: etag, body: result.data, fetchedAt: fetchedAt)
        return APIResponse(value: value, source: .network, fetchedAt: fetchedAt, etag: etag)
    }

    public func send<T: Decodable>(_ request: APIRequest, as type: T.Type) async throws -> T {
        let result: (status: Int, body: Data)
        do { result = try await perform(request) } catch { throw Self.map(error) }
        guard (200..<300).contains(result.status) else { throw APIError.from(status: result.status, body: result.body) }
        return try Self.decode(T.self, result.body)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try APICoding.decoder().decode(T.self, from: data) }
        catch { throw APIError.decoding("\(T.self): \(Self.describe(error))") }
    }

    static func map(_ error: any Error) -> any Error {
        switch error {
        case let error as APIError: return error
        case let error as URLError: return APIError.transport(error)
        case HTTPCore.Failure.missingToken: return APIError.unauthorized
        case HTTPCore.Failure.invalidResponse: return APIError.transport(URLError(.badServerResponse))
        default: return error
        }
    }

    /// Coding path and reason only; never echo response values into logs.
    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: type(of: error)) }
        func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let c): return "missing \(path(c)).\(key.stringValue)"
        case .valueNotFound(_, let c): return "null at \(path(c))"
        case .typeMismatch(_, let c): return "type mismatch at \(path(c))"
        case .dataCorrupted(let c): return "corrupt at \(path(c))"
        @unknown default: return "decoding failed"
        }
    }
}
