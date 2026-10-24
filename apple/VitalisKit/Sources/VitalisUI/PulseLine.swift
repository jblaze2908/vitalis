import SwiftUI

/// The signature line (spec 30 → PulseLine): flat past with a V dip per event, the now dot, a dotted future.
public struct PulseLine: View {
    public enum Style: Sendable, CaseIterable {
        case phone, watch, widget, progress

        var stroke: CGFloat { switch self { case .phone, .progress: 2.6; case .watch: 1.5; case .widget: 2.2 } }
        var dipHalfWidth: CGFloat { switch self { case .phone, .progress: 16; case .watch: 7; case .widget: 9 } }
        var dipDepth: CGFloat { switch self { case .phone: 22; case .progress: 26; case .watch: 8; case .widget: 10 } }
        var dotRadius: CGFloat { switch self { case .phone, .progress: 4.5; case .watch: 2.5; case .widget: 3.5 } }
        var futureStroke: CGFloat { switch self { case .phone, .progress: 2; case .watch: 1.5; case .widget: 1.6 } }
        var futureDash: [CGFloat] {
            switch self {
            case .phone, .progress: [2, 6]
            case .watch: [1.5, 4.5]
            case .widget: [2, 5]
            }
        }

        // Phone geometry is 390×40 with the baseline at 12; watch and widget scale it by their dip depth.
        private var scale: CGFloat { switch self { case .phone, .progress: 1; case .watch: 8 / 22; case .widget: 10 / 22 } }
        public var height: CGFloat { 40 * scale }
        var baseline: CGFloat { 12 * scale }
    }

    public var events: [Double]
    public var now: Double
    public var style: Style

    /// `events` and `now` are 0…1 fractions of the width; events after `now` are not drawn.
    public init(events: [Double] = [], now: Double, style: Style = .phone) {
        self.events = events
        self.now = now
        self.style = style
    }

    /// Server window (`pulse.window`) mapped to fractions with `fraction(at:start:end:)`.
    public init(start: Date, end: Date, now: Date, events: [Date], style: Style = .phone) {
        self.init(events: events.map { Self.fraction(at: $0, start: start, end: end) },
                  now: Self.fraction(at: now, start: start, end: end), style: style)
    }

    public var body: some View {
        Canvas { context, size in
            let layout = Self.layout(events: events, now: now, style: style, width: size.width)
            var past = Path()
            past.addLines(layout.past)
            context.stroke(past, with: .color(VColor.pulse),
                           style: StrokeStyle(lineWidth: style.stroke, lineCap: .round, lineJoin: .round))

            let y = style.baseline
            if layout.dotX < size.width {
                var future = Path()
                future.move(to: CGPoint(x: layout.dotX, y: y))
                future.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(future, with: .color(VColor.future),
                               style: StrokeStyle(lineWidth: style.futureStroke, dash: style.futureDash))
            }

            let r = style.dotRadius
            context.fill(Path(ellipseIn: CGRect(x: layout.dotX - r, y: y - r, width: 2 * r, height: 2 * r)),
                         with: .color(VColor.pulse))
        }
        .frame(height: style.height)
        .accessibilityHidden(true)
    }

    // MARK: - Mapping (server-driven, spec 30 "Time → x")

    /// x = (t − start) / (end − start), clamped to 0…1.
    nonisolated public static func fraction(at t: Date, start: Date, end: Date) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return t >= end ? 1 : 0 }
        return min(max(t.timeIntervalSince(start) / span, 0), 1)
    }

    /// Maps `GET /v2/today` → `pulse` ISO strings to fractions, dropping events after now; nil if the window or now don't parse.
    nonisolated public static func positions(windowStart: String, windowEnd: String, now: String,
                                 events: [String]) -> (events: [Double], now: Double)? {
        guard let start = parseDate(windowStart), let end = parseDate(windowEnd), let nowDate = parseDate(now) else { return nil }
        let past = events.compactMap(parseDate).filter { $0 <= nowDate }.sorted()
        return (past.map { fraction(at: $0, start: start, end: end) }, fraction(at: nowDate, start: start, end: end))
    }

    nonisolated static func parseDate(_ s: String) -> Date? {
        (try? Date(s, strategy: .iso8601))
            ?? (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    /// Past polyline and dot x for a width. Overlapping dips merge (deepest wins) and a dip that ends past now
    /// pushes the dot to its trailing edge, as in the Watch set-entry frame.
    nonisolated static func layout(events: [Double], now: Double, style: Style, width: CGFloat) -> (past: [CGPoint], dotX: CGFloat) {
        let half = style.dipHalfWidth, depth = style.dipDepth, base = style.baseline
        let nowFraction = min(max(now, 0), 1)
        let xs = events.filter { $0.isFinite && $0 <= nowFraction }
            .map { min(max(CGFloat(min(max($0, 0), 1)) * width, half), max(half, width - half)) }
            .sorted()
        let end = max(CGFloat(nowFraction) * width, xs.last.map { $0 + half } ?? 0)

        // Kinks of a max-of-V profile: each V's three corners plus the meeting point of neighbours.
        var breaks: [CGFloat] = [0, end]
        for (i, x) in xs.enumerated() {
            breaks += [x - half, x, x + half]
            if i > 0 { breaks.append((xs[i - 1] + x) / 2) }
        }
        let ordered = Array(Set(breaks.filter { $0 >= 0 && $0 <= end })).sorted()
        let past = ordered.map { x in
            CGPoint(x: x, y: base + (xs.map { depth * max(0, 1 - abs(x - $0) / half) }.max() ?? 0))
        }
        let r = style.dotRadius
        return (past, min(max(end, r), max(r, width - r)))
    }
}

// MARK: - Previews (fixtures only)

private struct PulseLinePreviewRow: View {
    let label: String
    let line: PulseLine
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoLabel(label, size: .small)
            line
        }
    }
}

#Preview("PulseLine · phone") {
    VStack(alignment: .leading, spacing: 24) {
        PulseLinePreviewRow(label: "Digest · now 0.18 · wake", line: PulseLine(events: [0.144], now: 0.18))
        PulseLinePreviewRow(label: "Today · now 0.64 · two events", line: PulseLine(events: [0.14, 0.426], now: 0.64))
        PulseLinePreviewRow(label: "Other tabs · flat", line: PulseLine(now: 0.64))
        PulseLinePreviewRow(label: "Event after now · not drawn", line: PulseLine(events: [0.3, 0.8], now: 0.5))
    }
    .frame(width: 390)
    .vScreen()
    .onAppear { VFont.register() }
}

#Preview("PulseLine · watch and widget") {
    VStack(alignment: .leading, spacing: 24) {
        // Set entry: x = i / (planned + 1) for 3 logged of 4 planned, now after the last.
        PulseLinePreviewRow(label: "Watch · three sets", line: PulseLine(events: [0.2, 0.4, 0.6], now: 0.6, style: .watch))
            .frame(width: 162)
        PulseLinePreviewRow(label: "Widget", line: PulseLine(events: [0.1, 0.4], now: 0.55, style: .widget))
            .frame(width: 140)
    }
    .padding(VSpace.gutter)
    .vScreen()
    .onAppear { VFont.register() }
}

#Preview("PulseLine · setup progress") {
    VStack(alignment: .leading, spacing: 20) {
        ForEach(1...4, id: \.self) { step in
            PulseLinePreviewRow(label: "Step \(step) of 4",
                                line: PulseLine(events: step > 1 ? [Double(step - 1) / 4.5] : [],
                                                now: Double(step) / 4.5, style: .progress))
        }
    }
    .frame(width: 390)
    .vScreen()
    .onAppear { VFont.register() }
}
