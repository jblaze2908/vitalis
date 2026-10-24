import SwiftUI
import VitalisKit
import VitalisUI

/// First run (spec 20 §4 Setup, frames 19–23): Welcome, Connect, Health, Reading history, Targets. `done` marks setup complete.
struct SetupFlow: View {
    @ObservedObject var model: AppModel
    var done: () -> Void
    @State private var store: SetupStore?

    var body: some View {
        Group {
            if let store {
                SetupSteps(store: store, done: done)
                    .onReceive(model.$snapshot) { store.observe($0) }
            } else {
                Color.clear
            }
        }
        .task { if store == nil { store = .live(model: model) } }
    }
}

/// Switches on the current step; each step is a full screen with the same chrome.
struct SetupSteps: View {
    @Bindable var store: SetupStore
    let done: () -> Void

    var body: some View {
        switch store.step {
        case .welcome: WelcomeStep(store: store)
        case .connect: ConnectStep(store: store)
        case .health: HealthStep(store: store)
        case .history: HistoryStep(store: store)
        case .targets: TargetsStep(store: store, done: done)
        }
    }
}

/// StatusRow, the progress PulseLine (not on Welcome or Reading history, per the frames), scrolling content, bottom action.
struct SetupChrome<Content: View, Action: View>: View {
    let step: SetupStep
    var showsPulse = true
    @ViewBuilder let content: Content
    @ViewBuilder let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusRow(step.statusLabel).padding(.top, VSpace.statusTop)
            if showsPulse, let pulse = step.pulse {
                PulseLine(events: pulse.events, now: pulse.now, style: .progress).padding(.top, 18)
            }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, VSpace.gutter)
                    .padding(.top, showsPulse && step.pulse != nil ? 8 : 40)
                    .padding(.bottom, VSpace.gutter)
            }
            .scrollBounceBehavior(.basedOnSize)
            action
                .padding(.horizontal, VSpace.gutter)
                .padding(.bottom, 44)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .vScreen()
    }
}

/// A mono key on the left, a reading value on the right, a rule under it (Health access and history rows).
struct SetupRow: View {
    let key: String
    let value: String
    var tint: VTint = .bone
    var verticalPadding: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(key).vReading(13, tint: .steel).textCase(.uppercase)
                Spacer(minLength: 12)
                Text(value).vReading(13, tint: tint).textCase(.uppercase).multilineTextAlignment(.trailing)
            }
            .padding(.vertical, verticalPadding)
            Rule()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews (fixtures only)

#if DEBUG
@MainActor
enum SetupPreview {
    /// Demo fixtures through `DemoURLProtocol`; nothing is saved and no network is used.
    static func store(_ step: SetupStep) -> SetupStore {
        let deps = SetupStore.Dependencies(
            makeAPI: { _ in VitalisAPI(baseURL: URL(string: "https://demo.vitalis.invalid")!, cache: nil, token: { "preview" },
                                       protocolClasses: [DemoURLProtocol.self]) },
            persist: { _, _ in })
        return SetupStore(deps: deps, step: step, serverText: "https://vitalis.example.com")
    }

    /// Connect-step errors: the host picks the reply (`s401`, `readonly`, `down`).
    static func failing(_ host: String) -> SetupStore {
        let deps = SetupStore.Dependencies(
            makeAPI: { _ in VitalisAPI(baseURL: URL(string: "https://\(host).preview.invalid")!, cache: nil, token: { "preview" },
                                       protocolClasses: [StatusURLProtocol.self]) },
            persist: { _, _ in })
        let store = SetupStore(deps: deps, step: .connect, serverText: "https://vitalis.example.com")
        store.tokenText = "preview-token"
        return store
    }
}

final class StatusURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host() ?? ""
        if host.hasPrefix("down") { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let (status, body) = host.hasPrefix("s401")
            ? (401, #"{"error":"Unauthorized","code":"unauthorized"}"#)
            : (200, #"{"token":{"scope":"ingest","can_push":true,"can_read":false,"can_write":false},"types":[],"batches":[]}"#)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

#Preview("Setup · welcome") {
    SetupSteps(store: SetupPreview.store(.welcome), done: {}).onAppear { VFont.register() }
}

#Preview("Setup · connect · connected") {
    let store = SetupPreview.store(.connect)
    store.tokenText = "preview-token"
    return SetupSteps(store: store, done: {}).task { await store.check() }.onAppear { VFont.register() }
}

#Preview("Setup · connect · invalid URL") {
    let store = SetupPreview.store(.connect)
    store.serverText = "vitalis example"
    store.tokenText = "preview-token"
    return SetupSteps(store: store, done: {}).task { await store.check() }.onAppear { VFont.register() }
}

#Preview("Setup · connect · token rejected") {
    let store = SetupPreview.failing("s401")
    return SetupSteps(store: store, done: {}).task { await store.check() }.onAppear { VFont.register() }
}

#Preview("Setup · connect · read-only token") {
    let store = SetupPreview.failing("readonly")
    return SetupSteps(store: store, done: {}).task { await store.check() }.onAppear { VFont.register() }
}

#Preview("Setup · connect · unreachable") {
    let store = SetupPreview.failing("down")
    return SetupSteps(store: store, done: {}).task { await store.check() }.onAppear { VFont.register() }
}

#Preview("Setup · health") {
    SetupSteps(store: SetupPreview.store(.health), done: {}).onAppear { VFont.register() }
}

#Preview("Setup · reading history") {
    let store = SetupPreview.store(.health)
    return SetupSteps(store: store, done: {})
        .task {
            await store.allowHealth()
            for snapshot in SettingsPreviewData.backfill { store.observe(snapshot) }
        }
        .onAppear { VFont.register() }
}

#Preview("Setup · targets") {
    let store = SetupPreview.store(.connect)
    store.tokenText = "preview-token"
    return SetupSteps(store: store, done: {})
        .task { await store.continueFromConnect(); store.goToTargets() }
        .onAppear { VFont.register() }
}
#endif
