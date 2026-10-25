import SwiftUI
import VitalisKit
import VitalisUI
#if os(watchOS)
import WatchKit
#endif

/// Frame-derived geometry (apple/briefs/02-watch-logger.md, @2x frames halved). Colours and type stay in VitalisUI.
enum WatchLayout {
    static let side: CGFloat = 22
    static let setEntrySide: CGFloat = 28
    static let buttonHeight: CGFloat = 33
    static let buttonBottom: CGFloat = 13
    static let rowHeight: CGFloat = 35
    static let focusUnderline: CGFloat = 1.5
    static let ringInset: CGFloat = 4
    static let ringRadius: CGFloat = 40
    static let ringStroke: CGFloat = 3
    static let restTop: CGFloat = 25
    static let restBottom: CGFloat = 21
    static let restSide: CGFloat = 27
    static let summaryMapWidth: CGFloat = 145
    static let summaryMapStroke: CGFloat = 4
    static let summaryBottom: CGFloat = 15
    static let summarySide: CGFloat = 23
}

/// Watch primary action: 33 pt tall, Action 17 (the phone PrimaryButton's label is fixed at 20).
struct WatchPrimaryButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title).vAction(17, color: VColor.ground).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: WatchLayout.buttonHeight)
                .background(VColor.pulse, in: RoundedRectangle(cornerRadius: VRadius.button, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 35 pt row with a rule on top: headline left, mono label right (Start, Add exercise).
struct WatchRow: View {
    let title: String
    let detail: String?
    var detailTint: VTint = .steel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Rule()
                HStack(alignment: .firstTextBaseline) {
                    Text(title).vHeadline(17).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 6)
                    if let detail { MonoLabel(detail, tint: detailTint) }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: WatchLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `-sdk iphonesimulator` builds of the `Vitalis` scheme compile this target for iOS too, so watch-only APIs sit behind `#if os(watchOS)`.
@MainActor enum Haptic {
    enum Kind { case success, failure, notification }
    static func play(_ kind: Kind) {
        #if os(watchOS)
        let type: WKHapticType = switch kind { case .success: .success; case .failure: .failure; case .notification: .notification }
        WKInterfaceDevice.current().play(type)
        #endif
    }
}

extension View {
    /// Crown editing with detents (spec 21 §2.2); a no-op where there is no Crown.
    func crownEditing(_ value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        #if os(watchOS)
        digitalCrownRotation(value, from: range.lowerBound, through: range.upperBound, by: step,
                             sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        #else
        self
        #endif
    }

    /// Double tap triggers the primary action where the hardware supports it.
    func doubleTapPrimaryAction() -> some View {
        #if os(watchOS)
        handGestureShortcut(.primaryAction)
        #else
        self
        #endif
    }
}

/// Display formatting only; every value is the owner's input or the server's.
enum WatchFormat {
    static let missing = "–"

    /// `100`, `97.5`, `–`.
    static func kg(_ value: Double?) -> String {
        guard let value else { return missing }
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    static func reps(_ value: Int?) -> String { value.map(String.init) ?? missing }

    /// `Squat 100 kg · 6`.
    static func setLine(name: String, weightKg: Double?, reps: Int?) -> String {
        "\(name) \(kg(weightKg)) kg · \(Self.reps(reps))"
    }

    /// Server day `2026-10-22` → `Thu` (the label role uppercases it).
    static func weekday(_ day: String) -> String? {
        guard let date = try? Date(day + "T12:00:00Z", strategy: .iso8601) else { return nil }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated)
        style.timeZone = .gmt
        return date.formatted(style)
    }

    /// Catalog id fallback when the pack has no name for it: `leg-press` → `leg press`.
    static func name(forID id: String) -> String { id.replacingOccurrences(of: "-", with: " ") }
}
