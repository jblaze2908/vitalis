import Foundation

// Write bodies are encoded with `APICoding.encoder()` (camelCase → snake_case). The server's zod
// schemas are strict, so nil optionals are omitted rather than sent as unknown keys.

/// POST /v2/workouts
public struct WorkoutUpsert: Codable, Sendable, Equatable {
    public struct Session: Codable, Sendable, Equatable {
        public var clientId: String
        public var title: String?
        public var template: String?
        /// `watch` | `phone`
        public var source: String
        public var startedAt: String
        public var endedAt: String?
        public var tzOffsetMin: Int
        public var hkWorkoutUuid: String?
        public var notes: String?
        public init(clientId: String, title: String? = nil, template: String? = nil, source: String, startedAt: String,
                    endedAt: String? = nil, tzOffsetMin: Int, hkWorkoutUuid: String? = nil, notes: String? = nil) {
            self.clientId = clientId; self.title = title; self.template = template; self.source = source
            self.startedAt = startedAt; self.endedAt = endedAt; self.tzOffsetMin = tzOffsetMin
            self.hkWorkoutUuid = hkWorkoutUuid; self.notes = notes
        }
    }
    public struct Set: Codable, Sendable, Equatable {
        public var id: String
        public var exercise: String?
        /// `normal` | `warmup` | …
        public var kind: String?
        public var weightKg: Double?
        public var reps: Int?
        public var durationS: Double?
        public var distanceM: Double?
        public var rpe: Double?
        public var rir: Int?
        public var targetWeightKg: Double?
        public var targetReps: Int?
        public var performedAt: String?
        public var note: String?
        public var deleted: Bool?
        public init(id: String, exercise: String? = nil, kind: String? = nil, weightKg: Double? = nil, reps: Int? = nil,
                    durationS: Double? = nil, distanceM: Double? = nil, rpe: Double? = nil, rir: Int? = nil,
                    targetWeightKg: Double? = nil, targetReps: Int? = nil, performedAt: String? = nil,
                    note: String? = nil, deleted: Bool? = nil) {
            self.id = id; self.exercise = exercise; self.kind = kind; self.weightKg = weightKg; self.reps = reps
            self.durationS = durationS; self.distanceM = distanceM; self.rpe = rpe; self.rir = rir
            self.targetWeightKg = targetWeightKg; self.targetReps = targetReps; self.performedAt = performedAt
            self.note = note; self.deleted = deleted
        }
        public static func deletion(_ id: String) -> Set { Set(id: id, deleted: true) }
    }
    public var session: Session
    public var sets: [Set]
    public init(session: Session, sets: [Set]) { self.session = session; self.sets = sets }
}

/// One entry of POST /v2/food/entries.
public struct FoodEntry: Codable, Sendable, Equatable {
    public var id: String
    public var mealId: String
    public var slot: String
    public var eatenAt: String
    public var name: String
    public var portionText: String?
    public var grams: Double?
    public var kcal: Double
    public var proteinG: Double?
    public var carbsG: Double?
    public var fatG: Double?
    /// `recent` | `usual` | `saved` | `search` | `barcode` | `describe` | `manual`
    public var source: String
    public var sourceRef: String?
    public var estimate: Bool?
    public var hkUuid: String?
    public init(id: String, mealId: String, slot: String, eatenAt: String, name: String, portionText: String? = nil,
                grams: Double? = nil, kcal: Double, proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil,
                source: String, sourceRef: String? = nil, estimate: Bool? = nil, hkUuid: String? = nil) {
        self.id = id; self.mealId = mealId; self.slot = slot; self.eatenAt = eatenAt; self.name = name
        self.portionText = portionText; self.grams = grams; self.kcal = kcal; self.proteinG = proteinG
        self.carbsG = carbsG; self.fatG = fatG; self.source = source; self.sourceRef = sourceRef
        self.estimate = estimate; self.hkUuid = hkUuid
    }
}

public struct FoodEntriesRequest: Codable, Sendable, Equatable {
    public var entries: [FoodEntry]
    public init(entries: [FoodEntry]) { self.entries = entries }
}

/// POST /v2/weight
public struct WeightEntry: Codable, Sendable, Equatable {
    public var id: String
    public var kg: Double
    public var measuredAt: String
    public var hkUuid: String?
    public init(id: String, kg: Double, measuredAt: String, hkUuid: String? = nil) {
        self.id = id; self.kg = kg; self.measuredAt = measuredAt; self.hkUuid = hkUuid
    }
}

/// A PUT /v2/targets field: absent (nil), `.set(value)`, or `.clear` (explicit JSON null → computed default).
public enum TargetPatchValue<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case set(Value)
    case clear
    public init(from decoder: any Decoder) throws {
        let box = try decoder.singleValueContainer()
        self = box.decodeNil() ? .clear : .set(try box.decode(Value.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .set(let value): try box.encode(value)
        case .clear: try box.encodeNil()
        }
    }
}

/// PUT /v2/targets: only non-nil fields are sent.
public struct TargetsPatch: Codable, Sendable, Equatable {
    public var steps: TargetPatchValue<Int>?
    public var kcalMode: TargetPatchValue<String>?
    public var kcal: TargetPatchValue<Int>?
    public var proteinG: TargetPatchValue<Double>?
    public var sleepNeedH: TargetPatchValue<Double>?
    public var wakeTime: TargetPatchValue<String>?
    public var goalWeightKg: TargetPatchValue<Double>?
    public var exerciseMin: TargetPatchValue<Int>?
    public var weeklySetsMin: TargetPatchValue<Int>?
    public var weeklySetsMax: TargetPatchValue<Int>?
    public var restS: TargetPatchValue<Int>?
    public var crownStepKg: TargetPatchValue<Double>?
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case steps, kcalMode, kcal, proteinG, sleepNeedH, wakeTime, goalWeightKg
        case exerciseMin, weeklySetsMin, weeklySetsMax, restS, crownStepKg
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T>(_ key: CodingKeys) throws -> TargetPatchValue<T>? {
            guard c.contains(key) else { return nil }
            return try c.decode(TargetPatchValue<T>.self, forKey: key)
        }
        steps = try field(.steps); kcalMode = try field(.kcalMode); kcal = try field(.kcal)
        proteinG = try field(.proteinG); sleepNeedH = try field(.sleepNeedH); wakeTime = try field(.wakeTime)
        goalWeightKg = try field(.goalWeightKg); exerciseMin = try field(.exerciseMin)
        weeklySetsMin = try field(.weeklySetsMin); weeklySetsMax = try field(.weeklySetsMax)
        restS = try field(.restS); crownStepKg = try field(.crownStepKg)
    }
    // Synthesized encoding would skip nil but cannot emit an explicit null, hence `.clear`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(steps, forKey: .steps); try c.encodeIfPresent(kcalMode, forKey: .kcalMode)
        try c.encodeIfPresent(kcal, forKey: .kcal); try c.encodeIfPresent(proteinG, forKey: .proteinG)
        try c.encodeIfPresent(sleepNeedH, forKey: .sleepNeedH); try c.encodeIfPresent(wakeTime, forKey: .wakeTime)
        try c.encodeIfPresent(goalWeightKg, forKey: .goalWeightKg); try c.encodeIfPresent(exerciseMin, forKey: .exerciseMin)
        try c.encodeIfPresent(weeklySetsMin, forKey: .weeklySetsMin); try c.encodeIfPresent(weeklySetsMax, forKey: .weeklySetsMax)
        try c.encodeIfPresent(restS, forKey: .restS); try c.encodeIfPresent(crownStepKg, forKey: .crownStepKg)
    }
}

/// POST /v2/food/saved
public struct SavedMeal: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var name: String
        public var portionText: String?
        public var grams: Double?
        public var kcal: Double
        public var proteinG: Double?
        public var carbsG: Double?
        public var fatG: Double?
        public init(name: String, portionText: String? = nil, grams: Double? = nil, kcal: Double,
                    proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil) {
            self.name = name; self.portionText = portionText; self.grams = grams; self.kcal = kcal
            self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        }
    }
    public var id: String
    public var name: String
    public var slot: String?
    public var items: [Item]
    public init(id: String, name: String, slot: String? = nil, items: [Item]) {
        self.id = id; self.name = name; self.slot = slot; self.items = items
    }
}

/// PUT /v2/food/barcode/:code body `{ "item": … }`.
public struct BarcodeItem: Codable, Sendable, Equatable {
    public var name: String
    public var brand: String?
    public var serving: Serving
    public var per100g: Nutrients?
    public init(name: String, brand: String? = nil, serving: Serving, per100g: Nutrients? = nil) {
        self.name = name; self.brand = brand; self.serving = serving; self.per100g = per100g
    }
    // convertToSnakeCase cannot produce `per_100g` from `per100g`.
    private enum CodingKeys: String, CodingKey { case name, brand, serving, per100g = "per_100g" }
}

public struct BarcodePut: Codable, Sendable, Equatable {
    public var item: BarcodeItem
    public init(item: BarcodeItem) { self.item = item }
}

/// POST /v2/food/describe
public struct DescribeRequest: Codable, Sendable, Equatable {
    public var text: String
    public var slot: String
    public init(text: String, slot: String) { self.text = text; self.slot = slot }
}

/// POST /v2/exercises
public struct NewExercise: Codable, Sendable, Equatable {
    public var name: String
    public var primary: [String]
    public var secondary: [String]?
    public var equipment: String?
    public var aliases: [String]?
    public init(name: String, primary: [String], secondary: [String]? = nil, equipment: String? = nil, aliases: [String]? = nil) {
        self.name = name; self.primary = primary; self.secondary = secondary; self.equipment = equipment; self.aliases = aliases
    }
}
