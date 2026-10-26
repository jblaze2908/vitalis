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
                titleRow.padding(.top, VSpace.s4)
                Figure(kgText, unit: "kg", size: 56)
                    .padding(.top, VSpace.s5)
                    .accessibilityHidden(true)
                if let caption { Text(caption).vText(.secondary).padding(.top, VSpace.s2).lineLimit(1).minimumScaleFactor(0.8) }
                WeightRuler(tenths: $tenths).frame(height: 60).padding(.top, VSpace.s4)
                ListCard {
                    whenRow
                    healthRow
                }
                .gutter()
                .padding(.top, VSpace.s5)
                Spacer(minLength: VSpace.s3)
                PrimaryButton("Save \(kgText) kg", fill: VColor.body, ink: VColor.onBody, action: save)
                    .gutter()
                    .padding(.bottom, VSpace.s6)
            }
        }
        .presentationDetents([.height(540)])
        .sheet(isPresented: $editingWhen) { whenPicker }
    }

    private var titleRow: some View {
        ZStack {
            Text("Log weight").vText(.title)
            HStack {
                Button { dismiss() } label: { Text("Cancel").vText(.body).frame(minHeight: 44) }.buttonStyle(.plain)
                Spacer()
            }
        }
        .gutter()
    }

    /// `Last 76.8 Yesterday · Trend 76.4` from the server's weight block.
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
            ListRow("When", value: "\(StaleState.dayLabel(when, now: Date(), calendar: .current)) · \(StaleState.clock(when, calendar: .current))")
        }
        .buttonStyle(.plain)
        .accessibilityHint("Changes when the weight was measured")
    }

    private var healthRow: some View {
        Toggle(isOn: $alsoHealth) {
            Text("Also save to Apple Health").vText(.body).lineLimit(1).minimumScaleFactor(0.8)
        }
        .toggleStyle(BodyToggleStyle())
        .frame(minHeight: VSpace.rowMin).padding(.vertical, VSpace.s3)
    }

    private var whenPicker: some View {
        SheetChrome {
            VStack(spacing: VSpace.s3) {
                DatePicker("When", selection: $when, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.wheel).labelsHidden()
                SecondaryButton("Done", size: .full) { editingWhen = false }
            }
            .gutter().padding(.top, VSpace.s3)
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

/// Ruler picker: a tick per 0.1 kg (major every 0.5 with its label), a text-colour centre indicator, light haptic per step.
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
                    Rectangle().fill(major ? VColor.text3 : VColor.dashed)
                        .frame(width: 1, height: major ? 26 : 14)
                        .position(x: x, y: 8 + (major ? 13 : 7))
                    if major {
                        Text(String(format: "%.1f", Double(t) / 10)).vText(.axis)
                            .fixedSize().position(x: x, y: 50)
                    }
                }
                Rectangle().fill(VColor.text).frame(width: 2, height: 44).position(x: mid, y: 22)
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

/// Body-violet track when on, bar track when off; the knob in text colour.
private struct BodyToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer(minLength: VSpace.s3)
                Capsule().fill(configuration.isOn ? VColor.body : VColor.barTrack)
                    .frame(width: 46, height: 28)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? VColor.text : VColor.text2).frame(width: 22, height: 22).padding(3)
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
