import SwiftUI
import VitalisKit
import VitalisUI

/// Sync (frame 25, spec 20 §4): exporter status (the old SyncView, restyled), the outbox and its failed items,
/// and the token-rejected state with real counts.
struct SyncScreen: View {
    @ObservedObject var model: AppModel
    let sync: SyncStore
    @Environment(Router.self) private var router
    @Environment(Services.self) private var services
    @State private var replacing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsBar(title: "Sync", back: { if !router.settingsPath.isEmpty { router.settingsPath.removeLast() } })
                // This screen is about the phone's own uploads, so its last success stands in for a fetch time.
                FreshnessLine(DataFreshness(fetchedAt: sync.lastSuccess, refreshing: sync.isWorking))
                    .frame(maxWidth: .infinity).padding(.top, VSpace.s1)
                if sync.tokenRejected { rejected } else { exporter }
                queue
                failed
                types
                batches
            }
            .padding(.bottom, VSpace.s6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await model.refresh(); await sync.refresh() }
        .vScreen()
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(model.$snapshot) { sync.observe($0) }
        .task(id: services.outboxPending) { await sync.refresh() }
        .task { await sync.probe() }
        .sheet(isPresented: $replacing) { ReplaceTokenSheet(sync: sync) }
    }

    // MARK: Token rejected (frame 25)

    private var rejected: some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.s3) {
                StatusWord(["Token rejected", sync.rejectedSince.map { "since \(SyncStore.sinceLabel($0))" }].compactMap { $0 }
                    .joined(separator: " · "), tone: .watch)
                Text("Nothing is lost.").vText(.title)
                Text(SyncStore.waitingCopy(sync.counts)).vText(.body).fixedSize(horizontal: false, vertical: true)
                PrimaryButton("Replace token") { replacing = true }.padding(.top, VSpace.s2)
                SecondaryButton(sync.isWorking ? "Trying" : "Try again", size: .full, enabled: !sync.isWorking) {
                    Task { await sync.tryAgain() }
                }
            }
        }
        .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5)
    }

    // MARK: Healthy exporter (restyled SyncView)

    private var exporter: some View {
        let s = model.snapshot
        return VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Export") {
                SettingsRow(key: "State", value: s.phase)
                if let type = s.currentType {
                    SettingsRow(key: shortName(type), value: "Page \(s.page)")
                }
                SettingsRow(key: "Last upload", value: SyncStore.agoLabel(s.history.lastSuccess, now: Date()),
                            tint: s.history.lastSuccess == nil ? .steel : .good)
                if let error = model.setupError ?? s.history.lastError {
                    Text(error).vText(.secondary, color: VColor.watch).padding(.vertical, VSpace.s3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: VSpace.s3) {
                SecondaryButton("Sync now", size: .full, enabled: !model.isSyncing) { Task { await model.syncNow() } }
                SecondaryButton("Allow Health", size: .full, enabled: !(model.isAuthorizing || model.isSyncing)) {
                    Task { await model.authorize() }
                }
            }
            .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
            Text("The first sync backfills all readable history. HealthKit doesn't say which read permissions were denied.")
                .vText(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s2)
        }
    }

    // MARK: Waiting (both states)

    private var queue: some View {
        let c = sync.counts
        return SettingsGroup(title: "Waiting") {
            SettingsRow(key: "Server", value: reachability.text, tint: reachability.tint)
            SettingsRow(key: "Write token", value: sync.tokenRejected ? "Rejected (401)" : "In Keychain",
                        tint: sync.tokenRejected ? .watch : .bone)
            SettingsRow(key: "Waiting to upload", value: "\(c.exporterBatches.formatted()) \(c.exporterBatches == 1 ? "batch" : "batches")")
            SettingsRow(key: "Outbox", value: "\(c.outboxItems.formatted()) \(c.outboxItems == 1 ? "change" : "changes")")
            SettingsRow(key: "Watch sets held", value: c.watchSetsHeld.formatted())
        }
    }

    private var reachability: (text: String, tint: VTint) {
        switch sync.reachability {
        case .reachable: ("Reachable", .good)
        case .unreachable: ("Unreachable", .watch)
        case .unknown: ("–", .steel)
        }
    }

    // MARK: Failed outbox items (409/422 with the server's message)

    @ViewBuilder private var failed: some View {
        if !sync.failedItems.isEmpty {
            SettingsGroup(title: "Not accepted by the server") {
                ForEach(sync.failedItems) { item in
                    VStack(alignment: .leading, spacing: VSpace.s1) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(item.method) \(item.path)").vText(.body).lineLimit(1)
                            Spacer(minLength: VSpace.s2)
                            SecondaryButton("Dismiss", size: .compact) {
                                Task { try? await services.outbox?.dismissFailed(id: item.id); await sync.refresh() }
                            }
                        }
                        Text(item.lastError ?? "Rejected").vText(.secondary, color: VColor.watch)
                        Text(item.createdAt, format: .dateTime.day().month().hour().minute()).vText(.secondary)
                    }
                    .padding(.vertical, VSpace.s3)
                }
            }
        }
    }

    // MARK: Per type and last batches (restyled SyncView)

    @ViewBuilder private var types: some View {
        let history = model.snapshot.history
        if !history.types.isEmpty {
            SettingsGroup(title: "Health types") {
                ForEach(history.types.keys.sorted(), id: \.self) { id in
                    if let type = history.types[id] {
                        ListRow(shortName(id), subtitle: type.backgroundDelivery, value: "\(type.objectsSent.formatted()) sent", chevron: false)
                    }
                }
            }
        }
    }

    @ViewBuilder private var batches: some View {
        let history = model.snapshot.history
        if !history.batches.isEmpty {
            SettingsGroup(title: "Last 20 batches") {
                ForEach(history.batches) { batch in
                    VStack(alignment: .leading, spacing: VSpace.s1) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(batch.date, format: .dateTime.day().month().hour().minute()).vText(.body)
                            Spacer(minLength: VSpace.s2)
                            Text("\(batch.upserts.formatted()) samples").vText(.secondary)
                        }
                        Text("\(batch.deletions) deletions · \(batch.dailyStats) daily stats").vText(.secondary)
                        ForEach(Array(batch.rejected.enumerated()), id: \.offset) { _, r in
                            Text("Rejected \(r.uuid): \(r.reason)").vText(.secondary, color: VColor.watch)
                        }
                    }
                    .padding(.vertical, VSpace.s3)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func shortName(_ id: String) -> String {
        id.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCorrelationTypeIdentifier", with: "")
    }
}

// MARK: - Previews (fixtures only)

#if DEBUG
@MainActor
private enum SyncPreview {
    static let wednesday = ISO8601DateFormatter().date(from: "2026-10-21T10:42:00Z")!
    static var rejected: SyncStore {
        SyncStore(deps: .init(authFailureAt: { wednesday }, exporterPendingBatches: { 3 }, watchSetsHeld: { 16 },
                              probe: { throw APIError.unauthorized }))
    }
    static var healthy: SyncStore {
        SyncStore(deps: .init(exporterPendingBatches: { 0 }, probe: {
            guard let status = SettingsPreviewData.syncStatus else { throw APIError.notFound }
            return status
        }))
    }
}

#Preview("Sync · token rejected") {
    let store = SyncPreview.rejected
    return SyncScreen(model: .shared, sync: store)
        .environment(Router()).environment(Services.shared)
        .task { await store.refresh(); await store.probe() }
        .onAppear { VFont.register() }
}

#Preview("Sync · healthy") {
    let store = SyncPreview.healthy
    return SyncScreen(model: .shared, sync: store)
        .environment(Router()).environment(Services.shared)
        .task { store.observe(SettingsPreviewData.snapshot(newestEnd: "2026-10-24T21:30:00.000+05:30", sent: 5_475, phase: "Idle")) }
        .onAppear { VFont.register() }
}
#endif
