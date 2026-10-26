import SwiftUI

// Vitalis design system v1 (Draft "Vitalis", canvas kqPE9w5k-9, rules doc "vitalis-rules").
// Screens use only these tokens and the components built on them; `DesignSystemLintTests` fails on literals.

public extension VColor {
    static let text = bone
    static let text2 = muted
    static let text3 = Color(hex: 0x6E6E6E)
    static let surface = card
    static let surface2 = cardRaised
    static let line = hairline
    static let grid = Color(hex: 0x1C1C1C)
    static let barTrack = Color(hex: 0x2A2A2A)
    /// Usual or aim range drawn behind a bar or chart.
    static let range = Color(hex: 0x333333)
    static let accent = pulse
    static let onAccent = Color(hex: 0x1A0503)
    static let onEat = Color(hex: 0x1A0C02)
    static let onBody = Color(hex: 0x140A2E)
    /// A day with a workout; a selected accent item.
    static let accentTint = Color(hex: 0x2B1412)
    static let segmentOn = Color(hex: 0x2C2C2C)
    static let chevron = Color(hex: 0x5A5A5A)
    static let dashed = Color(hex: 0x3A3A3A)
}

public extension VSpace {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32
    static let s7: CGFloat = 48
    /// Every screen edge and card inset.
    static let edge: CGFloat = 16
    static let rowMin: CGFloat = 52
}

public extension VRadius {
    static let control: CGFloat = 8
    static let inner: CGFloat = 12
    static let card: CGFloat = 16
}

/// Two bar heights, nothing else.
public enum VBar {
    /// Progress against a target.
    public static let meter: CGFloat = 8
    /// Comparison bars in lists.
    public static let thin: CGFloat = 4
    /// The target tick drawn over a meter.
    public static let tick: CGFloat = 16
}

/// The 9 type styles plus the unit beside a number.
public enum VText: Sendable {
    case display, numXL, numL, numM, numS, title, headline, body, secondary, label, axis, unit

    var font: Font {
        switch self {
        case .display: VFont.archivo(32, width: 62, weight: 800)
        case .numXL: VFont.archivo(56, width: 125, weight: 300)
        case .numL: VFont.archivo(40, width: 125, weight: 400)
        case .numM: VFont.archivo(28, width: 125, weight: 400)
        case .numS: VFont.archivo(20, width: 125, weight: 500)
        case .title: VFont.archivo(17, width: 100, weight: 600)
        case .headline: VFont.archivo(15, width: 100, weight: 600)
        case .body: VFont.archivo(15, width: 100, weight: 400)
        case .secondary: VFont.archivo(13, width: 100, weight: 400)
        case .label: VFont.mono(11, weight: 600)
        case .axis: VFont.mono(10, weight: 500)
        case .unit: VFont.archivo(13, width: 100, weight: 500)
        }
    }
    var color: Color {
        switch self {
        case .secondary, .label, .unit: VColor.text2
        case .axis: VColor.text3
        default: VColor.text
        }
    }
    var tracking: CGFloat {
        switch self {
        case .label: 11 * 0.12
        case .numXL, .numL, .numM, .numS: -0.01 * 20
        default: 0
        }
    }
    var caps: Bool { self == .display || self == .label }
}

public extension View {
    /// One of the system's type styles; `color` only when a status or tab colour applies.
    func vText(_ style: VText, color: Color? = nil) -> some View {
        font(style.font).tracking(style.tracking).foregroundStyle(color ?? style.color)
            .textCase(style.caps ? .uppercase : nil).monospacedDigit()
    }
}

// MARK: Header and freshness

/// What a tab's freshness line says: when its data last came from the server.
public struct DataFreshness: Equatable, Sendable {
    public var fetchedAt: Date?
    public var refreshing: Bool
    public init(fetchedAt: Date?, refreshing: Bool = false) { self.fetchedAt = fetchedAt; self.refreshing = refreshing }
    /// Amber after 6 hours without fresh data.
    public func isStale(now: Date) -> Bool { fetchedAt.map { now.timeIntervalSince($0) > 6 * 3600 } ?? false }
}

public struct FreshnessLine: View {
    let state: DataFreshness
    public init(_ state: DataFreshness) { self.state = state }
    public var body: some View {
        TimelineView(.everyMinute) { ctx in
            let stale = state.isStale(now: ctx.date)
            HStack(spacing: 6) {
                Circle().fill(state.refreshing ? VColor.text2 : stale ? VColor.watch : VColor.good).frame(width: 6, height: 6)
                    .opacity(state.refreshing ? 0.6 : 1)
                Text(text(now: ctx.date)).font(VFont.archivo(12, width: 100, weight: 400)).foregroundStyle(stale ? VColor.watch : VColor.text2)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private func text(now: Date) -> String {
        if state.refreshing { return "Updating…" }
        guard let at = state.fetchedAt else { return "Not updated yet · pull to refresh" }
        let s = now.timeIntervalSince(at)
        if s < 60 { return "Updated just now" }
        if s < 3600 { return "Updated \(Int(s / 60)) min ago" }
        let h = Int(s / 3600)
        return state.isStale(now: now) ? "Last update \(h) h ago · pull to refresh" : "Updated \(h) h ago"
    }
}

/// Opens Settings from any tab header; RootView sets it.
public struct OpenSettingsKey: EnvironmentKey { public static let defaultValue: (@MainActor () -> Void)? = nil }
public extension EnvironmentValues {
    var openSettings: (@MainActor () -> Void)? {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

/// Tab header: settings on the gutter, the title with the pulse mark, one trailing item, the freshness line under it.
/// It carries its own 16 gutter: place it edge to edge.
public struct VHeader<Trailing: View>: View {
    let title: String
    let freshness: DataFreshness?
    let trailing: Trailing
    @Environment(\.openSettings) private var openSettings
    public init(_ title: String, freshness: DataFreshness? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.freshness = freshness; self.trailing = trailing()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Button { openSettings?() } label: {
                    Image(systemName: "gearshape").font(.system(size: 15, weight: .medium)).foregroundStyle(VColor.text)
                        .frame(width: 32, height: 32).background(VColor.surface, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.leading, -6).accessibilityLabel("Settings")
                Text(title).font(VFont.archivo(20, width: 62, weight: 800)).tracking(20 * 0.04).textCase(.uppercase).foregroundStyle(VColor.text)
                PulseGlyph().frame(width: 48, height: 12)
                Spacer(minLength: VSpace.s2)
                trailing
            }
            .frame(height: 44)
            if let freshness { FreshnessLine(freshness).padding(.leading, 38) }
        }
        .padding(.horizontal, VSpace.edge)
    }
}

public extension VHeader where Trailing == EmptyView {
    init(_ title: String, freshness: DataFreshness? = nil) { self.init(title, freshness: freshness) { EmptyView() } }
}

/// The trailing action of a header: one pill in the tab's colour.
public struct PillButton: View {
    let title: String
    let fill: Color
    let ink: Color
    let action: () -> Void
    public init(_ title: String, fill: Color = VColor.accent, ink: Color = VColor.onAccent, action: @escaping () -> Void) {
        self.title = title; self.fill = fill; self.ink = ink; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title).font(VFont.archivo(14, width: 100, weight: 700)).foregroundStyle(ink)
                .padding(.horizontal, 13).frame(height: 32).background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Sections, lists, bars

/// Mono caps label above a card or list, optional note on the right. 24 above, 8 below, on the gutter.
public struct SectionLabel: View {
    let label: String
    let note: String?
    public init(_ label: String, note: String? = nil) { self.label = label; self.note = note }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).vText(.label)
            Spacer(minLength: VSpace.s2)
            if let note { Text(note).vText(.label) }
        }
        .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5).padding(.bottom, VSpace.s2)
    }
}

/// A card of rows separated by hairlines; rows bring their own 12 vertical padding.
public struct ListCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { i, v in
                    if i > 0 { Rectangle().fill(VColor.line).frame(height: 1) }
                    v
                }
            }
        }
        .padding(.horizontal, VSpace.s4)
        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.card, style: .continuous))
    }
}

/// A list row: title, secondary line, trailing value, chevron when it opens something. 52 minimum.
public struct ListRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let value: String?
    let chevron: Bool
    let accessory: Accessory
    public init(_ title: String, subtitle: String? = nil, value: String? = nil, chevron: Bool = true, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.subtitle = subtitle; self.value = value; self.chevron = chevron; self.accessory = accessory()
    }
    public var body: some View {
        HStack(spacing: VSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VFont.archivo(15, width: 100, weight: 500)).foregroundStyle(VColor.text).lineLimit(1)
                if let subtitle { Text(subtitle).vText(.secondary).lineLimit(1) }
            }
            Spacer(minLength: VSpace.s2)
            accessory
            if let value { Text(value).font(VFont.archivo(14, width: 100, weight: 500)).foregroundStyle(VColor.text2).lineLimit(1).monospacedDigit() }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(VColor.chevron) }
        }
        .frame(minHeight: VSpace.rowMin).padding(.vertical, VSpace.s3).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

public extension ListRow where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, value: String? = nil, chevron: Bool = true) {
        self.init(title, subtitle: subtitle, value: value, chevron: chevron) { EmptyView() }
    }
}

/// A comparison bar for lists (sets per muscle): 4 high, names and counts in fixed lanes, aim range behind.
public struct ComparisonBar: View {
    let name: String
    let value: Int
    let fraction: Double
    let range: ClosedRange<Double>?
    let fill: Color
    public init(_ name: String, value: Int, fraction: Double, range: ClosedRange<Double>? = nil, fill: Color = VColor.accent) {
        self.name = name; self.value = value; self.fraction = fraction; self.range = range; self.fill = fill
    }
    public var body: some View {
        HStack(spacing: VSpace.s3) {
            Text(name).font(VFont.archivo(14, width: 100, weight: 400)).foregroundStyle(VColor.text).lineLimit(1).frame(width: 84, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width, c = { (v: Double) in min(max(v, 0), 1) }
                ZStack(alignment: .leading) {
                    Capsule().fill(VColor.barTrack)
                    if let r = range { Rectangle().fill(VColor.range).frame(width: w * (c(r.upperBound) - c(r.lowerBound))).offset(x: w * c(r.lowerBound)) }
                    Capsule().fill(fill).frame(width: max(VBar.thin, w * c(fraction)))
                }
            }
            .frame(height: VBar.thin)
            Text("\(value)").font(VFont.archivo(13, width: 100, weight: 500)).foregroundStyle(VColor.text).monospacedDigit().frame(width: 24, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
