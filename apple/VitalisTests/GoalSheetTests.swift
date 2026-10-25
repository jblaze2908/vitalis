import Foundation
import Testing
import VitalisKit
@testable import Vitalis

@MainActor @Suite struct GoalSheetTests {
    func plan(_ json: String) throws -> TargetsResponse.Plan {
        try APICoding.decoder().decode(TargetsResponse.Plan.self, from: Data(json.utf8))
    }

    @Test func loseFromWatchBurnExplainsEveryStep() throws {
        let p = try plan(#"{"goal":"lose","goal_weight_kg":80,"trend_kg":91.9,"rate_kg_week":-0.46,"maintenance_kcal":2550,"kcal":2050,"kcal_mode":"adaptive","basis":"watch","reached":false}"#)
        #expect(GoalSheet.lines(p) == [
            "Maintenance 2,550 kcal, from your Watch's resting + active energy over 28 days",
            "−506 kcal a day to lose 0.46 kg a week",
            "91.9 → 80.0 kg in about 26 weeks",
            "Adjusts weekly once you've logged 14 days of food and 8 weigh-ins",
        ])
    }

    @Test func maintainAndReachedHoldSteady() throws {
        let m = try plan(#"{"goal":"maintain","goal_weight_kg":null,"trend_kg":70,"rate_kg_week":0,"maintenance_kcal":2100,"kcal":2100,"kcal_mode":"adaptive","basis":"adaptive","reached":false}"#)
        #expect(GoalSheet.lines(m) == ["Maintenance 2,100 kcal, from the food and weight you've logged", "No deficit or surplus: maintain"])
        let r = try plan(#"{"goal":"lose","goal_weight_kg":70,"trend_kg":70.3,"rate_kg_week":0,"maintenance_kcal":2100,"kcal":2100,"kcal_mode":"adaptive","basis":"estimate","reached":true}"#)
        #expect(GoalSheet.lines(r).contains("You're at your target weight, so it holds steady"))
    }
}
