import SwiftUI
import VitalisKit
import VitalisUI

/// Settings/Sync row: steel key, tinted value, 10 pt vertical padding, rule under (frame 28).
struct SettingsRow: View {
    let key: String
    let value: String
    var tint: VTint = .bone
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { content.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(key).vReading(13, tint: .steel).textCase(.uppercase).lineLimit(2)
                Spacer(minLength: 12)
                Text(value).vReading(13, tint: tint).textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            Rule()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Mono group heading over its rows, rule on top of the first row.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoLabel(title).padding(.bottom, 8)
            Rule()
            content
        }
        .padding(.top, 28)
    }
}

/// "‹ SETTINGS" (frame 25).
struct SettingsBackLink: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left").vLabel(.custom(14))
                MonoLabel(title)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to \(title)")
    }
}

/// The header line: Today's cached pulse when there is one, else a flat line at the time of day.
struct CachedPulseLine: View {
    @State private var positions: (events: [Double], now: Double)?

    var body: some View {
        PulseLine(events: positions?.events ?? [], now: positions?.now ?? Self.dayFraction(Date()))
            .task {
                guard let pulse = await Services.shared.api?.cached(TodayResponse.self, path: "v2/today")?.value.pulse else { return }
                positions = PulseLine.positions(windowStart: pulse.window.start, windowEnd: pulse.window.end,
                                                now: pulse.now, events: pulse.events.map(\.at))
            }
    }

    /// Time → x over the local day (formatting only).
    static func dayFraction(_ date: Date, calendar: Calendar = .current) -> Double {
        PulseLine.fraction(at: date, start: calendar.startOfDay(for: date),
                           end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date)
    }
}

/// Edits one or two targets; Save validates against the server's ranges (10 §3) before anything is sent.
struct TargetEditSheet: View {
    let fields: [TargetField]
    let initial: [TargetField: Double]
    var extra: (title: String, action: () -> Void)? = nil
    let onSave: ([TargetField: Double]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var texts: [TargetField: String] = [:]
    @State private var error: String?

    var body: some View {
        SheetChrome {
            VStack(alignment: .leading, spacing: 0) {
                HeadlineLines([fields.count == 1 ? fields[0].title : "Weekly sets per muscle"], size: 30)
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 8) {
                        MonoLabel(fields.count == 1 ? (field.unit ?? "Value") : field.title)
                        if let choices = field.choices {
                            HStack(spacing: 8) {
                                ForEach(choices, id: \.self) { c in
                                    let on = texts[field] == field.editText(c)
                                    SecondaryButton(field.format(c), size: .mini) { texts[field] = field.editText(c) }
                                        .overlay(on ? RoundedRectangle(cornerRadius: VRadius.mini).stroke(VColor.bone, lineWidth: 1.5) : nil)
                                }
                            }
                        } else {
                            TextField("", text: binding(field), prompt: Text(field.format(initial[field])).foregroundStyle(VColor.disabled))
                                .vNumber(40)
                                .keyboardType(field.isInteger ? .numberPad : .decimalPad)
                        }
                        Rule()
                    }
                    .padding(.top, 24)
                }
                if let error { MonoLabel(error, tint: .watch).padding(.top, 12) }
                Spacer(minLength: 24)
                if let extra {
                    SecondaryButton(extra.title, size: .full) { extra.action(); dismiss() }.padding(.bottom, 12)
                }
                PrimaryButton("Save") { save() }
            }
            .padding(.horizontal, VSpace.gutter)
            .padding(.top, 20)
            .padding(.bottom, VSpace.gutter)
        }
        .presentationDetents([.medium, .large])
        .onAppear { for f in fields where texts[f] == nil { texts[f] = f.editText(initial[f]) } }
    }

    private func binding(_ field: TargetField) -> Binding<String> {
        Binding(get: { texts[field] ?? "" }, set: { texts[field] = $0; error = nil })
    }

    private func save() {
        var values: [TargetField: Double] = [:]
        for field in fields {
            guard let v = Double((texts[field] ?? "").replacingOccurrences(of: ",", with: ".")) else {
                error = "\(field.title) · Enter a number"; return
            }
            values[field] = v
        }
        let checked = TargetField.patch(values)
        if let message = checked.error { error = message; return }
        onSave(values)
        dismiss()
    }
}

// MARK: - Preview fixtures

#if DEBUG
/// Decoded DemoData responses and exporter snapshots for previews.
enum SettingsPreviewData {
    static func demo<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? APICoding.decoder().decode(T.self, from: data)
    }
    static var targets: TargetsResponse? { demo(TargetsResponse.self, "targets") }
    static var syncStatus: SyncStatus? { demo(SyncStatus.self, "sync-status") }

    static func snapshot(type: String = "HKQuantityTypeIdentifierStepCount", newestEnd: String, sent: Int, phase: String = "Backfilling") -> SyncSnapshot {
        var history = SyncHistory()
        var t = TypeHistory(); t.objectsSent = sent; t.newestEnd = newestEnd; t.backgroundDelivery = "Enabled: immediate"
        history.types[type] = t
        var hrv = TypeHistory(); hrv.objectsSent = 2_190; hrv.newestEnd = "2026-10-24T05:10:00.000+05:30"
        history.types["HKQuantityTypeIdentifierHeartRateVariabilitySDNN"] = hrv
        history.lastSuccess = Date().addingTimeInterval(-120)
        return SyncSnapshot(phase: phase, currentType: phase == "Idle" ? nil : type, page: 12, history: history)
    }

    /// Two pages of a backfill: the first sets "oldest seen", the second is the page being read (≈ 62%).
    static var backfill: [SyncSnapshot] {
        [snapshot(newestEnd: "2019-01-01T00:00:00.000+05:30", sent: 400_000),
         snapshot(newestEnd: "2023-03-14T00:00:00.000+05:30", sent: 1_840_000)]
    }
}
#endif
