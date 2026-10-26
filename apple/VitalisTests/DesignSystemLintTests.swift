import Foundation
import Testing

/// Screens use only the design system (Draft "Vitalis" v1): colours, type styles and the shared components in VitalisUI.
/// A literal colour or an old type helper in a screen file fails here, so the app can't drift back to one-off values.
@Suite struct DesignSystemLintTests {
    static let screens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Vitalis/Screens")
    /// Old helpers replaced by `.vText(...)` and the VitalisUI components.
    static let banned = ["Color(hex:", ".vUI(", "MonoLabel(", ".vNumber(", ".vFigure(", ".vReading("]

    static func screenFiles() throws -> [URL] {
        let all = FileManager.default.enumerator(at: screens, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        // Preview fixtures and the label OCR parser carry no UI.
        return all.filter { $0.pathExtension == "swift" && !$0.lastPathComponent.contains("PreviewData") && $0.lastPathComponent != "LabelParser.swift" }
    }

    @Test func screensUseOnlyTokensAndTypeStyles() throws {
        let files = try Self.screenFiles()
        #expect(files.count > 20, "screen sources not found at \(Self.screens.path)")
        var hits: [String] = []
        for f in files {
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for b in Self.banned where line.contains(b) { hits.append("\(f.lastPathComponent):\(i + 1) \(b)") }
            }
        }
        #expect(hits.isEmpty, "literal colours or old type helpers in screens:\n\(hits.prefix(40).joined(separator: "\n"))")
    }
}
