import SwiftUI

/// The one red action on a screen (rule 2). Hidden rather than disabled when it doesn't apply.
public struct PrimaryButton: View {
    let title: String
    let value: String?
    let icon: String?
    let height: CGFloat
    let fill: Color
    let ink: Color
    let action: () -> Void

    /// The one primary action on a screen: 52 high, 12 radius, in the tab's colour (accent unless Eat or Body).
    public init(_ title: String, value: String? = nil, icon: String? = nil, height: CGFloat = VSpace.buttonHeight,
                fill: Color = VColor.accent, ink: Color = VColor.onAccent, action: @escaping () -> Void) {
        self.title = title; self.value = value; self.icon = icon; self.height = height; self.fill = fill; self.ink = ink; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 17, weight: .semibold)) }
                Text(title).font(VFont.archivo(17, width: 100, weight: 700)).lineLimit(1).minimumScaleFactor(0.7)
                if let value { Spacer(); Text(value).font(VFont.archivo(17, width: 125, weight: 600)).monospacedDigit() }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, value == nil ? VSpace.s3 : VSpace.s4)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(fill, in: RoundedRectangle(cornerRadius: VRadius.inner, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

public enum SecondarySize: Sendable {
    /// 52 tall, full width.
    case full
    /// 40–44 tall, hugging its label.
    case compact
    /// 34 tall, radius 10, mono label (rest −15S / SKIP / +15S).
    case mini
    /// 36×36 icon square (day navigation); hit area 44.
    case icon
}

/// Outline button: inset 1.5 `future` stroke, bone label.
public struct SecondaryButton: View {
    let title: String
    let systemImage: String?
    let size: SecondarySize
    let enabled: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, size: SecondarySize = .compact, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.size = size; self.enabled = enabled; self.action = action
    }

    public var body: some View {
        Button(action: action) { label }
            .buttonStyle(PressStyle())
            .disabled(!enabled)
            .accessibilityLabel(title)
    }

    @ViewBuilder private var label: some View {
        let radius = size == .mini ? VRadius.mini : VRadius.button
        let stroke = RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: 0.75)
            .stroke(enabled ? VColor.future : VColor.rule, lineWidth: 1.5)
        switch size {
        case .full:
            HStack(spacing: 10) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 18, weight: .semibold)) }
                Text(title).vAction(20)
            }
            .foregroundStyle(VColor.bone).frame(maxWidth: .infinity, minHeight: VSpace.buttonHeight).overlay(stroke)
        case .compact:
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .bold)) }
                Text(title).vAction(16)
            }
            .foregroundStyle(VColor.bone).padding(.horizontal, 18).frame(minHeight: 42).overlay(stroke)
        case .mini:
            Text(title).vLabel(.standard, tint: .bone).padding(.horizontal, 12).frame(minHeight: 34).overlay(stroke)
        case .icon:
            Image(systemName: systemImage ?? "chevron.right").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? VColor.bone : VColor.disabled)
                .frame(width: 36, height: 36).overlay(stroke)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}
