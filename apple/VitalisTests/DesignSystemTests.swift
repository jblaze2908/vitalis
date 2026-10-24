import SwiftUI
import Testing
@testable import VitalisUI

@Suite struct DesignSystemTests {
    @Test func bothFontFamiliesRegister() {
        VFont.register()
        VFont.register() // second call is a no-op
        #expect(VFont.isAvailable(VFont.archivoFamily))
        #expect(VFont.isAvailable(VFont.monoFamily))
    }

    @Test func archivoWidthAxisChangesTheFace() {
        VFont.register()
        let condensed = VFont.ctFont(family: VFont.archivoFamily, size: 40, width: 62, weight: 800)
        let expanded = VFont.ctFont(family: VFont.archivoFamily, size: 40, width: 125, weight: 200)
        let glyphWidth = { (f: CTFont) -> Double in
            var chars: [UniChar] = Array("M".utf16), glyphs = [CGGlyph](repeating: 0, count: 1)
            CTFontGetGlyphsForCharacters(f, &chars, &glyphs, 1)
            return CTFontGetAdvancesForGlyphs(f, .horizontal, glyphs, nil, 1)
        }
        #expect(glyphWidth(expanded) > glyphWidth(condensed) * 1.3)
    }

    @Test func everyColourTokenResolves() {
        let tokens: [Color] = [VColor.ground, VColor.pulse, VColor.bone, VColor.steel, VColor.rule, VColor.good, VColor.watch,
                               VColor.future, VColor.track, VColor.sheet, VColor.toast, VColor.barIdle, VColor.disabled, VColor.rawDot,
                               VColor.camera, VColor.muscleBase, VColor.tickMajor] + (0...4).map(VColor.heat)
        let env = EnvironmentValues()
        for c in tokens { #expect(c.resolve(in: env).opacity == 1) }
        #expect(VColor.pulse.resolve(in: env).red > 0.99)
        for t in VTint.allCases { _ = t.color.resolve(in: env) }
        #expect(VTint.server("watch", else: .bone) == .watch)
        #expect(VTint.server(nil, else: .bone) == .bone)
    }

    @Test func headlineSplitKeepsLinesShort() {
        #expect(HeadlineLines.split("Train legs hard today") == ["Train legs", "hard today"])
        #expect(HeadlineLines.split("Done for today") == ["Done for today"])
    }
}
