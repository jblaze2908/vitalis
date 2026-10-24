import SwiftUI
import VitalisKit
import VitalisUI

/// Stub until its task lands; owned by that task.
struct BodyScreen: View {
    var body: some View { TabPlaceholder(tab: .today).overlay(Text("Body").vReading()) }
}
