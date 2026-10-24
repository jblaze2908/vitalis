import CoreText
import Foundation
import Synchronization
import SwiftUI

/// Archivo (variable wdth/wght) and Azeret Mono (variable wght), bundled under the SIL OFL 1.1.
/// CoreText is used directly because `Font.custom` cannot set the width axis, and it behaves the same on iOS and watchOS.
public enum VFont {
    public static let archivoFamily = "Archivo"
    public static let monoFamily = "Azeret Mono"
    static let wdth = 0x77647468 // 'wdth'
    static let wght = 0x77676874 // 'wght'

    private static let registered = Mutex(false)
    // CTFont isn't Sendable, so the cache sits behind a plain lock instead of a Mutex.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CTFont] = [:]

    /// Registers the bundled fonts for this process (SPM resources live in Bundle.module, which UIAppFonts can't see).
    /// Call once from each App.init; repeat calls are no-ops.
    public static func register() {
        registered.withLock { done in
            guard !done else { return }
            let urls = ["Archivo[wdth,wght]", "AzeretMono[wght]"].compactMap { Bundle.module.url(forResource: $0, withExtension: "ttf") }
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
            done = true
        }
    }

    /// Whether a family resolved to the bundled font rather than a system substitute.
    /// Positive answers are remembered: this runs on every font a view builds.
    public static func isAvailable(_ family: String) -> Bool {
        if found.withLock({ $0.contains(family) }) { return true }
        let f = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary), 12, nil)
        let ok = (CTFontCopyFamilyName(f) as String) == family
        if ok { found.withLock { _ = $0.insert(family) } }
        return ok
    }
    private static let found = Mutex(Set<String>())

    static func ctFont(family: String, size: CGFloat, width: CGFloat?, weight: CGFloat) -> CTFont {
        let key = "\(family)|\(size)|\(width ?? -1)|\(weight)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }
        var axes: [Int: CGFloat] = [wght: weight]
        if let width { axes[wdth] = width }
        let attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: family, kCTFontVariationAttribute: axes]
        let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
        cache[key] = font
        return font
    }

    /// Archivo at an exact width/weight. Falls back to the system font (same size, nearest weight) if registration failed.
    public static func archivo(_ size: CGFloat, width: CGFloat, weight: CGFloat) -> Font {
        guard isAvailable(archivoFamily) else {
            return .system(size: size, weight: swiftWeight(weight)).width(width < 90 ? .condensed : width > 110 ? .expanded : .standard)
        }
        return Font(ctFont(family: archivoFamily, size: size, width: width, weight: weight))
    }

    public static func mono(_ size: CGFloat, weight: CGFloat) -> Font {
        guard isAvailable(monoFamily) else { return .system(size: size, weight: swiftWeight(weight), design: .monospaced) }
        return Font(ctFont(family: monoFamily, size: size, width: nil, weight: weight))
    }

    static func swiftWeight(_ w: CGFloat) -> Font.Weight {
        switch w {
        case ..<250: .ultraLight
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }
}

/// Text-size multiplier per Dynamic Type step (Apple's body-style progression). Hero roles stop at accessibility1.
public enum VScale {
    public static func factor(_ size: DynamicTypeSize, cap: DynamicTypeSize? = nil) -> CGFloat {
        let s = cap.map { min(size, $0) } ?? size
        switch s {
        case .xSmall: return 0.82
        case .small: return 0.88
        case .medium: return 0.94
        case .large: return 1
        case .xLarge: return 1.12
        case .xxLarge: return 1.24
        case .xxxLarge: return 1.35
        case .accessibility1: return 1.65
        case .accessibility2: return 1.94
        case .accessibility3: return 2.35
        case .accessibility4: return 2.76
        case .accessibility5: return 3.12
        @unknown default: return 1
        }
    }
}
