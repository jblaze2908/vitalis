import SwiftUI
import VitalisKit
import VitalisUI

/// Stub until its task lands; owned by that task.
struct QuickAddSheet: View {
    var slot: String?
    var body: some View { TabPlaceholder(tab: .today).overlay(Text("Quick add").vReading()) }
}
