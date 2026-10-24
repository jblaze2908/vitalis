import Foundation

/// Reads kcal, protein, carbs and fat from OCR'd nutrition-label rows by matching those words; the owner corrects the rest.
///
/// Column rule: a header naming both a per-100 g and a per-serving column → the serving column's position; a header with
/// one column → the first value; no header and two or more values on a row → the second (Indian and EU labels print per
/// 100 g first); one value → that value. `%` daily values are ignored, and on energy rows kcal wins over kJ.
enum LabelParser {
    struct Values: Equatable, Sendable {
        var kcal: Double?
        var proteinG: Double?
        var carbsG: Double?
        var fatG: Double?
        var isEmpty: Bool { kcal == nil && proteinG == nil && carbsG == nil && fatG == nil }
    }

    private enum Nutrient: CaseIterable {
        case energy, protein, carbs, fat
        var words: [String] {
            switch self {
            case .energy: ["energy", "calories", "calorie", "kcal"]
            case .protein: ["protein"]
            case .carbs: ["carbohydrate", "carbs"]
            case .fat: ["fat"]
            }
        }
        /// Sub-rows that share the word but aren't the total.
        var excluded: [String] {
            switch self {
            case .energy: ["from fat"]
            case .fat: ["saturat", "trans", "mono", "poly", "from fat", "fatty", "cholesterol"]
            default: []
            }
        }
    }

    private struct Number { let value: Double; let unit: String }

    static func parse(_ text: String) -> Values {
        let rows = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let column = servingColumn(rows)
        var values = Values()
        values.kcal = value(.energy, rows: rows, column: column)
        values.proteinG = value(.protein, rows: rows, column: column)
        values.carbsG = value(.carbs, rows: rows, column: column)
        values.fatG = value(.fat, rows: rows, column: column)
        return values
    }

    /// Index of the per-serving column from the first header row, or nil when there is no header.
    private static func servingColumn(_ rows: [String]) -> Int? {
        for row in rows.map({ $0.lowercased() }) where !Nutrient.allCases.contains(where: { n in n.words.contains { row.contains($0) } }) {
            let per100 = row.range(of: #"(per\s*|/\s*)?100\s*(g|gm|ml)\b"#, options: .regularExpression)
            let serving = row.range(of: #"per\s*(serv|portion|pack|piece|bar|cup)|serving|serve\b|portion"#, options: .regularExpression)
            switch (per100, serving) {
            case let (a?, b?): return b.lowerBound < a.lowerBound ? 0 : 1
            case (_?, nil): return 0
            case (nil, _?) where row.contains("per"): return 0
            default: continue
            }
        }
        return nil
    }

    private static func value(_ nutrient: Nutrient, rows: [String], column: Int?) -> Double? {
        for (i, row) in rows.enumerated() {
            let lower = row.lowercased()
            guard let word = nutrient.words.compactMap({ lower.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
                  !nutrient.excluded.contains(where: { lower.contains($0) }) else { continue }
            if nutrient == .energy, lower.contains("kj"), !lower.contains("kcal"), !lower.contains("calorie") { continue }
            var found = numbers(in: String(lower[word.upperBound...]))
            // Table columns often come back from OCR as their own row under the label.
            if found.isEmpty, i + 1 < rows.count, rows[i + 1].first?.isNumber == true { found = numbers(in: rows[i + 1].lowercased()) }
            found.removeAll { $0.unit == "%" }
            if nutrient == .energy { found = kcalOnly(found, row: lower) }
            guard !found.isEmpty else { continue }
            if found.count == 1 { return found[0].value }
            return found[min(column ?? 1, found.count - 1)].value
        }
        return nil
    }

    /// "795 kJ / 190 kcal" → 190; "kJ/kcal 1046/250 418/100" (no units on the numbers) → every second value.
    private static func kcalOnly(_ numbers: [Number], row: String) -> [Number] {
        let tagged = numbers.filter { $0.unit == "kcal" || $0.unit == "cal" }
        if !tagged.isEmpty { return tagged }
        let plain = numbers.filter { $0.unit != "kj" }
        guard let kj = row.range(of: "kj"), let kcal = row.range(of: "kcal"), plain.count >= 2, plain.count == numbers.count else { return plain }
        let kcalSecond = kj.lowerBound < kcal.lowerBound
        return plain.enumerated().filter { ($0.offset % 2 == 1) == kcalSecond }.map(\.element)
    }

    private static func numbers(in text: String) -> [Number] {
        guard let regex = try? Regex(#"(\d{1,3}(?:,\d{3})+(?![\d.,])|\d+(?:[.,]\d+)?)\s*(kcal|kj|cal|mg|gm|g|ml|%)?"#).ignoresCase() else { return [] }
        return text.matches(of: regex).compactMap { match in
            guard let raw = match.output[1].substring.map(String.init) else { return nil }
            let unit = match.output[2].substring.map { String($0).lowercased() } ?? ""
            return parseNumber(raw).map { Number(value: $0, unit: unit) }
        }
    }

    /// "4,5" is a decimal comma (EU); "1,046" is a thousands separator.
    private static func parseNumber(_ raw: String) -> Double? {
        if raw.range(of: #"^\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil { return Double(raw.replacingOccurrences(of: ",", with: "")) }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }
}
