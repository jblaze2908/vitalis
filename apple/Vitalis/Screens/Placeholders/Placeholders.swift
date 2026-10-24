import SwiftUI
import VitalisKit
import VitalisUI

/// Stand-in for each tab until its screen lands (I-07…I-12).
struct TabPlaceholder: View {
    let tab: VTab
    var settings: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(context: "Vitalis", title: tab.title) {
                if let settings { SecondaryButton("Settings", systemImage: "gearshape", size: .icon, action: settings) }
            }
            Text("This screen is on its way.").vBody()
        }
        .padding(.horizontal, VSpace.gutter).padding(.top, VSpace.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Stand-in for setup (I-05): the existing server settings, then Done.
struct SetupPlaceholder: View {
    @ObservedObject var model: AppModel
    let done: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            SettingsView(model: model)
            PrimaryButton("Done", action: done).padding(VSpace.gutter)
        }
    }
}
