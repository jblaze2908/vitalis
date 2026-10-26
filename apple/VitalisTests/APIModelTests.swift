import Foundation
import Testing
import VitalisKit

@Suite struct APIModelTests {
    /// Fixture file → model. Most come from the implemented server; search, barcode, cardio, saved,
    /// exercise-created and weight-delete are written from spec 10 / the server source (synthetic values).
    static var models: [String: any Decodable.Type] { [
        "sync-status": SyncStatus.self, "targets": TargetsResponse.self, "targets-put": TargetsResponse.self,
        "today": TodayResponse.self, "digest": DigestResponse.self, "sleep": SleepResponse.self,
        "sleep-week": SleepWeekResponse.self, "sleep-month": SleepMonthResponse.self, "body": BodyResponse.self, "weight-post": WeightPostResponse.self,
        "weight-delete": WeightDeleteResponse.self, "training": TrainingResponse.self, "training-sessions": SessionsPage.self,
        "training-session": SessionDetail.self, "training-session-cardio": SessionDetail.self,
        "exercises-search": ExerciseList.self, "exercise": ExerciseDetail.self, "exercise-created": ExerciseCreated.self,
        "workouts-post": WorkoutPostResponse.self, "food-day": FoodDay.self, "food-quick": FoodQuick.self,
        "food-entries-post": FoodEntriesResponse.self, "food-meal-delete": FoodDeleteResponse.self,
        "saved-post": SavedMealPostResponse.self, "food-search": FoodSearchResponse.self,
        "food-search-busy": FoodSearchResponse.self, "barcode": BarcodeResponse.self,
        "barcode-not-found": BarcodeResponse.self, "describe": DescribeResponse.self,
        "error-invalid": APIErrorBody.self, "error-unauthorized": APIErrorBody.self,
        "heart": HeartDay.self, "metrics": MetricsOverview.self, "metric": MetricHistory.self,
        "training-exercises": PerformedExercises.self, "training-session-hr": SessionDetail.self, "exercise-history": ExerciseDetail.self,
    ] }

    @Test(arguments: models.keys.sorted())
    func fixtureDecodes(_ name: String) throws {
        let type = try #require(Self.models[name])
        _ = try APICoding.decoder().decode(type, from: Fixture.data(name))
    }

    @Test func everyBundledFixtureHasAModel() {
        let bundled = Set(Fixture.apiNames)
        #expect(bundled.count >= Self.models.count)
        #expect(bundled.subtracting(Self.models.keys).isEmpty, "fixture without a model: \(bundled.subtracting(Self.models.keys))")
        #expect(Set(Self.models.keys).subtracting(bundled).isEmpty, "model without a bundled fixture")
    }

    @Test func todaySpotChecks() throws {
        let today = try Fixture.decode(TodayResponse.self, "today")
        #expect(today.day == "2026-10-24")
        #expect(today.recovery.score == 78 && today.recovery.status == "ok")
        #expect(today.recovery.parts?.hrv?.usualRange == [47.5, 47.5])
        #expect(today.recovery.parts?.restingHr?.tint == "watch")
        #expect(today.verdict.action?.kind == "bed_reminder")
        #expect(today.training.heat.count == 17)
        #expect(today.training.heat["lower-back"] == 1)
        #expect(today.training.splits ?? [] == [])
        #expect(today.fuel.nextLabel == "LOG BREAKFAST")
        let pulse = try #require(today.pulse)
        #expect(APIDate.clockText(pulse.now) == "22:14")
        let x = try #require(APIDate.fraction(pulse.now, start: pulse.window.start, end: pulse.window.end))
        #expect(x > 0.9 && x < 1)
    }

    @Test func digestRowsWithoutDelta() throws {
        let digest = try Fixture.decode(DigestResponse.self, "digest")
        #expect(digest.headline == ["You slept well.", "Ready to push."])
        let rows = try #require(digest.sleep?.rows)
        #expect(rows.first?.delta == "+0M")
        #expect(rows.contains { $0.delta == nil })
        #expect(digest.yesterday?.workout == nil)
        #expect(digest.plan.first?.primary == true)
    }

    @Test func trainingAndExerciseSpotChecks() throws {
        let training = try Fixture.decode(TrainingResponse.self, "training")
        #expect(training.weeklySets?.byMuscle["middle-back"] == 6)
        #expect(training.muscles.count == 17)
        #expect(!training.empty)
        let detail = try Fixture.decode(ExerciseDetail.self, "exercise")
        #expect(detail.e1rm?.change8wKg == -15.2)
        #expect(detail.records?.bestE1rmKg == 98.8)
        #expect(detail.next?.weightKg == 64.5)
        #expect(detail.exercise.aliases == nil)
        let post = try Fixture.decode(WorkoutPostResponse.self, "workouts-post")
        #expect(post.prs.first?.e1rmKgEstimate == 144)
        #expect(post.session.exercises?.first?.sets.first?.kind == "warmup")
        let cardio = try Fixture.decode(SessionDetail.self, "training-session-cardio")
        #expect(cardio.isCardio && cardio.hrAvg == 148 && cardio.name == "Running" && cardio.exercises == nil)
        let page = try Fixture.decode(SessionsPage.self, "training-sessions")
        #expect(page.next != nil)
    }

    @Test func syncTargetsAndBody() throws {
        let status = try Fixture.decode(SyncStatus.self, "sync-status")
        #expect(status.token?.canWrite == true)
        #expect(status.batches.first?.counts?.dailyStats == 0)
        let targets = try Fixture.decode(TargetsResponse.self, "targets")
        #expect(targets.values.steps == nil && targets.isSet?.steps == false)
        #expect(targets.effective.bedBy == "23:50")
        #expect(targets.suggested?.goalWeightKg?.value == nil)
        let put = try Fixture.decode(TargetsResponse.self, "targets-put")
        #expect(put.values.steps == 9000 && put.isSet?.steps == true)
        let body = try Fixture.decode(BodyResponse.self, "body")
        #expect(body.weight.series.count == 30)
        #expect(body.weight.latest?.at == nil)
        #expect(body.activity.exerciseMin == nil)
    }

    @Test func foodSpotChecks() throws {
        let day = try Fixture.decode(FoodDay.self, "food-day")
        #expect(day.kcalTarget == 2300 && day.macros.carbs.targetG == nil)
        #expect(day.usualNext?.mealSignature == "meal 0")
        let posted = try Fixture.decode(FoodEntriesResponse.self, "food-entries-post")
        #expect(posted.day.over && posted.day.kcalLeft == -310)
        #expect(posted.day.meals.contains { $0.justAdded })
        let search = try Fixture.decode(FoodSearchResponse.self, "food-search")
        #expect(search.results[1].per100g?.carbsG == 4.5)
        #expect(search.nextPage == 2)
        let busy = try Fixture.decode(FoodSearchResponse.self, "food-search-busy")
        #expect(busy.remote == "rate_limited" && busy.results[0].serving.grams == nil)
        let found = try Fixture.decode(BarcodeResponse.self, "barcode")
        #expect(found.item?.per100g?.kcal == 72 && found.item?.serving.grams == 200)
        let missing = try Fixture.decode(BarcodeResponse.self, "barcode-not-found")
        #expect(!missing.found && missing.item == nil)
        let describe = try Fixture.decode(DescribeResponse.self, "describe")
        #expect(describe.items.first?.portionOptions.first?.factor == 0.5)
    }

    @Test func errorBodiesMapToAPIError() throws {
        #expect(APIError.from(status: 422, body: try Fixture.data("error-invalid"))
                == .invalid("steps: Too small: expected number to be >=1000"))
        #expect(APIError.from(status: 401, body: try Fixture.data("error-unauthorized")) == .unauthorized)
        #expect(APIError.from(status: 409, body: Data(#"{"error":"set s1 is in another session","code":"conflict"}"#.utf8))
                == .conflict("set s1 is in another session"))
        #expect(APIError.from(status: 503, body: Data(#"{"error":"Describe isn't set up","code":"unavailable"}"#.utf8)) == .unavailable)
        #expect(APIError.from(status: 502, body: Data("<html>bad gateway</html>".utf8)) == .server(502))
        #expect(APIError.from(status: 403, body: Data()) == .scope)
        #expect(APIError.from(status: 429, body: Data()) == .rateLimited)
    }

    @Test func datesParseWithOffsets() throws {
        let a = try #require(APIDate.parse("2026-10-24T09:39:00+05:30"))
        let b = try #require(APIDate.parse("2026-10-24T04:09:00.000Z"))
        #expect(a == b)
        #expect(APIDate.offsetSeconds("2026-10-24T09:39:00+05:30") == 19_800)
        #expect(APIDate.clockText("2026-10-24T09:39:00+05:30") == "09:39")
        #expect(APIDate.parse("not a date") == nil)
    }

    // MARK: Request bodies

    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try APICoding.encoder().encode(value), as: UTF8.self)
    }

    @Test func targetsPatchSendsExplicitNull() throws {
        var patch = TargetsPatch()
        patch.steps = .set(9000)
        patch.goalWeightKg = .clear
        #expect(try json(patch) == #"{"goal_weight_kg":null,"steps":9000}"#)
        #expect(try json(TargetsPatch()) == "{}")
    }

    @Test func writeBodiesUseServerKeys() throws {
        let workout = WorkoutUpsert(
            session: .init(clientId: "S1", template: "legs", source: "phone", startedAt: "2026-10-24T18:40:00+05:30", tzOffsetMin: 330),
            sets: [.init(id: "A1", exercise: "barbell-squat", kind: "normal", weightKg: 100, reps: 6,
                         targetWeightKg: 100, performedAt: "2026-10-24T18:47:30+05:30"), .deletion("A0")])
        let text = try json(workout)
        #expect(text.contains(#""client_id":"S1""#) && text.contains(#""tz_offset_min":330"#))
        #expect(text.contains(#""target_weight_kg":100"#) && text.contains(#""performed_at":"#))
        #expect(text.contains(#"{"deleted":true,"id":"A0"}"#))
        #expect(!text.contains("null"), "strict server schemas: nil fields must be omitted")

        let entry = FoodEntry(id: "E1", mealId: "M1", slot: "lunch", eatenAt: "2026-10-24T13:05:00+05:30", name: "Paneer tikka",
                              kcal: 420, proteinG: 28, source: "describe", estimate: true)
        let entryText = try json(FoodEntriesRequest(entries: [entry]))
        #expect(entryText.contains(#""meal_id":"M1""#) && entryText.contains(#""protein_g":28"#) && entryText.contains(#""eaten_at":"#))

        let barcode = BarcodePut(item: BarcodeItem(name: "Bar", serving: Serving(label: "1 BAR", grams: 40, kcal: 190, proteinG: 10, carbsG: 20, fatG: 7),
                                                   per100g: Nutrients(kcal: 475, proteinG: 25, carbsG: 50, fatG: 17.5)))
        let barcodeText = try json(barcode)
        #expect(barcodeText.contains(#""per_100g":{"#) && barcodeText.contains(#""protein_g":10"#))

        #expect(try json(WeightEntry(id: "W1", kg: 76.6, measuredAt: "2026-10-24T07:05:00+05:30"))
                == #"{"id":"W1","kg":76.6,"measured_at":"2026-10-24T07:05:00+05:30"}"#)
    }

    @Test func requestPathsEncodeIds() throws {
        #expect(APIRequest.deleteMeal(mealId: "M1").path == "v2/food/meals/M1")
        #expect(APIRequest.deleteFoodEntry(id: "a/b c").path == "v2/food/entries/a%2Fb%20c")
        #expect(try APIRequest.putBarcode(code: "8901063010031", item: BarcodeItem(name: "x", serving: Serving(label: "1", grams: nil, kcal: 1, proteinG: nil, carbsG: nil, fatG: nil))).method == "PUT")
    }
}
