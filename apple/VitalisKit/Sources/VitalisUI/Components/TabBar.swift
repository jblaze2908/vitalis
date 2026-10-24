import SwiftUI

public enum VTab: String, CaseIterable, Sendable, Identifiable {
    case today, sleep, body, train, eat
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
}

/// Custom five-tab bar: labels only, a 22×2 pulse bar over the active tab. 83 tall including the home-indicator area.
public struct TabBar: View {
    @Binding var selection: VTab
    public init(selection: Binding<VTab>) { _selection = selection }

    public var body: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 0) {
                ForEach(VTab.allCases) { tab in
                    Button { selection = tab } label: {
                        VStack(spacing: 14) {
                            Rectangle().fill(selection == tab ? VColor.pulse : .clear).frame(width: 22, height: 2)
                            Text(tab.title).vLabel(.small, tint: selection == tab ? .bone : .steel).lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .offset(y: -1)
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
