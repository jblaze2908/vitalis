import SwiftUI
import UIKit
import VitalisKit
import VitalisUI

/// Settings (frame 28, spec 20 §4): server, targets and training via GET/PUT /v2/targets, start choice, reset, token, credits.
struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    @Environment(Router.self) private var router
    @Environment(Services.self) private var services
    @State private var targets: Loadable<TargetsResponse>
    private let sync: SyncStore
    @State private var editing: SettingsEdit?
    @State private var replacing = false
    @State private var settingGoal = false
    @State private var confirmReset = false
    @State private var message: String?

    init(model: AppModel) { self.init(model: model, targets: nil, sync: .shared) }

    init(model: AppModel, targets: TargetsResponse?, sync: SyncStore) {
        self.model = model; self.sync = sync
        _targets = State(initialValue: Loadable(targets))
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.settingsPath) {
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await load() }
                .vScreen()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: SettingsPage.self) { page in
                    switch page {
                    case .sync: SyncScreen(model: model, sync: sync)
                    case .splits: SplitsScreen()
                    }
                }
        }
        .onReceive(model.$snapshot) { sync.observe($0) }
        .task(id: services.writesVersion) { await load() }
        .sheet(item: $editing) { edit in editSheet(edit) }
        .sheet(isPresented: $replacing) { ReplaceTokenSheet(sync: sync) }
        .sheet(isPresented: $settingGoal) { GoalSheet(targets: targets.value) }
        .confirmationDialog("Reset export state and backfill again?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset local export state", role: .destructive) {
                Task {
                    do { try await model.resetExport(); message = "Local export state reset" }
                    catch { message = "Couldn't reset · \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("Removes local anchors, pending uploads, cached screens and sync history, then backfills everything again. Server data stays.")
        }
    }

    private var content: some View {
        let t = targets.value
        return VStack(alignment: .leading, spacing: 0) {
            SettingsBar(title: "Settings", done: { router.showsSettings = false })
            FreshnessLine(DataFreshness(fetchedAt: targets.fetchedAt, refreshing: targets.isLoading))
                .frame(maxWidth: .infinity).padding(.top, VSpace.s1)
            if sync.tokenRejected {
                Text("Sync paused").vText(.secondary, color: VColor.watch).frame(maxWidth: .infinity).padding(.top, VSpace.s1)
            }
            if let error = targets.error as? APIError, t != nil {
                Text(error.statusLine).vText(.secondary, color: VColor.watch).padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
            }

            SettingsGroup(title: "Server") {
                SettingsRow(key: "Server", value: host)
                SettingsRow(key: "Write token", value: sync.tokenRejected ? "Rejected" : "In Keychain",
                            tint: sync.tokenRejected ? .watch : .bone) { replacing = true }
                SettingsRow(key: "Sync", value: syncValue.text, tint: syncValue.tint) { router.settingsPath.append(.sync) }
            }

            SettingsGroup(title: "Targets") {
                row(.steps, t.flatMap { v in (v.values.steps ?? v.effective.steps).map(Double.init) })
                SettingsRow(key: "Calories", value: calories(t), tint: t?.effective.kcal == nil ? .steel : .bone) { editing = .target(.kcal) }
                row(.proteinG, t?.effective.proteinG)
                row(.sleepNeedH, t?.effective.sleepNeedH)
                SettingsRow(key: "Goal", value: Self.goalText(t), tint: t?.values.goal == nil && t?.values.goalWeightKg == nil ? .steel : .bone) {
                    settingGoal = true
                }
            }

            SettingsGroup(title: "Training") {
                SettingsRow(key: "Weekly sets per muscle", value: weeklySets(t), tint: t?.values.weeklySetsMin == nil ? .steel : .bone) {
                    editing = .weeklySets
                }
                row(.restS, t?.values.restS.map(Double.init), key: "Default rest")
                row(.crownStepKg, t?.values.crownStepKg)
                SettingsRow(key: "Splits", value: "Edit") { router.settingsPath.append(.splits) }
            }

            SectionLabel("This phone")
            VStack(spacing: VSpace.s3) {
                SecondaryButton("Replace token", size: .full) { replacing = true }
                SecondaryButton("Reset local export state", size: .full) { confirmReset = true }
                if let message { Text(message).vText(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(.horizontal, VSpace.edge)

            SettingsGroup(title: "Acknowledgements") {
                ForEach(VAcknowledgements.lines, id: \.title) { line in
                    VStack(alignment: .leading, spacing: VSpace.s1) {
                        Text(line.title).vText(.headline)
                        Text(line.detail).vText(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, VSpace.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }

            Text("Vitalis \(Self.version) · Personal build").vText(.secondary)
                .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5)
        }
        .padding(.bottom, VSpace.s6)
    }

    // MARK: Rows

    private func row(_ field: TargetField, _ value: Double?, key: String? = nil) -> some View {
        SettingsRow(key: key ?? field.title.replacingOccurrences(of: " a day", with: ""), value: Self.show(field, value),
                    tint: value == nil ? .steel : .bone) { editing = .target(field) }
    }

    static func show(_ field: TargetField, _ value: Double?) -> String {
        guard let value else { return "–" }
        return [field.format(value), field == .restS ? nil : field.unit].compactMap { $0 }.joined(separator: " ")
    }

    private func calories(_ t: TargetsResponse?) -> String {
        let kcal = Self.show(.kcal, t?.effective.kcal.map(Double.init))
        return t?.values.kcalMode == "adaptive" ? "Adaptive · \(kcal)" : kcal
    }

    private func weeklySets(_ t: TargetsResponse?) -> String {
        guard let lo = t?.values.weeklySetsMin, let hi = t?.values.weeklySetsMax else { return "–" }
        return "\(lo)–\(hi)"
    }

    /// "Lose · 80.0 kg", "Maintain", or "Set" when neither is stored.
    static func goalText(_ t: TargetsResponse?) -> String {
        let goal = (t?.values.goal ?? t?.plan?.goal)?.capitalized
        let kg = t?.values.goalWeightKg.map { String(format: "%.1f kg", $0) }
        let parts = [goal, goal == "Maintain" ? nil : kg].compactMap { $0 }
        return parts.isEmpty ? "Set" : parts.joined(separator: " · ")
    }


    private var host: String {
        (try? ServerSettings(SettingsStore.baseURL))?.baseURL.host() ?? "–"
    }

    private var syncValue: (text: String, tint: VTint) {
        if sync.tokenRejected { return ("Paused", .watch) }
        let stale = sync.staleState(lastSync: APIDate.parse(targets.value?.freshness?.lastSync), cachedAt: nil, refreshFailed: false).isStale
        return (SyncStore.agoLabel(sync.lastSuccess, now: Date()), stale ? .watch : .good)
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–" }

    // MARK: Data

    private func load() async {
        guard let api = services.api else { return }
        await targets.load(cached: { await api.cached(TargetsResponse.self, path: "v2/targets") }) { try await api.targets() }
    }

    @ViewBuilder private func editSheet(_ edit: SettingsEdit) -> some View {
        let t = targets.value
        switch edit {
        case .weeklySets:
            TargetEditSheet(fields: [.weeklySetsMin, .weeklySetsMax],
                            initial: [.weeklySetsMin: t?.values.weeklySetsMin.map(Double.init), .weeklySetsMax: t?.values.weeklySetsMax.map(Double.init)]
                                .compactMapValues { $0 }) { save($0) }
        case .target(.kcal):
            TargetEditSheet(fields: [.kcal], initial: [.kcal: t?.effective.kcal.map(Double.init)].compactMapValues { $0 },
                            extra: ("Use adaptive", { useAdaptive() })) { save($0) }
        case .target(let field):
            TargetEditSheet(fields: [field], initial: [field: current(field, t)].compactMapValues { $0 }) { save($0) }
        }
    }

    private func current(_ field: TargetField, _ t: TargetsResponse?) -> Double? {
        switch field {
        case .steps: (t?.values.steps ?? t?.effective.steps).map(Double.init)
        case .kcal: t?.effective.kcal.map(Double.init)
        case .proteinG: t?.effective.proteinG
        case .sleepNeedH: t?.effective.sleepNeedH
        case .goalWeightKg: t?.values.goalWeightKg
        case .weeklySetsMin: t?.values.weeklySetsMin.map(Double.init)
        case .weeklySetsMax: t?.values.weeklySetsMax.map(Double.init)
        case .restS: t?.values.restS.map(Double.init)
        case .crownStepKg: t?.values.crownStepKg
        }
    }

    /// PUT through the outbox; `writesVersion` bumps on delivery and the task above refetches.
    private func save(_ values: [TargetField: Double]) {
        guard let patch = TargetField.patch(values).patch, let request = try? APIRequest.putTargets(patch) else { return }
        Task { await services.send(request) }
    }

    private func useAdaptive() {
        var patch = TargetsPatch()
        patch.kcalMode = .set("adaptive")
        patch.kcal = .clear
        guard let request = try? APIRequest.putTargets(patch) else { return }
        Task { await services.send(request) }
    }
}

enum SettingsEdit: Identifiable, Hashable {
    case target(TargetField)
    case weeklySets
    var id: String {
        switch self { case .target(let f): f.rawValue; case .weeklySets: "weeklySets" }
    }
}

/// Secure field → Keychain → resume (spec 20 §4). The token is held only in this sheet's state and cleared on save.
struct ReplaceTokenSheet: View {
    let sync: SyncStore
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var confirmRemove = false
    @AppStorage("setupCompleted") private var setupCompleted = false

    var body: some View {
        SheetChrome {
            VStack(alignment: .leading, spacing: 0) {
                Text("Replace token").vText(.title)
                Text("Paste a new write token. It's kept in this phone's Keychain and never shown again.")
                    .vText(.body).fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s3)
                ListCard {
                    HStack {
                        VStack(alignment: .leading, spacing: VSpace.s1) {
                            Text("Write token").vText(.secondary)
                            SecureField("", text: $token, prompt: Text("Paste your token").foregroundStyle(VColor.text3))
                                .vText(.body)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Spacer(minLength: VSpace.s3)
                        SecondaryButton("Paste") { if let s = UIPasteboard.general.string { token = s } }
                    }
                    .padding(.vertical, VSpace.s3)
                }
                .padding(.top, VSpace.s5)
                Text("vitalis token create iphone --scope write").vText(.secondary).textSelection(.enabled).padding(.top, VSpace.s3)
                if let error { Text(error).vText(.secondary, color: VColor.watch).padding(.top, VSpace.s3) }
                Spacer(minLength: VSpace.s5)
                SecondaryButton("Remove token", size: .full) { confirmRemove = true }.padding(.bottom, VSpace.s3)
                PrimaryButton(sync.isWorking ? "Checking" : "Save token") { Task { await save() } }
            }
            .padding(.horizontal, VSpace.edge)
            .padding(.top, VSpace.s5)
            .padding(.bottom, VSpace.edge)
        }
        .presentationDetents([.large])
        .confirmationDialog("Remove the token from this phone?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove token", role: .destructive) {
                // Clearing the token sends the app back to setup's Connect step (spec 20 §4).
                guard (try? TokenStore.save("")) != nil else { error = "Couldn't remove the token"; return }
                setupCompleted = false
                dismiss()
            }
        } message: {
            Text("Uploads stop until you connect again. Nothing waiting on this phone is deleted.")
        }
    }

    private func save() async {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { error = "Paste a write token"; return }
        do {
            try await sync.replaceToken(value)
            token = ""
            dismiss()
        } catch {
            self.error = "Couldn't save the token · unlock your phone and try again"
        }
    }
}

// MARK: - Previews (fixtures only)

#if DEBUG
#Preview("Settings") {
    SettingsScreen(model: .shared, targets: SettingsPreviewData.targets, sync: SyncStore(deps: .init()))
        .environment(Router())
        .environment(Services.shared)
        .onAppear { VFont.register() }
}

#Preview("Settings · targets missing") {
    SettingsScreen(model: .shared, targets: nil, sync: SyncStore(deps: .init()))
        .environment(Router())
        .environment(Services.shared)
        .onAppear { VFont.register() }
}

#Preview("Settings · edit steps") {
    TargetEditSheet(fields: [.steps], initial: [.steps: 9_000]) { _ in }
        .onAppear { VFont.register() }
}
#endif
