import SwiftUI

/// The 17 muscles the server scores; raw values are the JSON / heat-object hyphen slugs.
public enum Muscle: String, CaseIterable, Sendable {
    case abdominals, abductors, adductors, biceps, calves, chest, forearms, glutes, hamstrings, lats
    case lowerBack = "lower-back"
    case middleBack = "middle-back"
    case neck, quadriceps, shoulders, traps, triceps

    var spokenName: String { rawValue.replacingOccurrences(of: "-", with: " ") }
    public var displayName: String { spokenName.capitalized }
}

/// Front + back anatomical figure lit by server heat 0–4 (spec 30 → MuscleMap). Size it by width.
public struct MuscleMap: SwiftUI.View {
    public enum View: Sendable, CaseIterable {
        case front, back, both

        /// Left edge and width of this view inside the 1408×1215 viewBox.
        var originX: CGFloat { self == .back ? 724 : 20 }
        var span: CGFloat { self == .both ? 1408 : 704 }
        var aspect: CGFloat { span / MuscleMapPaths.viewBox.height }
    }

    /// Spoken names for heat 0…4, matching the Train legend.
    nonisolated public static let levelNames = ["Not trained", "Fresh", "Recovering", "Partly loaded", "Loaded"]

    let heat: [Muscle: Int]
    let view: View
    let strokeWidth: CGFloat

    /// `strokeWidth` is in viewBox units (3 default, 4 on the Watch summary).
    public init(heat: [Muscle: Int], view: View = .both, strokeWidth: CGFloat = 3) {
        self.heat = heat
        self.view = view
        self.strokeWidth = strokeWidth
    }

    /// Server heat object keyed by slug; unknown keys are ignored and missing muscles are 0.
    public init(heat: [String: Int], view: View = .both, strokeWidth: CGFloat = 3) {
        self.init(heat: Self.heat(slugs: heat), view: view, strokeWidth: strokeWidth)
    }

    nonisolated static func heat(slugs: [String: Int]) -> [Muscle: Int] {
        // The server's exercise catalogue writes "lower back" with a space; accept both spellings.
        var out: [Muscle: Int] = [:]
        for (key, level) in slugs {
            if let m = Muscle(rawValue: key.replacingOccurrences(of: " ", with: "-")) { out[m] = level }
        }
        return out
    }

    nonisolated static func level(_ raw: Int?) -> Int { min(max(raw ?? 0, 0), 4) }

    public var body: some SwiftUI.View {
        Canvas { context, size in draw(in: &context, size: size) }
            .aspectRatio(view.aspect, contentMode: .fit)
            .accessibilityElement()
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(Self.accessibilitySummary(heat: heat))
    }

    // Paths are rebuilt per draw (~1,800 ops, well under a millisecond); Canvas only redraws when size or heat change.
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let box = MuscleMapPaths.viewBox
        let scale = min(size.width / view.span, size.height / box.height)
        let dx = (size.width - view.span * scale) / 2
        let transform = CGAffineTransform(translationX: dx, y: 0)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -view.originX, y: -box.minY)

        var outline = Path()
        // Fill everything first, then stroke once, so a neighbour's fill never covers half a seam.
        for ops in MuscleMapPaths.base {
            let p = Self.path(ops).applying(transform)
            context.fill(p, with: .color(VColor.muscleBase))
            outline.addPath(p)
        }
        for muscle in Muscle.allCases {
            guard let ops = MuscleMapPaths.muscles[muscle.rawValue] else { continue }
            let p = Self.path(ops).applying(transform)
            context.fill(p, with: .color(VColor.heat(Self.level(heat[muscle]))))
            outline.addPath(p)
        }
        context.stroke(outline, with: .color(VColor.ground),
                       style: StrokeStyle(lineWidth: max(strokeWidth * scale, 0.5), lineJoin: .round))
    }

    nonisolated static func path(_ ops: [MusclePathOp]) -> Path {
        var p = Path()
        for op in ops {
            switch op {
            case let .move(x, y): p.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): p.addLine(to: CGPoint(x: x, y: y))
            case let .quad(cx, cy, x, y): p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case let .cubic(c1x, c1y, c2x, c2y, x, y):
                p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    /// VoiceOver label, e.g. "Fresh: quadriceps, hamstrings. Loaded: chest."; untrained muscles are left out.
    nonisolated public static func accessibilitySummary(heat: [Muscle: Int]) -> String {
        let groups = (1...4).compactMap { level -> String? in
            let names = Muscle.allCases.filter { Self.level(heat[$0]) == level }.map(\.spokenName)
            return names.isEmpty ? nil : "\(levelNames[level]): \(names.joined(separator: ", "))."
        }
        return groups.isEmpty ? "\(levelNames[0])." : groups.joined(separator: " ")
    }

    /// The only client-side lighting (spec 30): an exercise's primary muscles at 4, secondary at 3.
    nonisolated public static func catalogLighting(primary: [Muscle], secondary: [Muscle]) -> [Muscle: Int] {
        var heat: [Muscle: Int] = [:]
        for m in secondary { heat[m] = 3 }
        for m in primary { heat[m] = 4 }
        return heat
    }
}

// MARK: - Previews (fixtures only)

extension VFixtures {
    /// Roughly the Home / Train frames: chest loaded, delts and triceps partly, back recovering, legs fresh.
    static let muscleHeat: [Muscle: Int] = [
        .chest: 4, .shoulders: 3, .triceps: 3, .biceps: 2, .forearms: 2, .lats: 2, .middleBack: 2, .traps: 2,
        .quadriceps: 1, .hamstrings: 1, .glutes: 1, .calves: 1, .adductors: 1, .abductors: 1,
    ]
}

#Preview("MuscleMap · heat levels") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0...4, id: \.self) { level in
                MonoLabel("\(level) · \(MuscleMap.levelNames[level])", size: .small)
                MuscleMap(heat: Dictionary(uniqueKeysWithValues: Muscle.allCases.map { ($0, level) }))
                    .frame(width: 290)
            }
        }
        .padding(VSpace.gutter)
    }
    .vScreen()
    .onAppear { VFont.register() }
}

#Preview("MuscleMap · views at 130 and 290") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([CGFloat(130), 290], id: \.self) { width in
                ForEach(MuscleMap.View.allCases, id: \.self) { view in
                    MonoLabel("\(view) · \(Int(width)) pt", size: .small)
                    MuscleMap(heat: VFixtures.muscleHeat, view: view).frame(width: width)
                }
            }
            MonoLabel("Catalog lighting · bench press", size: .small)
            MuscleMap(heat: MuscleMap.catalogLighting(primary: [.chest], secondary: [.shoulders, .triceps]), strokeWidth: 4)
                .frame(width: 145)
        }
        .padding(VSpace.gutter)
    }
    .vScreen()
    .onAppear { VFont.register() }
}
