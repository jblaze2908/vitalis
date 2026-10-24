import SwiftUI
import VitalisKit

@MainActor
struct SyncView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("State", value: model.snapshot.phase)
                    if let type = model.snapshot.currentType {
                        Text(shortName(type)).font(.caption).textSelection(.enabled)
                        LabeledContent("Page", value: "\(model.snapshot.page)")
                    }
                    if let date = model.snapshot.history.lastSuccess {
                        LabeledContent("Last successful upload") { Text(date, style: .relative) }
                    } else { Text("No successful uploads yet").foregroundStyle(.secondary) }
                    if let error = model.setupError ?? model.snapshot.history.lastError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Button("Allow Health access") { Task { await model.authorize() } }
                        .disabled(model.isAuthorizing || model.isSyncing)
                    Button("Sync now") { Task { await model.syncNow() } }.disabled(model.isSyncing)
                } header: { Text("Export") } footer: {
                    Text("The first sync backfills all readable history. HealthKit does not disclose which read permissions were denied.")
                }
                Section("Health types and background delivery") {
                    ForEach(model.snapshot.history.types.keys.sorted(), id: \.self) { id in
                        if let type = model.snapshot.history.types[id] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(shortName(id)).font(.subheadline)
                                Text("Sent \(type.objectsSent) · Deleted \(type.deletions)").font(.caption)
                                if let end = type.newestEnd { Text("Newest end: \(end)").font(.caption2) }
                                Text(type.backgroundDelivery).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Last 20 batches") {
                    ForEach(model.snapshot.history.batches) { batch in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(batch.date, format: .dateTime).font(.subheadline)
                            Text("\(batch.upserts) samples · \(batch.deletions) deletions · \(batch.dailyStats) daily stats").font(.caption)
                            Text(batch.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            ForEach(batch.counts.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(batch.counts[key] ?? 0)").font(.caption2)
                            }
                            ForEach(Array(batch.rejected.enumerated()), id: \.offset) { _, rejection in
                                Text("Rejected \(rejection.uuid): \(rejection.reason)").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                if !model.snapshot.history.diagnostics.isEmpty {
                    Section("Registry diagnostics") {
                        ForEach(Array(model.snapshot.history.diagnostics.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Vitalis Sync")
            .refreshable { await model.refresh() }
        }
    }
    private func shortName(_ id: String) -> String {
        id.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCorrelationTypeIdentifier", with: "")
    }
}
