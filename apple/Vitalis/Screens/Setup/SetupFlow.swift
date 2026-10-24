import SwiftUI
import VitalisKit
import VitalisUI

/// Stub until its task lands; owned by that task.
struct SetupFlow: View {
    @ObservedObject var model: AppModel
    var done: () -> Void
    var body: some View { TabPlaceholder(tab: .today).overlay(Text("Setup").vReading()) }
}
