import SwiftUI
import VitalisKit
import VitalisUI

/// Rest (frame 32): countdown from a stored end date, the edge ring, ±15 and tap to skip.
struct RestScreen: View {
    let model: WorkoutModel
    let timer: RestTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                RestRing(inset: WatchLayout.ringInset, cornerRadius: WatchLayout.ringRadius)
                    .stroke(VColor.rule, lineWidth: WatchLayout.ringStroke)
                RestRing(inset: WatchLayout.ringInset, cornerRadius: WatchLayout.ringRadius)
                    .trim(from: 0, to: timer.fraction(at: context.date))
                    .stroke(VColor.pulse, style: StrokeStyle(lineWidth: WatchLayout.ringStroke, lineCap: .round))
                    .animation(.linear(duration: 1), value: timer.fraction(at: context.date))
                content(remaining: timer.remaining(at: context.date))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.skipRest() }
        .task(id: timer) {
            try? await Task.sleep(for: .seconds(timer.remaining(at: .now)))
            if !Task.isCancelled { model.restFinished(timer) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea()
        .vScreen()
    }

    private func content(remaining: TimeInterval) -> some View {
        VStack(spacing: 0) {
            MonoLabel("Rest").padding(.top, WatchLayout.restTop)
            Text(RestTimer.clockText(remaining)).vNumber(70).lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityLabel("\(Int(remaining.rounded(.up))) seconds of rest left")
            MonoLabel("Next").padding(.top, 6)
            Text(model.nextSetText).vHeadline(20).lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                adjust("−15", by: -RestTimer.step)
                Spacer(minLength: 4)
                MonoLabel("Tap to skip", size: .custom(9))
                Spacer(minLength: 4)
                adjust("+15", by: RestTimer.step)
            }
            .padding(.horizontal, WatchLayout.restSide)
            .padding(.bottom, WatchLayout.restBottom)
        }
        .padding(.horizontal, WatchLayout.side)
    }

    private func adjust(_ title: String, by delta: TimeInterval) -> some View {
        Button { model.adjustRest(by: delta) } label: { MonoLabel(title, tint: .bone) }
            .buttonStyle(.plain)
            .accessibilityLabel(delta > 0 ? "Add 15 seconds" : "Remove 15 seconds")
    }
}

/// Rounded rect whose path starts at top centre and runs clockwise, so `trim(from: 0, to:)` shrinks back toward the start.
struct RestRing: Shape {
    var inset: CGFloat
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = min(cornerRadius, r.width / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - c, y: r.minY + c), radius: c, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addArc(center: CGPoint(x: r.maxX - c, y: r.maxY - c), radius: c, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + c, y: r.maxY - c), radius: c, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addArc(center: CGPoint(x: r.minX + c, y: r.minY + c), radius: c, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

#Preview("Rest · 1:24 of 2:00") {
    let model = WorkoutModel.preview(.rest)
    if case .rest(let timer) = model.step {
        NavigationStack { RestScreen(model: model, timer: timer) }.onAppear { VFont.register() }
    }
}
