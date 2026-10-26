import SwiftUI
import VitalisKit
import VitalisUI

/// Stand-in for each tab until its screen lands (I-07…I-12). The header carries the Settings button.
struct TabPlaceholder: View {
    let tab: VTab
    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.s4) {
            VHeader(tab.title)
            Text("This screen is on its way.").vText(.body).padding(.horizontal, VSpace.edge)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
