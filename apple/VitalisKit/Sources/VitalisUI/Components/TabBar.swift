import SwiftUI

public enum VTab: String, CaseIterable, Sendable, Identifiable {
    case today, sleep, body, train, eat
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var symbol: String {
        switch self {
        case .today: "waveform.path.ecg"
        case .sleep: "moon"
        case .body: "figure.stand"
        case .train: "dumbbell"
        case .eat: "fork.knife"
        }
    }
}

/// Five tabs: an outline icon over a small label; the active tab's icon turns pulse red and its label bone.
public struct TabBar: View {
    @Binding var selection: VTab
    public init(selection: Binding<VTab>) { _selection = selection }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(VColor.line).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(VTab.allCases) { tab in
                    let on = selection == tab
                    Button { selection = tab } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.symbol).font(.system(size: 20, weight: .regular))
                                .foregroundStyle(on ? VColor.pulse : VColor.muted).frame(height: 24)
                            Text(tab.name).vUI(11, weight: 600, color: on ? VColor.accent : VColor.muted).lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
                        .padding(.top, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.name)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: VSpace.tabBarHeight)
        .background(VColor.ground)
    }
}

/// Bottom-sheet chrome: grabber, sheet background, top rule. Pair with `.presentationDetents`.
public struct SheetChrome<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(VColor.future).frame(width: 36, height: 4).padding(.top, 10)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VColor.sheet)
        .presentationBackground(VColor.sheet)
        .presentationCornerRadius(VRadius.sheet)
        .presentationDragIndicator(.hidden)
    }
}

public extension View {
    /// Black ground, dark only (spec 30 platform rules).
    func vScreen() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(VColor.ground.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }
}
