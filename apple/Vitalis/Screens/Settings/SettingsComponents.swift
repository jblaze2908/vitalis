import SwiftUI
import VitalisKit
import VitalisUI

/// A Settings or Sync row in a `ListCard`: key, value, chevron when it opens something.
/// A good or watch value shows as a status word so its colour carries.
struct SettingsRow: View {
    let key: String
    let value: String
    var tint: VTint = .bone
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    @ViewBuilder private var row: some View {
        switch tint {
        case .good: ListRow(key, chevron: action != nil) { StatusWord(value, tone: .good) }
        case .watch: ListRow(key, chevron: action != nil) { StatusWord(value, tone: .watch) }
        case .steel, .bone, .pulse: ListRow(key, value: value, chevron: action != nil)
        }
    }
}

/// A section label over a card of rows, on the gutter.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title)
            ListCard { content }.padding(.horizontal, VSpace.edge)
        }
    }
}

/// Top bar of a Settings page: Back on the left when it's a sub-page, the title centred, Done on the right on the root.
struct SettingsBar: View {
    let title: String
    var back: (() -> Void)? = nil
    var done: (() -> Void)? = nil
    var body: some View {
        ZStack {
            Text(title).vText(.title)
            HStack {
                if let back {
                    Button(action: back) {
                        HStack(spacing: VSpace.s1) {
                            Image(systemName: "chevron.left").font(.body.weight(.semibold))
                            Text("Settings").vText(.headline, color: VColor.text2)
                        }
                        .foregroundStyle(VColor.text2).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to Settings")
                }
                Spacer()
                if let done {
                    Button(action: done) { Text("Done").vText(.headline).frame(minHeight: 44).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
    }
}

/// One choice among several, or one toggle in a set: a chip lit when on.
struct ChoiceChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    init(_ title: String, on: Bool, action: @escaping () -> Void) { self.title = title; self.on = on; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).vText(.headline, color: on ? VColor.text : VColor.text2).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, VSpace.s3).padding(.vertical, VSpace.s2)
                .frame(maxWidth: .infinity)
                .background(on ? VColor.segmentOn : VColor.surface, in: RoundedRectangle(cornerRadius: VRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A big number or name typed over a hairline.
struct UnderlinedField: View {
    @Binding var text: String
    let prompt: String
    var style: VText = .numL
    var keyboard: UIKeyboardType = .decimalPad
    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.s2) {
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(VColor.text3))
                .vText(style).keyboardType(keyboard).tint(VColor.accent)
            Rectangle().fill(VColor.line).frame(height: 1)
        }
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
                Text(fields.count == 1 ? fields[0].title : "Weekly sets per muscle").vText(.title).padding(.top, VSpace.s3)
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: VSpace.s2) {
                        Text(fields.count == 1 ? (field.unit ?? "Value") : field.title).vText(.secondary)
                        if let choices = field.choices {
                            HStack(spacing: VSpace.s2) {
                                ForEach(choices, id: \.self) { c in
                                    ChoiceChip(field.format(c), on: texts[field] == field.editText(c)) { texts[field] = field.editText(c) }
                                }
                            }
                        } else {
                            UnderlinedField(text: binding(field), prompt: field.format(initial[field]),
                                            keyboard: field.isInteger ? .numberPad : .decimalPad)
                        }
                    }
                    .padding(.top, VSpace.s5)
                }
                if let error { Text(error).vText(.secondary, color: VColor.watch).padding(.top, VSpace.s3) }
                Spacer(minLength: VSpace.s5)
                if let extra {
                    SecondaryButton(extra.title, size: .full) { extra.action(); dismiss() }.padding(.bottom, VSpace.s3)
                }
                PrimaryButton("Save") { save() }
            }
            .padding(.horizontal, VSpace.edge)
            .padding(.bottom, VSpace.edge)
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
