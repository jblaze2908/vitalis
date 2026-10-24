import SwiftUI
import VitalisKit
import VitalisUI

/// Stub until its task lands; owned by that task.
struct TodayScreen: View {
    var body: some View { TabPlaceholder(tab: .today).overlay(Text("Today").vReading()) }
}
