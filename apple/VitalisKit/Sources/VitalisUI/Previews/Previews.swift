import SwiftUI

/// Example values for previews only (spec 30: fixtures, never HealthKit or network).
public enum VFixtures {
    public static let week: [WeekBars.Bar] = zip(["M", "T", "W", "T", "F", "S", "S"], [0.62, 0.8, 0.55, 0.9, 0.7, 0.35, 0.3]).enumerated()
        .map { i, p in WeekBars.Bar(id: "\(i)", letter: p.0, height: p.1, value: i == 6 ? "3.2K" : nil, isToday: i == 6) }
}

#Preview("Type roles") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Train legs").vHeadline(46)
        Text("78").vNumber(92)
        Text("3,206").vNumber(52)
        MonoLabel("Now · Ready", tint: .pulse)
        Text("HRV 62 ↑").vReading(tint: .good)
        Text("Everything is safe on this phone until it's fixed.").vBody()
        MonoLabel(VFont.isAvailable(VFont.archivoFamily) ? "Archivo registered" : "Archivo missing", tint: .watch)
    }
    .padding(VSpace.gutter).vScreen()
    .onAppear { VFont.register() }
}

#Preview("Buttons") {
    VStack(spacing: 16) {
        PrimaryButton("Start legs on Watch") {}
        PrimaryButton("Chicken rice bowl", value: "640") {}
        SecondaryButton("Log meal", size: .full) {}
        HStack { SecondaryButton("+ Log weight") {}; SecondaryButton("Remind me") {} }
        HStack { SecondaryButton("−15S", size: .mini) {}; SecondaryButton("Skip", size: .mini) {}; SecondaryButton("+15S", size: .mini) {} }
        HStack { SecondaryButton("Back", systemImage: "chevron.left", size: .icon) {}; SecondaryButton("Next", systemImage: "chevron.right", size: .icon, enabled: false) {} }
    }
    .padding(VSpace.gutter).vScreen()
    .onAppear { VFont.register() }
}

#Preview("Rows and bars") {
    VStack(alignment: .leading, spacing: 16) {
        ReadingRow("Sleep", value: "85")
        ReadingRow("HRV", value: "62", tint: .good, arrow: .up)
        ReadingRow("Resting", value: "57", tint: .watch, arrow: .up, showsRule: false)
        ProgressTrack(0.34)
        RangeBar(low: 0.3, high: 0.7, value: 0.85, tint: .watch)
        WeekBars(VFixtures.week)
        Toast("Added lunch · 640 kcal") {}
        Spacer()
        TabBar(selection: .constant(.today))
    }
    .padding(.top, VSpace.gutter).vScreen()
    .onAppear { VFont.register() }
}
