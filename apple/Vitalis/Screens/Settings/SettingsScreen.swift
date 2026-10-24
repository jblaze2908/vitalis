import SwiftUI
import VitalisKit
import VitalisUI

/// Stub until its task lands; owned by that task.
struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    var body: some View { TabPlaceholder(tab: .today).overlay(Text("Settings").vReading()) }
}
