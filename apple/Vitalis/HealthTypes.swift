@preconcurrency import HealthKit
import Foundation
import OSLog

struct HealthTypes: Sendable {
    let samples: [HKSampleType]
    let readTypes: Set<HKObjectType>
    let units: [String: HKUnit]
    let diagnostics: [String]
    private static let logger = Logger(subsystem: "Vitalis", category: "TypeRegistry")

    init() {
        var samples: [HKSampleType] = []
        var readTypes: Set<HKObjectType> = []
        var units: [String: HKUnit] = [:]
        var diagnostics: [String] = []
        for (identifier, unit) in Self.quantityUnits {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
                let message = "Unavailable quantity type: \(identifier.rawValue)"
                diagnostics.append(message); Self.logger.notice("\(message, privacy: .public)")
                continue
            }
            guard type.is(compatibleWith: unit) else {
                let message = "Incompatible configured unit for \(identifier.rawValue); using fallback."
                diagnostics.append(message); Self.logger.error("\(message, privacy: .public)")
                if let fallback = Self.fallbackUnit(for: type) { units[type.identifier] = fallback }
                else { diagnostics.append("No compatible unit: \(type.identifier)"); continue }
                samples.append(type); readTypes.insert(type)
                continue
            }
            samples.append(type); readTypes.insert(type); units[type.identifier] = unit
        }
        for identifier in Self.categoryIDs {
            guard let type = HKObjectType.categoryType(forIdentifier: identifier) else {
                let message = "Unavailable category type: \(identifier.rawValue)"
                diagnostics.append(message); Self.logger.notice("\(message, privacy: .public)")
                continue
            }
            samples.append(type); readTypes.insert(type)
        }
        let special: [HKSampleType] = [HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
            HKSeriesType.heartbeat(), HKObjectType.electrocardiogramType(), HKObjectType.stateOfMindType(),
            HKObjectType.audiogramSampleType(), HKObjectType.visionPrescriptionType()]
        for type in special { samples.append(type); readTypes.insert(type) }
        for type in Self.assessmentTypes() { samples.append(type); readTypes.insert(type) }
        // Correlation read permission is obtained through the member quantity types above.
        for id: HKCorrelationTypeIdentifier in [.bloodPressure, .food] {
            if let type = HKObjectType.correlationType(forIdentifier: id) { samples.append(type) }
        }
        var seen = Set<String>()
        self.samples = samples.filter { seen.insert($0.identifier).inserted }.sorted { $0.identifier < $1.identifier }
        self.readTypes = readTypes; self.units = units; self.diagnostics = diagnostics
    }

    func unit(for type: HKQuantityType) throws -> HKUnit {
        if let unit = units[type.identifier] { return unit }
        if let unit = Self.fallbackUnit(for: type) { return unit }
        throw HealthReadError.unsupportedUnit(type.identifier)
    }

    private static func assessmentTypes() -> [HKSampleType] {
        [HKScoredAssessmentType(.GAD7), HKScoredAssessmentType(.PHQ9)]
    }

    static func fallbackUnit(for type: HKQuantityType) -> HKUnit? {
        let scalar: [HKUnit] = [.count(), .percent()]
        let physical: [HKUnit] = [.meter(), .gramUnit(with: .kilo), .second(), .kilocalorie(),
            .count().unitDivided(by: .minute()), .meter().unitDivided(by: .second()),
            .degreeCelsius(), .millimeterOfMercury(), .liter(), .watt(), .hertz(), .siemenUnit(with: .micro)]
        let candidates = type.aggregationStyle == .cumulative ? physical + scalar : scalar + physical
        guard let unit = candidates.first(where: { type.is(compatibleWith: $0) }) else { return nil }
        logger.notice("Fallback unit \(unit.unitString, privacy: .public) for \(type.identifier, privacy: .public)")
        return unit
    }

    // A single table defines the wire unit for every supported quantity identifier.
    static var quantityUnits: [(HKQuantityTypeIdentifier, HKUnit)] {
        let count = HKUnit.count()
        let bpm = count.unitDivided(by: .minute())
        let speed = HKUnit.meter().unitDivided(by: .second())
        let percent = HKUnit.percent()
        let grams = HKUnit.gram()
        let mg = HKUnit.gramUnit(with: .milli)
        let mcg = HKUnit.gramUnit(with: .micro)
        return [
            // Activity, fitness, mobility, running and cycling (through iOS 18).
            (.stepCount, count), (.distanceWalkingRunning, .meter()), (.distanceCycling, .meter()),
            (.pushCount, count), (.distanceWheelchair, .meter()), (.swimmingStrokeCount, count),
            (.distanceSwimming, .meter()), (.distanceDownhillSnowSports, .meter()),
            (.basalEnergyBurned, .kilocalorie()), (.activeEnergyBurned, .kilocalorie()),
            (.flightsClimbed, count), (.nikeFuel, count), (.appleExerciseTime, .minute()),
            (.appleMoveTime, .minute()), (.appleStandTime, .minute()),
            (.vo2Max, HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .minute())),
            (.runningGroundContactTime, .secondUnit(with: .milli)), (.runningPower, .watt()),
            (.runningSpeed, speed), (.runningStrideLength, .meter()), (.runningVerticalOscillation, .meter()),
            (.cyclingCadence, bpm), (.cyclingFunctionalThresholdPower, .watt()), (.cyclingPower, .watt()),
            (.cyclingSpeed, speed), (.crossCountrySkiingSpeed, speed), (.distanceCrossCountrySkiing, .meter()),
            (.distancePaddleSports, .meter()), (.distanceRowing, .meter()), (.distanceSkatingSports, .meter()),
            (.paddleSportsSpeed, speed), (.rowingSpeed, speed),
            (.physicalEffort, HKUnit.kilocalorie().unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .hour())),
            (.workoutEffortScore, .appleEffortScore()), (.estimatedWorkoutEffortScore, .appleEffortScore()),
            (.appleWalkingSteadiness, percent), (.sixMinuteWalkTestDistance, .meter()),
            (.walkingSpeed, speed), (.walkingStepLength, .meter()), (.walkingAsymmetryPercentage, percent),
            (.walkingDoubleSupportPercentage, percent), (.stairAscentSpeed, speed), (.stairDescentSpeed, speed),
            // Body measurements, reproductive health.
            (.height, .meter()), (.bodyMass, .gramUnit(with: .kilo)), (.bodyMassIndex, count),
            (.leanBodyMass, .gramUnit(with: .kilo)), (.bodyFatPercentage, percent), (.waistCircumference, .meter()),
            (.basalBodyTemperature, .degreeCelsius()), (.appleSleepingWristTemperature, .degreeCelsius()),
            // Vital signs, heart and respiratory health.
            (.heartRate, bpm), (.restingHeartRate, bpm), (.walkingHeartRateAverage, bpm),
            (.heartRateVariabilitySDNN, .secondUnit(with: .milli)), (.heartRateRecoveryOneMinute, bpm),
            (.atrialFibrillationBurden, percent), (.oxygenSaturation, percent), (.bodyTemperature, .degreeCelsius()),
            (.bloodPressureDiastolic, .millimeterOfMercury()), (.bloodPressureSystolic, .millimeterOfMercury()),
            (.respiratoryRate, bpm), (.appleSleepingBreathingDisturbances, count),
            // Lab values, medication, falls.
            (.bloodGlucose, mg.unitDivided(by: .literUnit(with: .deci))),
            (.electrodermalActivity, .siemenUnit(with: .micro)), (.forcedExpiratoryVolume1, .liter()),
            (.forcedVitalCapacity, .liter()), (.inhalerUsage, count), (.insulinDelivery, .internationalUnit()),
            (.numberOfTimesFallen, count), (.peakExpiratoryFlowRate, .liter().unitDivided(by: .minute())),
            (.peripheralPerfusionIndex, percent), (.bloodAlcoholContent, percent), (.numberOfAlcoholicBeverages, count),
            // Hearing, environment, diving.
            (.environmentalAudioExposure, .decibelAWeightedSoundPressureLevel()),
            (.headphoneAudioExposure, .decibelAWeightedSoundPressureLevel()),
            (.environmentalSoundReduction, .decibelAWeightedSoundPressureLevel()),
            (.uvExposure, count), (.timeInDaylight, .minute()), (.underwaterDepth, .meter()),
            (.waterTemperature, .degreeCelsius()),
            // Nutrition: preserve each nutrient sample and food-correlation membership.
            (.dietaryBiotin, mcg), (.dietaryCaffeine, mg), (.dietaryCalcium, mg), (.dietaryCarbohydrates, grams),
            (.dietaryChloride, mg), (.dietaryCholesterol, mg), (.dietaryChromium, mcg), (.dietaryCopper, mg),
            (.dietaryEnergyConsumed, .kilocalorie()), (.dietaryFatMonounsaturated, grams),
            (.dietaryFatPolyunsaturated, grams), (.dietaryFatSaturated, grams), (.dietaryFatTotal, grams),
            (.dietaryFiber, grams), (.dietaryFolate, mcg), (.dietaryIodine, mcg), (.dietaryIron, mg),
            (.dietaryMagnesium, mg), (.dietaryManganese, mg), (.dietaryMolybdenum, mcg), (.dietaryNiacin, mg),
            (.dietaryPantothenicAcid, mg), (.dietaryPhosphorus, mg), (.dietaryPotassium, mg),
            (.dietaryProtein, grams), (.dietaryRiboflavin, mg), (.dietarySelenium, mcg), (.dietarySodium, mg),
            (.dietarySugar, grams), (.dietaryThiamin, mg), (.dietaryVitaminA, mcg), (.dietaryVitaminB12, mcg),
            (.dietaryVitaminB6, mg), (.dietaryVitaminC, mg), (.dietaryVitaminD, mcg), (.dietaryVitaminE, mg),
            (.dietaryVitaminK, mcg), (.dietaryWater, .literUnit(with: .milli)), (.dietaryZinc, mg)
        ]
    }

    static let categoryIDs: [HKCategoryTypeIdentifier] = [
        // Activity, sleep, mindfulness and personal care.
        .appleStandHour, .lowCardioFitnessEvent, .sleepAnalysis, .mindfulSession,
        .toothbrushingEvent, .handwashingEvent,
        // Reproductive health.
        .menstrualFlow, .intermenstrualBleeding, .infrequentMenstrualCycles, .irregularMenstrualCycles,
        .persistentIntermenstrualBleeding, .prolongedMenstrualPeriods, .cervicalMucusQuality,
        .ovulationTestResult, .progesteroneTestResult, .sexualActivity, .contraceptive,
        .pregnancy, .pregnancyTestResult, .lactation, .bleedingDuringPregnancy, .bleedingAfterPregnancy,
        // Hearing, heart and mobility.
        .environmentalAudioExposureEvent, .headphoneAudioExposureEvent, .audioExposureEvent,
        .lowHeartRateEvent, .highHeartRateEvent, .irregularHeartRhythmEvent, .appleWalkingSteadinessEvent, .sleepApneaEvent,
        // Symptoms: abdominal / gastrointestinal.
        .abdominalCramps, .bloating, .constipation, .diarrhea, .heartburn, .nausea, .vomiting,
        // Constitutional.
        .appetiteChanges, .chills, .dizziness, .fainting, .fatigue, .fever, .generalizedBodyAche, .hotFlashes,
        // Heart / lung, musculoskeletal, neurological.
        .chestTightnessOrPain, .coughing, .rapidPoundingOrFlutteringHeartbeat, .shortnessOfBreath,
        .skippedHeartbeat, .wheezing, .lowerBackPain, .headache, .memoryLapse, .moodChanges,
        // Nose / throat, reproduction, skin / hair, sleep, urinary.
        .lossOfSmell, .lossOfTaste, .runnyNose, .soreThroat, .sinusCongestion,
        .breastPain, .pelvicPain, .vaginalDryness, .acne, .drySkin, .hairLoss,
        .nightSweats, .sleepChanges, .bladderIncontinence
    ]
}

enum HealthReadError: LocalizedError {
    case unsupportedUnit(String), missingAnchor, missingWorkout(String), tooManyPoints(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedUnit(let type): "No safe unit for \(type)."
        case .missingAnchor: "HealthKit returned no anchor."
        case .missingWorkout(let uuid): "No readable workout associated with route \(uuid)."
        case .tooManyPoints(let uuid): "Sample \(uuid) exceeds 200,000 points; export paused without truncation."
        }
    }
}
