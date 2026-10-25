import SwiftUI

// 2e card language (Draft canvas SgbW4nfdaw, "2e" rows): a #161616 card holds a title, a dot-and-one-word status at the
// top right, one visual, then the figure. Status colour means the same thing on every card.

/// What a status dot means: good = on track or better, watch = off your usual, usual = steady, load = muscle load.
public enum VTone: Sendable {
    case good, watch, usual, load, quiet

    public var color: Color {
        switch self {
        case .good: VColor.good
        case .watch: VColor.watch
        case .usual: VColor.usual
        case .load: VColor.pulse
        case .quiet: VColor.steel
        }
    }

    /// Server `tint` (`good` / `watch` / nil) as a tone; nil means within your usual.
    public static func server(_ tint: String?) -> VTone {
        switch tint { case "good": .good; case "watch": .watch; default: .usual }
    }
}

public struct VCard<Content: View>: View {
    let padding: EdgeInsets
    let content: Content
    public init(padding: EdgeInsets = EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14), @ViewBuilder content: () -> Content) {
        self.padding = padding; self.content = content()
    }
    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(VColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

public struct StatusWord: View {
    let text: String
    let tone: VTone
    public init(_ text: String, tone: VTone) { self.text = text; self.tone = tone }
    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone.color).frame(width: 8, height: 8)
            Text(text).vUI(13, weight: 500, color: VColor.muted).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Title on the left, optional status on the right.
public struct CardHeader: View {
    let title: String
    let status: (String, VTone)?
    public init(_ title: String, status: (String, VTone)? = nil) { self.title = title; self.status = status }
    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).vUI(14, weight: 600).lineLimit(1)
            Spacer(minLength: 4)
            if let status { StatusWord(status.0, tone: status.1) }
        }
    }
}

/// A figure with a small mono unit after it ("71 /100", "6:28 OF 7:00").
public struct Figure: View {
    let value: String
    let unit: String?
    let size: CGFloat
    let color: Color?
    public init(_ value: String, unit: String? = nil, size: CGFloat = 28, color: Color? = nil) {
        self.value = value; self.unit = unit; self.size = size; self.color = color
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).vFigure(size, color: color).lineLimit(1).minimumScaleFactor(0.7)
            if let unit { Text(unit).vLabel(.standard, tint: .steel).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A 6 pt meter: track, fill, and an optional marker with a mono caption above it ("USUAL 1,450", "NEED 7:00").
public struct Meter: View {
    let fraction: Double
    let marker: Double?
    let caption: String?
    let leading: String?
    let fill: Color
    public init(fraction: Double, marker: Double? = nil, caption: String? = nil, leading: String? = nil, fill: Color = VColor.bone) {
        self.fraction = fraction; self.marker = marker; self.caption = caption; self.leading = leading; self.fill = fill
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if caption != nil || leading != nil {
                HStack {
                    if let leading { Text(leading).vLabel(.standard, tint: .bone) }
                    Spacer(minLength: 0)
                    if let caption { Text(caption).vLabel(.standard, tint: .steel) }
                }
            }
            GeometryReader { g in
                let w = g.size.width, clamp = { (v: Double) in min(max(v, 0), 1) }
                ZStack(alignment: .leading) {
                    Capsule().fill(VColor.meterTrack)
                    Capsule().fill(fill).frame(width: max(6, w * clamp(fraction)))
                    if let marker {
                        Rectangle().fill(VColor.muted).frame(width: 1.5, height: 14).offset(x: w * clamp(marker) - 0.75)
                    }
                }
            }
            .frame(height: 6)
        }
        .accessibilityHidden(true)
    }
}

/// Seven daily values as a line, the usual range as two dashed lines, the latest as a dot in the status tone.
public struct Sparkline: View {
    let values: [Double?]
    let usual: ClosedRange<Double>?
    let tone: VTone
    public init(_ values: [Double?], usual: ClosedRange<Double>? = nil, tone: VTone = .usual) {
        self.values = values; self.usual = usual; self.tone = tone
    }
    public var body: some View {
        Canvas { ctx, size in
            let present = values.compactMap { $0 }
            guard !present.isEmpty else { return }
            var lo = present.min()!, hi = present.max()!
            if let usual { lo = min(lo, usual.lowerBound); hi = max(hi, usual.upperBound) }
            let pad = max((hi - lo) * 0.12, 0.5)
            lo -= pad; hi += pad
            let y = { (v: Double) in size.height * (1 - (v - lo) / (hi - lo)) }
            let step = values.count > 1 ? (size.width - 4) / Double(values.count - 1) : 0
            if let usual {
                for v in [usual.lowerBound, usual.upperBound] {
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y(v))); p.addLine(to: CGPoint(x: size.width, y: y(v)))
                    ctx.stroke(p, with: .color(Color(hex: 0x3A3A3A)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            var line = Path(), started = false, last: CGPoint?
            for (i, v) in values.enumerated() {
                guard let v else { started = false; continue }
                let pt = CGPoint(x: 2 + Double(i) * step, y: y(v))
                if started { line.addLine(to: pt) } else { line.move(to: pt); started = true }
                last = pt
            }
            ctx.stroke(line, with: .color(VColor.bone), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            if let last { ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(tone.color)) }
        }
        .accessibilityHidden(true)
    }
}

/// Recovery's four bands as one bar, the current band lit and a knob at the score.
public struct BandScale: View {
    let score: Int?
    let floors: (ease: Int, steady: Int, ready: Int)
    public init(score: Int?, ease: Int = 45, steady: Int = 60, ready: Int = 75) {
        self.score = score; self.floors = (ease, steady, ready)
    }
    public var body: some View {
        let edges = [0, floors.ease, floors.steady, floors.ready, 100]
        let names = ["Rest", "Ease", "Steady", "Ready"]
        let current = score.map { s in (0..<4).last { s >= edges[$0] } ?? 0 }
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                let w = g.size.width, gap: CGFloat = 4
                ZStack(alignment: .leading) {
                    ForEach(0..<4, id: \.self) { i in
                        let x0 = w * Double(edges[i]) / 100, x1 = w * Double(edges[i + 1]) / 100
                        Capsule().fill(i == current ? VColor.bone : Color(hex: 0x2A2A2A))
                            .frame(width: max(x1 - x0 - gap, 4), height: 6).offset(x: x0)
                    }
                    if let score {
                        Circle().fill(VColor.card).overlay(Circle().stroke(VColor.bone, lineWidth: 2.5))
                            .frame(width: 11, height: 11).offset(x: w * Double(min(max(score, 0), 100)) / 100 - 5.5)
                    }
                }
                .frame(height: 11)
            }
            .frame(height: 11)
            GeometryReader { g in
                ForEach(0..<4, id: \.self) { i in
                    Text(names[i]).vUI(11, weight: i == current ? 600 : 500, color: i == current ? VColor.bone : Color(hex: 0x7A7A7A))
                        .offset(x: g.size.width * Double(edges[i]) / 100)
                }
            }
            .frame(height: 13)
        }
        .accessibilityHidden(true)
    }
}

/// Small static pulse glyph beside a tab title (the brand line, not data).
public struct PulseGlyph: View {
    public init() {}
    public var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 64, sy = size.height / 16
            var p = Path()
            p.move(to: CGPoint(x: 1 * sx, y: 10 * sy))
            for (x, y) in [(19.0, 10.0), (23, 2), (28, 15), (32, 5), (35, 10), (63, 10)] { p.addLine(to: CGPoint(x: x * sx, y: y * sy)) }
            ctx.stroke(p, with: .color(VColor.pulse), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 64, height: 16)
        .accessibilityHidden(true)
    }
}

/// Tab header: room for the Settings gear (drawn by the shell), the condensed title, the pulse glyph, and a trailing view.
public struct TabHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) { self.title = title; self.trailing = trailing() }
    public var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 28, height: 28)
            Text(title).vHeadline(19).tracking(19 * 0.05)
            PulseGlyph()
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 32)
    }
}

public extension TabHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

/// A row of readouts split by hairlines: label, figure, status word. The card-less summary under a tab's centrepiece.
public struct Readout: Identifiable {
    public let id = UUID()
    let label: String, value: String, status: (String, VTone)?
    public init(_ label: String, _ value: String, status: (String, VTone)? = nil) { self.label = label; self.value = value; self.status = status }
}

public struct ReadoutRow: View {
    let items: [Readout]
    public init(_ items: [Readout]) { self.items = items }
    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.label).vUI(12, weight: 400, color: VColor.muted).lineLimit(1)
                    Text(item.value).vFigure(18).lineLimit(1).minimumScaleFactor(0.7)
                    if let s = item.status {
                        HStack(spacing: 5) {
                            Circle().fill(s.1.color).frame(width: 7, height: 7)
                            Text(s.0).vUI(12, weight: 500, color: VColor.muted).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                }
                .padding(.vertical, 12).padding(.leading, i == 0 ? 0 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(VColor.hairline).frame(width: 1) } }
                .accessibilityElement(children: .combine)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(VColor.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(VColor.hairline).frame(height: 1) }
    }
}

/// Pill segmented control: Night · Week · Month and similar.
public struct PillPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    public init(_ options: [(T, String)], selection: Binding<T>) { self.options = options; _selection = selection }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title).vUI(13, weight: 600, color: selection == value ? VColor.bone : VColor.muted)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(selection == value ? Color(hex: 0x2C2C2C) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(VColor.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// ‹ label › with either arrow disabled at the ends.
public struct PeriodStepper: View {
    let label: String
    let back: (() -> Void)?
    let forward: (() -> Void)?
    public init(_ label: String, back: (() -> Void)?, forward: (() -> Void)?) { self.label = label; self.back = back; self.forward = forward }
    public var body: some View {
        HStack(spacing: 4) {
            arrow("chevron.left", back, "Previous")
            Text(label).vUI(14, weight: 600).lineLimit(1)
            arrow("chevron.right", forward, "Next")
        }
    }
    private func arrow(_ name: String, _ action: (() -> Void)?, _ label: String) -> some View {
        Button { action?() } label: {
            Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(action == nil ? Color(hex: 0x4A4A4A) : VColor.muted)
                .frame(width: 32, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(action == nil).accessibilityLabel(label)
    }
}

/// Touch-to-read for charts: the finger's x (0…1 of the width) while touching, kept 3 s after lifting.
public struct Scrub: ViewModifier {
    @Binding var x: Double?
    @State private var clear: Task<Void, Never>?
    public init(_ x: Binding<Double?>) { _x = x }
    public func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { g in
                Color.clear.contentShape(Rectangle())
                    // Simultaneous, so a vertical swipe that starts on a chart still scrolls the page.
                    .simultaneousGesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in clear?.cancel(); x = min(max(v.location.x / max(g.size.width, 1), 0), 1) }
                        .onEnded { _ in
                            clear = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { x = nil } }
                        })
            }
        }
    }
}

public extension View {
    func scrub(_ x: Binding<Double?>) -> some View { modifier(Scrub(x)) }
}

/// The value under the finger: a small dark pill with a bone label.
public struct ChartCallout: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).vUI(12, weight: 600).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(hex: 0x2A2A2A), in: Capsule())
    }
}
