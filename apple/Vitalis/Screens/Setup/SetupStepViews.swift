import SwiftUI
import UIKit
import VitalisKit
import VitalisUI

// MARK: 19 · Welcome

struct WelcomeStep: View {
    let store: SetupStore
    /// Example heat for the hero figure (frame 19), not the owner's data.
    private static let exampleHeat: [String: Int] = [
        "chest": 4, "shoulders": 3, "triceps": 2, "biceps": 2, "lats": 2, "traps": 2,
        "quadriceps": 1, "hamstrings": 1, "glutes": 1, "calves": 1, "adductors": 1,
    ]

    var body: some View {
        SetupChrome(step: .welcome) {
            VStack(alignment: .leading, spacing: 0) {
                MuscleMap(heat: Self.exampleHeat).frame(height: 290).frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Wordmark().padding(.top, VSpace.s7)
                SetupHeadline(["Sleep, recovery, training", "and food.", "On a server you own."], dimmedFrom: 2)
                    .padding(.top, VSpace.s4)
                ListCard {
                    feature("01", "Every raw sample from Apple Health")
                    feature("02", "Log sets on your Watch, see muscles light up")
                    feature("03", "Meals in seconds: usual, scan or describe")
                }
                .padding(.top, VSpace.s5)
            }
        } action: {
            PrimaryButton("Get started") { store.step = .connect }
        }
    }

    private func feature(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VSpace.s4) {
            Text(n).vText(.secondary)
            Text(text).vText(.body)
            Spacer(minLength: 0)
        }
        .padding(.vertical, VSpace.s3)
        .accessibilityElement(children: .combine)
    }
}

/// "Vitalis" with the pulse V (frame 19): a logo, so it keeps its own size outside the type scale.
private struct Wordmark: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("V").font(VFont.archivo(58, width: 100, weight: 600)).foregroundStyle(VColor.accent)
            Text("italis").font(VFont.archivo(58, width: 100, weight: 600)).foregroundStyle(VColor.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vitalis")
    }
}

// MARK: 20 · Connect server

struct ConnectStep: View {
    @Bindable var store: SetupStore
    @FocusState private var focus: Field?
    private enum Field { case server, token }

    var body: some View {
        SetupChrome(step: .connect) {
            VStack(alignment: .leading, spacing: 0) {
                SetupHeadline(["Connect your", "server"])
                Text("Your data goes straight to your own Vitalis server. Nothing else sees it.")
                    .vText(.body).fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s4)
                ListCard {
                    VStack(alignment: .leading, spacing: VSpace.s1) {
                        Text("Server").vText(.secondary)
                        TextField("", text: $store.serverText, prompt: Text("https://vitalis.example.com").foregroundStyle(VColor.text3))
                            .vText(.body)
                            .keyboardType(.URL).textContentType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .server).submitLabel(.next)
                            .onSubmit { focus = .token }
                    }
                    .padding(.vertical, VSpace.s3)
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: VSpace.s1) {
                            Text("Write token").vText(.secondary)
                            SecureField("", text: $store.tokenText, prompt: Text("Paste your token").foregroundStyle(VColor.text3))
                                .vText(.body)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .token).submitLabel(.go)
                                .onSubmit { Task { await store.check() } }
                        }
                        Spacer(minLength: VSpace.s3)
                        SecondaryButton("Paste") {
                            if let text = UIPasteboard.general.string { store.tokenText = text; Task { await store.check() } }
                        }
                    }
                    .padding(.vertical, VSpace.s3)
                }
                .padding(.top, VSpace.s5)
                Text("No token yet? On your server run").vText(.secondary).padding(.top, VSpace.s4)
                Text("vitalis token create iphone --scope write").vText(.body).padding(.top, VSpace.s1)
                    .textSelection(.enabled)
                if let label = store.connect.label {
                    StatusWord(label, tone: store.connect.isError ? .watch : store.connect == .connected ? .good : .quiet)
                        .padding(.top, VSpace.s5)
                }
            }
        } action: {
            PrimaryButton("Continue") { focus = nil; Task { await store.continueFromConnect() } }
        }
    }
}

// MARK: 21 · Health access

struct HealthStep: View {
    let store: SetupStore
    private static let areas: [(String, String)] = [
        ("Sleep", "Every stage"), ("Heart", "HR · HRV · Resting · SpO2"), ("Activity", "Steps · Energy · Exercise"),
        ("Workouts", "Routes · Heartbeats"), ("Body", "Weight · Temperature"), ("Nutrition", "Read + write"),
    ]

    var body: some View {
        SetupChrome(step: .health) {
            VStack(alignment: .leading, spacing: 0) {
                SetupHeadline(["Health access"])
                Text("Vitalis reads every sample with its source and time zone. Meals you log go back into Health.")
                    .vText(.body).fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s4)
                ListCard {
                    ForEach(Self.areas, id: \.0) { ListRow($0.0, subtitle: $0.1, chevron: false) }
                }
                .padding(.top, VSpace.s5)
                Text("Apple only allows Health reads while your phone is unlocked, so the first sync is fastest with Vitalis open.")
                    .vText(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s4)
            }
        } action: {
            PrimaryButton("Allow in Health") { Task { await store.allowHealth() } }
                .disabled(store.isAuthorizing)
        }
    }
}

// MARK: 22 · Reading your history

struct HistoryStep: View {
    let store: SetupStore

    var body: some View {
        historyBody
            // A relaunch mid-backfill leaves the exporter idle until something asks; this step asks.
            .task { await AppModel.shared.syncNow() }
    }

    @ViewBuilder private var historyBody: some View {
        let p = store.progress()
        SetupChrome(step: .history, showsPulse: false) {
            VStack(alignment: .leading, spacing: 0) {
                SetupHeadline(["Reading your", "history"])
                Text("Keep Vitalis open and your phone unlocked. Progress is saved if you leave.")
                    .vText(.body).fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s4)
                HStack(alignment: .lastTextBaseline) {
                    Figure(p.percent.map(String.init) ?? FoodFormat.dash, unit: "%", size: 56, color: p.percent == nil ? VColor.text3 : nil)
                    Spacer(minLength: VSpace.s2)
                    VStack(alignment: .trailing, spacing: VSpace.s1) {
                        Text(p.done ? "Finished" : "Now reading").vText(.secondary)
                        Text(p.reading ?? FoodFormat.dash).vText(.body, color: p.reading == nil ? VColor.text3 : nil)
                    }
                    .accessibilityElement(children: .combine)
                }
                .padding(.top, VSpace.s6)
                PulseLine(now: Double(p.percent ?? 0) / 100, style: .progress).padding(.top, VSpace.s5)
                HStack {
                    Text("First sample").vText(.secondary)
                    Spacer()
                    Text("Today").vText(.secondary)
                }
                .padding(.top, VSpace.s2)
                ListCard {
                    SetupRow(key: "Samples sent", value: p.samplesSent)
                    SetupRow(key: "Time left", value: p.timeLeft ?? FoodFormat.dash, tint: p.timeLeft == nil ? .steel : .bone)
                    SetupRow(key: "Server", value: store.connect == .connected ? "Connected" : FoodFormat.dash,
                             tint: store.connect == .connected ? .good : .steel)
                }
                .padding(.top, VSpace.s6)
            }
        } action: {
            SecondaryButton(p.done ? "Set targets" : "Set targets while this runs", size: .full) { store.goToTargets() }
        }
    }
}

// MARK: 23 · Targets

struct TargetsStep: View {
    let store: SetupStore
    let done: () -> Void
    @State private var editing: TargetField?

    var body: some View {
        SetupChrome(step: .targets) {
            VStack(alignment: .leading, spacing: 0) {
                SetupHeadline(["Your targets"])
                Text("Starting points from your history. You can change any of them later.")
                    .vText(.body).fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s4)
                ListCard {
                    ForEach(TargetField.setup) { field in
                        Button { editing = field } label: { row(field) }.buttonStyle(.plain)
                    }
                }
                .padding(.top, VSpace.s5)
                if let error = store.targetsError {
                    Text(error.statusLine).vText(.secondary, color: VColor.watch).padding(.top, VSpace.s4)
                }
            }
        } action: {
            PrimaryButton("Finish") { Task { await store.finish(done: done) } }
        }
        .task { await store.loadTargets() }
        .sheet(item: $editing) { field in
            TargetEditSheet(fields: [field], initial: [field: store.draft.value(field)].compactMapValues { $0 }) { values in
                if let v = values[field] { store.setTarget(field, v) }
            }
        }
    }

    private func row(_ field: TargetField) -> some View {
        let value = store.draft.value(field)
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.title).vText(.headline)
                if let basis = store.draft.basis[field] { Text(basis).vText(.secondary) }
            }
            Spacer(minLength: VSpace.s3)
            Figure(field.format(value), unit: value == nil ? nil : field.unit, size: 20, color: value == nil ? VColor.text3 : nil)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(VColor.chevron)
        }
        .frame(minHeight: VSpace.rowMin).padding(.vertical, VSpace.s3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit")
    }
}
