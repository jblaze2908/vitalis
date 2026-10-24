import SwiftUI
import VitalisKit
import VitalisUI
import WidgetKit

@main
struct VitalisWatchWidgetBundle: WidgetBundle {
    init() { VFont.register() }
    var body: some Widget { TodayComplication() }
}

/// Watch face complications, frame 34 (`9KeK3X1BI1`) per spec 21 §3. A tap launches the app on Start (its root).
struct TodayComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VitalisTodayComplication", provider: TodayProvider()) { entry in
            TodayComplicationView(model: entry.model)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Today")
        .description("Recovery and steps from your iPhone.")
        .supportedFamilies(Self.families)
    }

    // `-sdk iphonesimulator` builds of the Vitalis scheme compile this target against iOS, which lacks the corner.
    #if os(watchOS)
    static let families: [WidgetFamily] = [.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline]
    #else
    static let families: [WidgetFamily] = [.accessoryRectangular, .accessoryCircular, .accessoryInline]
    #endif
}

private enum ComplicationLayout {
    static let lineGap: CGFloat = 4
}

struct TodayComplicationView: View {
    let model: WidgetModel
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        #if os(watchOS)
        case .accessoryCorner: corner
        #endif
        case .accessoryInline: Text(model.inline)
        default: rectangular
        }
    }

    private var score: some View {
        Text(model.recovery ?? WidgetModel.dash)
            .lineLimit(1).minimumScaleFactor(0.6)
            .widgetAccentable()
    }

    private var bandLabel: some View {
        MonoLabel(model.label ?? WidgetModel.dash, size: .small, tint: model.label == nil ? .steel : model.tint)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    /// PulseLine, then score + band word on the left and steps on the right.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: ComplicationLayout.lineGap) {
            PulseLine(model.pulse, style: .widget).widgetAccentable()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    score.vNumber(24, color: model.recovery == nil ? VColor.steel : nil)
                    bandLabel
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(model.steps ?? WidgetModel.dash)
                        .vNumber(24, color: model.steps == nil ? VColor.steel : nil)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    MonoLabel("Steps", size: .small)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Recovery \(model.recovery ?? "not available")", model.label, model.stepsLine]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                score.vNumber(22, color: model.recovery == nil ? VColor.steel : nil)
                bandLabel
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Recovery \(model.recovery ?? "not available")", model.label].compactMap { $0 }.joined(separator: ", "))
    }

    private var corner: some View {
        score.vNumber(20, color: model.recovery == nil ? VColor.steel : nil)
            .widgetLabel {
                if let gauge = model.recoveryGauge {
                    Gauge(value: gauge) { Text("Recovery") }.tint(model.tint.color)
                } else {
                    Text(model.label ?? WidgetModel.dash)
                }
            }
            .accessibilityLabel("Recovery \(model.recovery ?? "not available")")
    }
}

// MARK: - Previews (fixture snapshot and missing snapshot)

#Preview("Rectangular", as: .accessoryRectangular) { TodayComplication() } timeline: { WidgetPreviewData.ready; WidgetPreviewData.missing }
#Preview("Circular", as: .accessoryCircular) { TodayComplication() } timeline: { WidgetPreviewData.ready; WidgetPreviewData.missing }
#if os(watchOS)
#Preview("Corner", as: .accessoryCorner) { TodayComplication() } timeline: { WidgetPreviewData.ready; WidgetPreviewData.missing }
#endif
#Preview("Inline", as: .accessoryInline) { TodayComplication() } timeline: { WidgetPreviewData.ready; WidgetPreviewData.missing }
