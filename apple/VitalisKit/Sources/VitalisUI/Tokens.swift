import SwiftUI

public extension Color {
    /// 0xRRGGBB; only VitalisUI defines colours, so app targets never hold a hex.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Vital line colours (spec 30). LOCKED values first; derived greys only for the roles named.
public enum VColor {
    public static let ground = Color(hex: 0x000000)
    public static let pulse = Color(hex: 0xFF4538)
    public static let bone = Color(hex: 0xF2EEE6)
    public static let steel = Color(hex: 0x8C8C8C)
    public static let rule = Color(hex: 0x1E1E1E)
    public static let good = Color(hex: 0x6FCF97)
    public static let watch = Color(hex: 0xE9B949)

    // 2e cards (Draft canvas SgbW4nfdaw): every card is a title, a dot-and-word status, a visual, then the number.
    public static let card = Color(hex: 0x161616)
    public static let cardRaised = Color(hex: 0x1E1E1E)
    public static let muted = Color(hex: 0xA8A8A8)
    public static let usual = Color(hex: 0xCFC9BF)
    public static let meterTrack = Color(hex: 0x2E2E2E)
    public static let hairline = Color(hex: 0x262626)
    /// One chart colour per tab, so each tab's centrepiece reads as its own; status dots keep good/watch everywhere.
    public static let sleepDeep = Color(hex: 0x5D63A8)
    public static let sleepCore = Color(hex: 0x6F8FC2)
    public static let sleepREM = Color(hex: 0x8DBFCB)
    public static let eat = Color(hex: 0xFF8A3D)
    public static let body = Color(hex: 0xA78BFA)

    public static let future = Color(hex: 0x333333)
    public static let track = Color(hex: 0x262626)
    public static let sheet = Color(hex: 0x0E0E0E)
    public static let toast = Color(hex: 0x121212)
    public static let barIdle = Color(hex: 0x3A3A3A)
    public static let disabled = Color(hex: 0x555555)
    public static let rawDot = Color(hex: 0x4A4A4A)
    public static let camera = Color(hex: 0x141414)
    public static let muscleBase = Color(hex: 0x272727)
    public static let tickMajor = Color(hex: 0x666666)

    /// Muscle heat 0–4 as load: grey for none, red as load rises. Server 1 is "recovered" (load < 0.5), so it shares 0's grey.
    public static func heat(_ level: Int) -> Color {
        switch level {
        case 2: return Color(hex: 0x8F352E)
        case 3: return Color(hex: 0xC63E34)
        case 4: return Color(hex: 0xFF4538)
        default: return Color(hex: 0x363636)
        }
    }
}

/// Semantic tints the server sends (`good` / `watch`) plus the plain roles a label can take.
public enum VTint: String, Sendable, Codable, CaseIterable {
    case steel, bone, pulse, good, watch

    public var color: Color {
        switch self {
        case .steel: VColor.steel
        case .bone: VColor.bone
        case .pulse: VColor.pulse
        case .good: VColor.good
        case .watch: VColor.watch
        }
    }

    /// Server tint string (`"good"`, `"watch"`, nil) mapped onto a fallback.
    public static func server(_ raw: String?, else fallback: VTint) -> VTint {
        raw.flatMap(VTint.init(rawValue:)) ?? fallback
    }
}

public enum VSpace {
    public static let gutter: CGFloat = 24
    public static let statusTop: CGFloat = 18
    public static let statusSide: CGFloat = 30
    public static let sectionTop: CGFloat = 16
    public static let sectionPad: CGFloat = 12
    public static let rowPad: CGFloat = 7
    public static let tabBarHeight: CGFloat = 83
    public static let buttonHeight: CGFloat = 52
    public static let buttonBottomAboveTabs: CGFloat = 17
    public static let sheetTop: CGFloat = 104
}

public enum VRadius {
    public static let button: CGFloat = 12
    public static let mini: CGFloat = 10
    public static let field: CGFloat = 8
    public static let sheet: CGFloat = 20
}

/// Settings → Acknowledgements (spec 30: OFL fonts, MIT muscle map).
public enum VAcknowledgements {
    public static let lines: [(title: String, detail: String)] = [
        ("Archivo", "SIL Open Font License 1.1 · Copyright 2020 The Archivo Project Authors"),
        ("Azeret Mono", "SIL Open Font License 1.1 · Copyright 2021 The Azeret Project Authors"),
        ("Muscle map", "react-native-body-highlighter · MIT License · Copyright (c) 2022 ELABBASSI Hicham"),
    ]
}
