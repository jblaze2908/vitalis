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
                Wordmark().padding(.top, 52)
                HeadlineLines(["Sleep, recovery, training", "and food.", "On a server you own."], size: 30,
                              colors: [VColor.bone, VColor.bone, VColor.steel])
                    .padding(.top, 18)
                VStack(spacing: 0) {
                    Rule()
                    feature("01", "Every raw sample from Apple Health")
                    feature("02", "Log sets on your Watch, see muscles light up")
                    feature("03", "Meals in seconds: usual, scan or describe")
                }
                .padding(.top, 18)
            }
        } action: {
            PrimaryButton("Get started") { store.step = .connect }
        }
    }

    private func feature(_ n: String, _ text: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                MonoLabel(n)
                Text(text).vBody(15, color: VColor.bone)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            Rule()
        }
    }
}

/// "Vitalis" with the pulse V (frame 19). VitalisUI has no wordmark component yet, so it's composed from type roles.
private struct Wordmark: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("V").vRole(.statusTime(58), color: VColor.pulse)
            Text("italis").vRole(.statusTime(58), color: VColor.bone)
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
                HeadlineLines(["Connect your", "server"], size: 44)
                Text("Your data goes straight to your own Vitalis server. Nothing else sees it.")
                    .vBody(15).padding(.top, 16)
                VStack(spacing: 0) {
                    Rule()
                    VStack(alignment: .leading, spacing: 8) {
                        MonoLabel("Server")
                        TextField("", text: $store.serverText, prompt: Text("https://vitalis.example.com").foregroundStyle(VColor.disabled))
                            .vReading(14)
                            .keyboardType(.URL).textContentType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .server).submitLabel(.next)
                            .onSubmit { focus = .token }
                    }
                    .padding(.vertical, 14)
                    Rule()
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 8) {
                            MonoLabel("Write token")
                            SecureField("", text: $store.tokenText, prompt: Text("Paste your token").foregroundStyle(VColor.disabled))
                                .vReading(14)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .token).submitLabel(.go)
                                .onSubmit { Task { await store.check() } }
                        }
                        Spacer(minLength: 12)
                        SecondaryButton("Paste") {
                            if let text = UIPasteboard.general.string { store.tokenText = text; Task { await store.check() } }
                        }
                    }
                    .padding(.vertical, 14)
                    Rule()
                }
                .padding(.top, 28)
                Text("No token yet? On your server run").vBody(14).padding(.top, 16)
                Text("vitalis token create iphone --scope write").vReading(13).padding(.top, 6)
                    .textSelection(.enabled)
                if let label = store.connect.label {
                    HStack(spacing: 10) {
                        if store.connect == .connected {
                            Image(systemName: "checkmark").vLabel(.custom(14), tint: .good)
                        }
                        MonoLabel(label, tint: store.connect.isError ? .watch : store.connect == .connected ? .good : .steel)
                    }
                    .padding(.top, 28)
                    .accessibilityElement(children: .combine)
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
                HeadlineLines(["Health access"], size: 44)
                Text("Vitalis reads every sample with its source and time zone. Meals you log go back into Health.")
                    .vBody(15).padding(.top, 16)
                VStack(spacing: 0) {
                    Rule()
                    ForEach(Self.areas, id: \.0) { SetupRow(key: $0.0, value: $0.1, verticalPadding: 15) }
                }
                .padding(.top, 24)
                Text("Apple only allows Health reads while your phone is unlocked, so the first sync is fastest with Vitalis open.")
                    .vBody(13).padding(.top, 18)
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
                HeadlineLines(["Reading your", "history"], size: 44)
                Text("Keep Vitalis open and your phone unlocked. Progress is saved if you leave.")
                    .vBody(15).padding(.top, 16)
                HStack(alignment: .lastTextBaseline) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(p.percent.map(String.init) ?? "–").vNumber(96, color: p.percent == nil ? VColor.steel : nil)
                        Text("%").vNumber(44)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 8) {
                        MonoLabel(p.done ? "Finished" : "Now reading")
                        Text(p.reading ?? "–").vReading(13, tint: p.reading == nil ? .steel : .bone)
                    }
                    .accessibilityElement(children: .combine)
                }
                .padding(.top, 36)
                PulseLine(now: Double(p.percent ?? 0) / 100, style: .progress).padding(.top, 24)
                HStack {
                    MonoLabel("First sample")
                    Spacer()
                    MonoLabel("Today")
                }
                .padding(.top, 10)
                VStack(spacing: 0) {
                    Rule()
                    SetupRow(key: "Samples sent", value: p.samplesSent)
                    SetupRow(key: "Time left", value: p.timeLeft ?? "–", tint: p.timeLeft == nil ? .steel : .bone)
                    SetupRow(key: "Server", value: store.connect == .connected ? "Connected" : "–",
                             tint: store.connect == .connected ? .good : .steel)
                }
                .padding(.top, 36)
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
                HeadlineLines(["Your targets"], size: 44)
                Text("Starting points from your history. You can change any of them later.")
                    .vBody(15).padding(.top, 16)
                VStack(spacing: 0) {
                    Rule()
                    ForEach(TargetField.setup) { field in
                        Button { editing = field } label: { row(field) }.buttonStyle(.plain)
                    }
                }
                .padding(.top, 24)
                if let error = store.targetsError {
                    MonoLabel(error.statusLine, tint: .watch).padding(.top, 16)
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
        return VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.title).vHeadline(22)
                    MonoLabel(store.draft.basis[field] ?? " ")
                }
                Spacer(minLength: 12)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(field.format(value)).vNumber(30, color: value == nil ? VColor.steel : nil)
                    if value != nil, let unit = field.unit { Text(unit).vNumber(16) }
                }
            }
            .padding(.vertical, 12)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
            Rule()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit")
    }
}
