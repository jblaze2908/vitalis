import SwiftUI
import VitalisKit
import VitalisUI

/// Log weight half sheet (frame 08, brief 03 → Log weight): ruler prefilled with the last reading, when, Health toggle, Save.
struct LogWeightSheet: View {
    let store: BodyStore
    @Environment(\.dismiss) private var dismiss
    @State private var tenths: Int
    @State private var when = Date()
    @State private var alsoHealth = true
    @State private var editingWhen = false
    @State private var saving = false

    /// No reading yet: the ruler starts here (display default, not a server value).
    static let emptyStartTenths = 700

    init(store: BodyStore) {
        self.store = store
        _tenths = State(initialValue: store.prefillTenths ?? Self.emptyStartTenths)
    }

    private var kgText: String { String(format: "%.1f", Double(tenths) / 10) }

    var body: some View {
        SheetChrome {
            VStack(spacing: 0) {
                titleRow.padding(.top, 22)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(kgText).vNumber(84).monospacedDigit().lineLimit(1)
                    MonoLabel("kg")
                }
                .padding(.top, 22)
                .accessibilityHidden(true)
                if let caption { MonoLabel(caption, size: .small).padding(.top, 8).lineLimit(1).minimumScaleFactor(0.8) }
                WeightRuler(tenths: $tenths).frame(height: 60).padding(.top, 18)
                VStack(spacing: 0) {
                    Rule()
                    whenRow
                    Rule()
                    healthRow
                }
                .padding(.top, 20)
                .padding(.horizontal, VSpace.gutter)
                Spacer(minLength: 12)
                PrimaryButton("Save \(kgText) kg", action: save)
                    .padding(.horizontal, VSpace.gutter)
                    .padding(.bottom, 38)
            }
        }
        .presentationDetents([.height(486)])
        .sheet(isPresented: $editingWhen) { whenPicker }
    }

    private var titleRow: some View {
        ZStack {
            Text("Log weight").vHeadline(22)
            HStack {
                Button { dismiss() } label: { MonoLabel("Cancel", tint: .bone).frame(minHeight: 44) }.buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, VSpace.gutter)
    }

    /// `LAST 76.8 YESTERDAY · TREND 76.4` from the server's weight block.
    private var caption: String? {
        guard let w = store.weight else { return nil }
        var parts: [String] = []
        if let latest = w.latest {
            let day = latest.at.flatMap(APIDate.parse).map { " " + StaleState.dayLabel($0, now: Date(), calendar: .current) } ?? ""
            parts.append("Last \(SleepBodyFormat.kg(latest.kg))\(day)")
        }
        if let trend = w.trendKg { parts.append("Trend \(SleepBodyFormat.kg(trend))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var whenRow: some View {
        Button { editingWhen = true } label: {
            HStack {
                Text("When").vReading(13, tint: .steel).textCase(.uppercase)
                Spacer()
                Text("\(StaleState.dayLabel(when, now: Date(), calendar: .current)) · \(StaleState.clock(when, calendar: .current))")
                    .vReading(13).textCase(.uppercase)
            }
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Changes when the weight was measured")
    }

    private var healthRow: some View {
        Toggle(isOn: $alsoHealth) {
            Text("Also save to Apple Health").vReading(13, tint: .steel).textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.8)
        }
        .toggleStyle(BoneToggleStyle())
        .frame(height: 52)
    }

    private var whenPicker: some View {
        SheetChrome {
            VStack(spacing: 12) {
                DatePicker("When", selection: $when, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.wheel).labelsHidden()
                SecondaryButton("Done", size: .full) { editingWhen = false }
            }
            .padding(.horizontal, VSpace.gutter).padding(.top, 12)
        }
        .presentationDetents([.height(340)])
    }

    private func save() {
        guard !saving else { return }
        saving = true
        let tenths = tenths, when = when, alsoHealth = alsoHealth, store = store
        // The store outlives the sheet; it shows the toast and the server's block once the write settles.
        Task { await store.saveWeight(tenths: tenths, at: when, alsoHealth: alsoHealth) }
        dismiss()
    }
}

/// Ruler picker: a tick per 0.1 kg (major every 0.5 with its label), bone centre indicator, light haptic per step.
struct WeightRuler: View {
    @Binding var tenths: Int
    @State private var dragStart: Int?
    static let range = 200...3000
    private static let spacing: CGFloat = 10

    var body: some View {
        GeometryReader { g in
            let mid = g.size.width / 2
            let half = Int(mid / Self.spacing) + 1
            ZStack(alignment: .topLeading) {
                ForEach((tenths - half)...(tenths + half), id: \.self) { t in
                    let x = mid + CGFloat(t - tenths) * Self.spacing
                    let major = t % 5 == 0
                    Rectangle().fill(major ? VColor.tickMajor : VColor.future)
                        .frame(width: 1, height: major ? 26 : 14)
                        .position(x: x, y: 8 + (major ? 13 : 7))
                    if major {
                        Text(String(format: "%.1f", Double(t) / 10)).vLabel(.small)
                            .fixedSize().position(x: x, y: 50)
                    }
                }
                Rectangle().fill(VColor.bone).frame(width: 2, height: 44).position(x: mid, y: 22)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    let start = dragStart ?? tenths
                    dragStart = start
                    let next = start - Int((drag.translation.width / Self.spacing).rounded())
                    tenths = min(max(next, Self.range.lowerBound), Self.range.upperBound)
                }
                .onEnded { _ in dragStart = nil })
        }
        .sensoryFeedback(.selection, trigger: tenths)
        .accessibilityElement()
        .accessibilityLabel("Weight")
        .accessibilityValue("\(String(format: "%.1f", Double(tenths) / 10)) kilograms")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: tenths = min(tenths + 1, Self.range.upperBound)
            case .decrement: tenths = max(tenths - 1, Self.range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// Bone track with a black knob when on (frame 08); `future` track when off.
private struct BoneToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer(minLength: 12)
                Capsule().fill(configuration.isOn ? VColor.bone : VColor.future)
                    .frame(width: 46, height: 28)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? VColor.ground : VColor.steel).frame(width: 22, height: 22).padding(3)
                    }
                    .animation(.snappy(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

#Preview("Log weight") {
    Color.clear.sheet(isPresented: .constant(true)) {
        let store = BodyStore(api: { nil }, health: FakeHealthWriter(), writes: BodyPreviewWrites())
        let _ = store.preload(SleepBodyPreviewData.body)
        LogWeightSheet(store: store)
    }
    .vScreen().onAppear { VFont.register() }
}

#Preview("Log weight · no reading yet") {
    Color.clear.sheet(isPresented: .constant(true)) {
        let store = BodyStore(api: { nil }, health: FakeHealthWriter(), writes: BodyPreviewWrites())
        let _ = store.preload(SleepBodyPreviewData.noWeight)
        LogWeightSheet(store: store)
    }
    .vScreen().onAppear { VFont.register() }
}
