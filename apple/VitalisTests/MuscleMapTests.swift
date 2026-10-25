import SwiftUI
import Testing
@testable import VitalisUI

@Suite struct MuscleMapTests {
    @Test func everyMuscleHasGeneratedPaths() {
        #expect(Muscle.allCases.count == 17)
        #expect(MuscleMapPaths.muscles.count == 17)
        for m in Muscle.allCases { #expect(!(MuscleMapPaths.muscles[m.rawValue] ?? []).isEmpty, "\(m.rawValue)") }
        #expect(MuscleMapPaths.base.count == 12)
    }

    @Test func generatedPathsStayInsideTheViewBox() {
        let box = MuscleMapPaths.viewBox.insetBy(dx: -0.5, dy: -0.5)
        #expect(box.minX == 19.5 && box.maxX == 1428.5 && box.minY == 149.5 && box.maxY == 1365.5)
        // Tight bounds: control points of the near-straight r=910 arc may sit outside.
        for (slug, ops) in MuscleMapPaths.muscles {
            let bounds = MuscleMap.path(ops).cgPath.boundingBoxOfPath
            #expect(!bounds.isEmpty)
            #expect(box.contains(bounds), "\(slug) \(bounds)")
        }
        // The source heads (base 0, 1, 8) rise to y 97 and are clipped flat by the viewBox, as in the frames.
        let headroom = CGRect(x: box.minX, y: 90, width: box.width, height: box.maxY - 90)
        for ops in MuscleMapPaths.base {
            #expect(headroom.contains(MuscleMap.path(ops).cgPath.boundingBoxOfPath))
        }
    }

    @Test func slugDictionaryMapsHyphenSlugsAndIgnoresUnknownKeys() {
        let heat = MuscleMap.heat(slugs: ["lower-back": 2, "middle back": 3, "chest": 4, "wings": 4])
        #expect(heat == [.lowerBack: 2, .middleBack: 3, .chest: 4])
        #expect(Muscle(rawValue: "lower-back") == .lowerBack)
    }

    @Test func accessibilitySummaryGroupsByHeatLevel() {
        let summary = MuscleMap.accessibilitySummary(heat: [.quadriceps: 1, .hamstrings: 1, .chest: 4, .lowerBack: 2, .neck: 0])
        // Spoken as load, not freshness (the map shows stress: grey for none, red for just trained).
        #expect(summary == "Recovered: hamstrings, quadriceps. Easing: lower back. Just trained: chest.")
        #expect(MuscleMap.accessibilitySummary(heat: [:]) == "No load.")
        #expect(MuscleMap.accessibilitySummary(heat: [.calves: 9]) == "Just trained: calves.")
    }

    @Test func catalogLightingPutsPrimaryAboveSecondary() {
        let heat = MuscleMap.catalogLighting(primary: [.chest, .triceps], secondary: [.shoulders, .triceps])
        #expect(heat == [.chest: 4, .triceps: 4, .shoulders: 3])
    }
}
