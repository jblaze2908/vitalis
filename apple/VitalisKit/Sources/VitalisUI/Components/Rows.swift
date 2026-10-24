import SwiftUI

/// Every caption, section label, unit and status. Always uppercase mono.
public struct MonoLabel: View {
    let text: String
    let size: VLabelSize
    let tint: VTint
    public init(_ text: String, size: VLabelSize = .standard, tint: VTint = .steel) { self.text = text; self.size = size; self.tint = tint }
    public var body: some View { Text(text).vLabel(size, tint: tint) }
}

public enum VArrow: String, Sendable, Codable { case up, down
    var glyph: String { self == .up ? "↑" : "↓" }
}

/// KEY ………… VALUE ↑, a 1 px rule under it. Tint follows the metric's better direction (server-given), not the arrow.
public struct ReadingRow: View {
    let key: String
    let value: String
    let tint: VTint
    let arrow: VArrow?
    let showsRule: Bool
    let size: CGFloat

    public init(_ key: String, value: String, tint: VTint = .bone, arrow: VArrow? = nil, showsRule: Bool = true, size: CGFloat = 12.5) {
        self.key = key; self.value = value; self.tint = tint; self.arrow = arrow; self.showsRule = showsRule; self.size = size
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(key).vReading(size, tint: .steel).textCase(.uppercase)
                Spacer(minLength: 12)
                Text(arrow.map { "\(value) \($0.glyph)" } ?? value).vReading(size, tint: tint).textCase(.uppercase)
            }
            .padding(.vertical, VSpace.rowPad)
            if showsRule { Rule() }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The 1 px hairline that separates every section (never cards).
public struct Rule: View {
    public init() {}
    public var body: some View { Rectangle().fill(VColor.rule).frame(height: 1) }
}

/// A section: rule on top, then content.
public struct VSection<Content: View>: View {
    let top: CGFloat
    let content: Content
    public init(top: CGFloat = VSpace.sectionTop, @ViewBuilder content: () -> Content) { self.top = top; self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
            content.padding(.top, VSpace.sectionPad)
        }
        .padding(.top, top)
    }
}

/// Right-hand status label aligned with the system status bar (iOS draws the time itself).
public struct StatusRow: View {
    let label: String
    let tint: VTint
    let showsTime: Bool
    public init(_ label: String, tint: VTint = .steel, showsTime: Bool = false) { self.label = label; self.tint = tint; self.showsTime = showsTime }
    public var body: some View {
        HStack {
            if showsTime { Text(Date.now, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute()).vStatusTime() }
            Spacer()
            MonoLabel(label, tint: tint)
        }
        .padding(.horizontal, VSpace.statusSide)
    }
}

/// Context label, 46 pt headline, optional trailing control aligned to the headline's bottom.
public struct ScreenHeader<Trailing: View>: View {
    let context: String
    let title: String
    let contextTint: VTint
    let trailing: Trailing
    public init(context: String, title: String, contextTint: VTint = .steel, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.context = context; self.title = title; self.contextTint = contextTint; self.trailing = trailing()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoLabel(context, tint: contextTint)
            HStack(alignment: .bottom) {
                HeadlineLines(HeadlineLines.split(title, maxChars: 16), size: 46)
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

/// 2 pt track with a bone (or watch) fill; `fraction` is server-derived (e.g. eaten / target is display only).
public struct ProgressTrack: View {
    let fraction: Double
    let flagged: Bool
    public init(_ fraction: Double, flagged: Bool = false) { self.fraction = fraction; self.flagged = flagged }
    public var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(VColor.track)
                Rectangle().fill(flagged ? VColor.watch : VColor.bone).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// Vitals: a 2 pt track, the usual range as a 4 pt band, the value as an 8 pt dot. Positions come in as 0…1.
public struct RangeBar: View {
    let low: Double, high: Double, value: Double
    let tint: VTint
    public init(low: Double, high: Double, value: Double, tint: VTint = .bone) { self.low = low; self.high = high; self.value = value; self.tint = tint }
    public var body: some View {
        GeometryReader { g in
            let w = g.size.width, c = { (x: Double) in w * min(max(x, 0), 1) }
            ZStack(alignment: .leading) {
                Rectangle().fill(VColor.track).frame(height: 2)
                Rectangle().fill(VColor.disabled).frame(width: max(c(high) - c(low), 2), height: 4).offset(x: c(low))
                Circle().fill(tint.color).frame(width: 8, height: 8).offset(x: c(value) - 4)
            }
            .frame(height: 8)
        }
        .frame(width: 92, height: 8)
        .accessibilityHidden(true)
    }
}

/// Seven 6 pt bars (today bone), letters under, value labels above. Heights arrive as 0…1.
public struct WeekBars: View {
    public struct Bar: Identifiable, Sendable {
        public let id: String
        public let letter: String
        public let height: Double
        public let value: String?
        public let isToday: Bool
        public init(id: String, letter: String, height: Double, value: String? = nil, isToday: Bool = false) {
            self.id = id; self.letter = letter; self.height = height; self.value = value; self.isToday = isToday
        }
    }
    let bars: [Bar]
    let maxHeight: CGFloat
    public init(_ bars: [Bar], maxHeight: CGFloat = 56) { self.bars = bars; self.maxHeight = maxHeight }
    public var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(bars) { b in
                VStack(spacing: 6) {
                    if let v = b.value { Text(v).vLabel(.small, tint: b.isToday ? .bone : .steel) }
                    Capsule().fill(b.isToday ? VColor.bone : VColor.barIdle)
                        .frame(width: 6, height: max(2, maxHeight * min(max(b.height, 0), 1)))
                    Text(b.letter).vLabel(.small, tint: b.isToday ? .bone : .steel)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Undo toast: tick, text, divider, UNDO. The owner of the toast dismisses it after 5 s.
public struct Toast: View {
    let text: String
    let undo: (() -> Void)?
    public init(_ text: String, undo: (() -> Void)? = nil) { self.text = text; self.undo = undo }
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(VColor.good)
            Text(text).vReading(12.5).lineLimit(1)
            Spacer()
            if let undo {
                Rectangle().fill(VColor.track).frame(width: 1, height: 24)
                Button(action: undo) { Text("Undo").vAction(19) }.buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(VColor.toast, in: RoundedRectangle(cornerRadius: VRadius.button, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VRadius.button, style: .continuous).stroke(VColor.track, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}
