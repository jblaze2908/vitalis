import Foundation
import Testing
import VitalisUI
@testable import Vitalis

@Suite struct DeepLinkTests {
    @Test(arguments: [
        ("vitalis://today", Route.tab(.today)), ("vitalis://sleep", .tab(.sleep)), ("vitalis://body", .tab(.body)),
        ("vitalis://train", .tab(.train)), ("vitalis://eat", .tab(.eat)), ("vitalis://digest", .digest),
        ("vitalis://eat/add?slot=lunch", .eatAdd(slot: "lunch")), ("vitalis://eat/add", .eatAdd(slot: nil)),
        ("vitalis://eat/add?slot=brunch", .eatAdd(slot: nil)), ("vitalis://workout/start", .workoutStart),
        ("vitalis://settings", .settings), ("vitalis://settings/sync", .settingsSync), ("VITALIS://Today", .tab(.today)),
    ])
    func parses(_ link: String, _ route: Route) {
        #expect(DeepLinks.parse(URL(string: link)!) == route)
    }

    @Test(arguments: ["vitalis://nowhere", "https://today", "vitalis://eat/remove", "vitalis://"])
    func ignoresUnknown(_ link: String) {
        #expect(DeepLinks.parse(URL(string: link)!) == nil)
    }

    @MainActor @Test func routerOpensDestinations() {
        let r = Router()
        r.open(URL(string: "vitalis://eat/add?slot=dinner")!)
        #expect(r.tab == .eat); #expect(r.sheet == .quickAdd(slot: "dinner"))
        r.open(.settingsSync)
        #expect(r.showsSettings); #expect(r.settingsPath == [.sync]); #expect(r.sheet == nil)
        r.open(.digest)
        #expect(r.tab == .today); #expect(r.showsDigest); #expect(!r.showsSettings)
        r.open(.workoutStart)
        #expect(r.tab == .train); #expect(r.sheet == .workoutStart); #expect(!r.showsDigest)
    }
}
