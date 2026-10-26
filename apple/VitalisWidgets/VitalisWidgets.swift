import SwiftUI
import VitalisKit
import VitalisUI
import WidgetKit

@main
struct VitalisWidgetBundle: WidgetBundle {
    init() { VFont.register() }
    var body: some Widget {
        TodayWidget()
        WorkoutLiveActivity()
    }
}

/// Home and Lock Screen widgets, frame 29 (`lDPxhnSr9k`).
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VitalisToday", provider: TodayProvider()) { entry in
            TodayWidgetView(model: entry.model)
        }
        .configurationDisplayName("Today")
        .description("Recovery, steps and fuel from your last Today refresh.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

/// Measurements from brief 03 → Widgets.
enum WidgetLayout {
    static let smallPadding: CGFloat = 14
    static let mediumVertical: CGFloat = 14
    static let mediumHorizontal: CGFloat = 16
    static let pulseWidth: CGFloat = 130
    static let headerGap: CGFloat = 8
    static let ring: CGFloat = 1
    static let accessoryInset: CGFloat = 8
}

struct TodayWidgetView: View {
    let model: WidgetModel
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium: SystemWidget { MediumBody(model: model) }
        case .accessoryCircular: AccessoryWidget { CircularBody(model: model) }
        case .accessoryRectangular: AccessoryWidget { RectangularBody(model: model) }
        default: SystemWidget { SmallBody(model: model) }
        }
    }
}

/// `sheet` fill and a 1 pt `rule` ring following the system widget shape.
private struct SystemWidget<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .widgetURL(WidgetLink.today)
            .containerBackground(for: .widget) {
                ZStack {
                    VColor.sheet
                    ContainerRelativeShape().inset(by: WidgetLayout.ring / 2).stroke(VColor.rule, lineWidth: WidgetLayout.ring)
                }
            }
    }
}

private struct AccessoryWidget<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            content
        }
        .widgetURL(WidgetLink.today)
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct SmallBody: View {
    let model: WidgetModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PulseLine(model.pulse, style: .widget).frame(width: WidgetLayout.pulseWidth, alignment: .leading)
            Spacer(minLength: 0)
            Text(model.recovery ?? WidgetModel.dash)
                .vNumber(54, color: model.recovery == nil ? VColor.steel : nil)
                .lineLimit(1).minimumScaleFactor(0.6)
            MonoLabel(model.label ?? WidgetModel.dash, tint: model.label == nil ? .steel : model.tint)
            Text(model.headline ?? WidgetModel.dash)
                .vHeadline(19, color: model.headline == nil ? VColor.steel : nil)
                .lineLimit(2).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(WidgetLayout.smallPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Recovery \(model.recovery ?? "not available")", model.label, model.headline]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

private struct MediumBody: View {
    let model: WidgetModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MonoLabel(model.context)
                Spacer(minLength: WidgetLayout.headerGap)
                Link(destination: WidgetLink.logMeal) { MonoLabel("+ Log meal", tint: .bone) }
                    .accessibilityLabel("Log meal")
            }
            .padding(.bottom, WidgetLayout.headerGap)
            row("Steps", model.stepsReading, missing: model.steps == nil)
            Rule()
            row("Fuel left", model.fuelReading, missing: model.kcalLeft == nil)
            Rule()
            row("Protein", model.proteinReading, missing: model.protein == nil)
        }
        .padding(.vertical, WidgetLayout.mediumVertical)
        .padding(.horizontal, WidgetLayout.mediumHorizontal)
    }

    private func row(_ key: String, _ value: String, missing: Bool) -> some View {
        ReadingRow(key, value: value, tint: missing ? .steel : .bone, showsRule: false, size: 13)
            .frame(maxHeight: .infinity)
    }
}

private struct CircularBody: View {
    let model: WidgetModel
    var body: some View {
        VStack(spacing: 0) {
            Text(model.recovery ?? WidgetModel.dash)
                .vNumber(24, color: model.recovery == nil ? VColor.steel : nil)
                .lineLimit(1).minimumScaleFactor(0.6)
            MonoLabel(model.label ?? WidgetModel.dash, size: .small, tint: .bone)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Recovery \(model.recovery ?? "not available")", model.label].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct RectangularBody: View {
    let model: WidgetModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.headline ?? WidgetModel.dash)
                .vHeadline(18, color: model.headline == nil ? VColor.steel : nil)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(model.stepsLine).vReading(11, tint: .steel).lineLimit(1)
            Text(model.kcalLine).vReading(11, tint: .steel).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WidgetLayout.accessoryInset)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews (fixture snapshot and missing snapshot)

#Preview("Small", as: .systemSmall) { TodayWidget() } timeline: { WidgetPreviewData.ready; WidgetPreviewData.missing }
#Preview("Medium", as: .systemMedium) { TodayWidget() } timeline: { WidgetPreviewData.ready; WidgetPreviewData.missing }
#Preview("Circular", as: .accessoryCircular) { TodayWidget() } timeline: { WidgetPreviewData.ready; WidgetPreviewData.missing }
#Preview("Rectangular", as: .accessoryRectangular) { TodayWidget() } timeline: { WidgetPreviewData.ready; WidgetPreviewData.missing }
