import Foundation

// MARK: GET /v2/food/day (10 §7)

/// One food item as the server echoes it (entries, usual items, recent items, saved items).
public struct FoodItem: Codable, Sendable, Equatable {
    public let name: String
    public let portionText: String?
    public let grams: Double?
    public let kcal: Double
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    public init(name: String, portionText: String?, grams: Double?, kcal: Double, proteinG: Double?, carbsG: Double?, fatG: Double?) {
        self.name = name; self.portionText = portionText; self.grams = grams; self.kcal = kcal
        self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
    }
}

public struct FoodDayEntry: Codable, Sendable, Equatable {
    public let id: String
    public let mealId: String
    public let name: String
    public let portionText: String?
    public let grams: Double?
    public let kcal: Double
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    public let estimate: Bool
    public let source: String
    /// Sent back unchanged when an edit re-posts the entry under the same id; nil from older servers.
    public let slot: String?
    public let eatenAt: String?
    public let sourceRef: String?
    public let hkUuid: String?
}

public struct UsualMeal: Codable, Sendable, Equatable {
    public let name: String
    public let kcal: Double
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    public let items: [FoodItem]
    public let mealSignature: String?
}

public struct FoodDay: Codable, Sendable, Equatable {
    public struct Macro: Codable, Sendable, Equatable {
        public let g: Double
        public let targetG: Double?
    }
    public struct Macros: Codable, Sendable, Equatable {
        public let protein, carbs, fat: Macro
    }
    public struct Meal: Codable, Sendable, Equatable {
        public let slot: String
        public let label: String
        public let time: String?
        public let kcal: Double
        public let justAdded: Bool
        public let entries: [FoodDayEntry]
    }
    public let day: String
    public let dateLabel: String?
    public let prevDay: String?
    public let nextDay: String?
    public let kcalTarget: Double?
    public let kcalEaten: Double
    public let kcalLeft: Double?
    public let over: Bool
    public let macros: Macros
    public let targetNote: String?
    public let meals: [Meal]
    public let nextSlot: String?
    public let usualNext: UsualMeal?
    public let empty: Bool
    public let freshness: Freshness?
}

// MARK: GET /v2/food/quick (10 §7)

public struct SavedMealInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let slot: String?
    public let kcal: Double?
    public let items: [FoodItem]
    public init(id: String, name: String, slot: String?, kcal: Double?, items: [FoodItem]) {
        self.id = id; self.name = name; self.slot = slot; self.kcal = kcal; self.items = items
    }
}

public struct FoodQuick: Codable, Sendable, Equatable {
    public struct Recent: Codable, Sendable, Equatable {
        public let name: String
        public let portionText: String?
        public let grams: Double?
        public let kcal: Double
        public let proteinG: Double?
        public let carbsG: Double?
        public let fatG: Double?
        public let lastDay: String?
    }
    public let slot: String
    public let usual: UsualMeal?
    public let recent: [Recent]
    public let saved: [SavedMealInfo]
}

// MARK: Food writes (10 §7)

public struct FoodEntriesResponse: Codable, Sendable, Equatable {
    public struct Accepted: Codable, Sendable, Equatable {
        public let inserted, updated, unchanged: Int
    }
    public let accepted: Accepted
    public let day: FoodDay
}

/// DELETE /v2/food/entries/:id and /v2/food/meals/:meal_id.
public struct FoodDeleteResponse: Codable, Sendable, Equatable {
    public let deleted: Int
    public let day: FoodDay
}

public struct SavedMealPostResponse: Codable, Sendable, Equatable {
    public let saved: SavedMealInfo
}

public struct SavedMealsResponse: Codable, Sendable, Equatable {
    public let saved: [SavedMealInfo]
}

// MARK: GET /v2/food/search, GET/PUT /v2/food/barcode/:code (10 §7)

public struct Nutrients: Codable, Sendable, Equatable {
    public let kcal: Double
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    public init(kcal: Double, proteinG: Double?, carbsG: Double?, fatG: Double?) {
        self.kcal = kcal; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
    }
}

public struct Serving: Codable, Sendable, Equatable {
    public let label: String
    public let grams: Double?
    public let kcal: Double
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    public init(label: String, grams: Double?, kcal: Double, proteinG: Double?, carbsG: Double?, fatG: Double?) {
        self.label = label; self.grams = grams; self.kcal = kcal
        self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
    }
}

public struct FoodSearchResponse: Codable, Sendable, Equatable {
    public struct Result: Codable, Sendable, Equatable {
        public let key: String
        public let name: String
        public let brand: String?
        /// `search` | `recent` | `saved`
        public let source: String
        public let sourceRef: String?
        public let estimate: Bool
        public let per100g: Nutrients?
        public let serving: Serving
        public let label: String?
        // convertFromSnakeCase capitalises after a digit: `per_100g` arrives as `per100G`.
        private enum CodingKeys: String, CodingKey {
            case key, name, brand, source, sourceRef, estimate, per100g = "per100G", serving, label
        }
    }
    public let q: String
    public let page: Int
    /// `ok` | `rate_limited` | `unavailable`
    public let remote: String
    public let count: Int
    public let results: [Result]
    public let nextPage: Int?
}

public struct BarcodeResponse: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public let name: String
        public let brand: String?
        public let quantityLabel: String?
        /// Whole-pack size in g (or ml), so a scan can log ½ or ¼ of the pack; nil when Open Food Facts doesn't know.
        public let packageG: Double?
        public let per100g: Nutrients?
        public let serving: Serving
        // convertFromSnakeCase capitalises after a digit: `per_100g` arrives as `per100G`.
        private enum CodingKeys: String, CodingKey { case name, brand, quantityLabel, packageG, per100g = "per100G", serving }
    }
    public let code: String
    public let found: Bool
    /// `openfoodfacts` | `you`
    public let source: String
    public let item: Item?
    public let label: String?
}

// MARK: POST /v2/food/describe (10 §7)

public struct DescribeResponse: Codable, Sendable, Equatable {
    public struct PortionOption: Codable, Sendable, Equatable {
        public let label: String
        public let factor: Double
    }
    public struct Item: Codable, Sendable, Equatable {
        public let name: String
        public let portionText: String?
        public let grams: Double?
        public let kcal: Double
        public let proteinG: Double?
        public let carbsG: Double?
        public let fatG: Double?
        public let confidence: String?
        public let portionOptions: [PortionOption]
    }
    public struct Total: Codable, Sendable, Equatable {
        public let kcal: Double
        public let proteinG: Double?
        public let carbsG: Double?
        public let fatG: Double?
    }
    public let items: [Item]
    public let total: Total?
    public let estimate: Bool
    public let note: String?
}
