import SwiftUI

/// The type roles of spec 30. Each modifier rebuilds its font when Dynamic Type changes, since a CoreText font doesn't scale itself.
public enum VRole: Sendable {
    /// Archivo condensed caps (wdth 62, wght 800).
    case headline(CGFloat)
    /// Button label, same face as headline.
    case action(CGFloat)
    /// Archivo expanded light (wdth 125, wght 200).
    case number(CGFloat)
    /// Azeret Mono 500, uppercase, 0.12em.
    case label(CGFloat)
    /// Azeret Mono 400, 0.06em.
    case reading(CGFloat)
    /// Archivo wdth 100, wght 400, line height 1.45.
    case body(CGFloat)
    /// Archivo wdth 100, wght 600.
    case statusTime(CGFloat)

    var size: CGFloat {
        switch self { case .headline(let s), .action(let s), .number(let s), .label(let s), .reading(let s), .body(let s), .statusTime(let s): s }
    }

    func font(scale: CGFloat) -> Font {
        let s = size * scale
        switch self {
        case .headline, .action: return VFont.archivo(s, width: 62, weight: 800)
        case .number: return VFont.archivo(s, width: 125, weight: 200)
        case .label: return VFont.mono(s, weight: 500)
        case .reading: return VFont.mono(s, weight: 400)
        case .body: return VFont.archivo(s, width: 100, weight: 400)
        case .statusTime: return VFont.archivo(s, width: 100, weight: 600)
        }
    }

    func tracking(scale: CGFloat) -> CGFloat {
        let s = size * scale
        switch self {
        case .number: return s * (size >= 72 ? -0.05 : -0.04)
        case .label: return s * 0.12
        case .reading: return s * 0.06
        default: return 0
        }
    }

    /// Hero headlines and numbers stop growing at accessibility1; mono labels may grow without limit.
    var cap: DynamicTypeSize? {
        switch self { case .headline, .number, .action: .accessibility1; default: nil }
    }

    var uppercased: Bool {
        switch self { case .headline, .action, .label: true; default: false }
    }
}

struct VRoleModifier: ViewModifier {
    let role: VRole
    let color: Color?
    @Environment(\.dynamicTypeSize) private var dts

    func body(content: Content) -> some View {
        let scale = VScale.factor(dts, cap: role.cap)
        var view = AnyView(content.font(role.font(scale: scale)).tracking(role.tracking(scale: scale)))
        if role.uppercased { view = AnyView(view.textCase(.uppercase)) }
        if case .body(let s) = role { view = AnyView(view.lineSpacing(s * scale * 0.45)) }
        return view.foregroundStyle(color ?? defaultColor)
    }

    private var defaultColor: Color {
        switch role {
        case .label, .body: VColor.steel
        default: VColor.bone
        }
    }
}

public extension View {
    func vRole(_ role: VRole, color: Color? = nil) -> some View { modifier(VRoleModifier(role: role, color: color)) }
    func vHeadline(_ size: CGFloat, color: Color? = nil) -> some View { vRole(.headline(size), color: color) }
    func vAction(_ size: CGFloat = 20, color: Color? = nil) -> some View { vRole(.action(size), color: color) }
    func vNumber(_ size: CGFloat, color: Color? = nil) -> some View { vRole(.number(size), color: color) }
    func vLabel(_ size: VLabelSize = .standard, tint: VTint = .steel) -> some View { vRole(.label(size.points), color: tint.color) }
    func vReading(_ size: CGFloat = 12.5, tint: VTint = .bone) -> some View { vRole(.reading(size), color: tint.color) }
    func vBody(_ size: CGFloat = 14, color: Color? = nil) -> some View { vRole(.body(size), color: color) }
    func vStatusTime(_ size: CGFloat = 16) -> some View { vRole(.statusTime(size)) }
}

public enum VLabelSize: Sendable {
    case standard, small, custom(CGFloat)
    var points: CGFloat {
        switch self { case .standard: 11; case .small: 10; case .custom(let s): s }
    }
}

/// Multi-line condensed headline with the frames' 0.92 line height: SwiftUI can't set leading below the font's own,
/// so each line is its own Text pinned to a short frame.
public struct HeadlineLines: View {
    let lines: [String]
    let size: CGFloat
    let colors: [Color]
    @Environment(\.dynamicTypeSize) private var dts

    public init(_ lines: [String], size: CGFloat, colors: [Color] = []) {
        self.lines = lines; self.size = size; self.colors = colors
    }

    public var body: some View {
        let scale = VScale.factor(dts, cap: .accessibility1)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line).vHeadline(size, color: i < colors.count ? colors[i] : nil)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(height: size * scale * 0.92, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Balanced lines of at most `maxChars` where possible ("Train legs / hard today"); server headlines are ≤ 2 × 18.
    public static func split(_ text: String, maxChars: Int = 18) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard text.count > maxChars, words.count > 1 else { return [text] }
        var best: [String] = [text], bestLongest = Int.max
        for cut in 1..<words.count {
            let a = words[..<cut].joined(separator: " "), b = words[cut...].joined(separator: " ")
            let longest = max(a.count, b.count)
            if longest < bestLongest { best = [a, b]; bestLongest = longest }
        }
        return best
    }
}
