@preconcurrency import HealthKit
import CoreFoundation
import Foundation
import OSLog
import VitalisKit

struct HealthSerializer: Sendable {
    let registry: HealthTypes
    let timeZone: TimeZone
    init(registry: HealthTypes, timeZone: TimeZone = .current) { self.registry = registry; self.timeZone = timeZone }
    private func dateString(_ date: Date) -> String { WireDate.string(date, timeZone: timeZone) }
    private static let logger = Logger(subsystem: "Vitalis", category: "Serializer")

    func sample(_ sample: HKSample) throws -> Sample {
        let revision = sample.sourceRevision
        let version = revision.operatingSystemVersion
        var fields: [String: JSONValue] = [
            "uuid": .string(sample.uuid.uuidString), "type": .string(sample.sampleType.identifier),
            "start": .string(dateString(sample.startDate)), "end": .string(dateString(sample.endDate)),
            "tz": .optional(sample.metadata?[HKMetadataKeyTimeZone] as? String),
            "source": .object(["name": .string(revision.source.name), "bundle_id": .string(revision.source.bundleIdentifier),
                "version": .optional(revision.version), "product_type": .optional(revision.productType),
                "os_version": .string("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")]),
            "device": device(sample.device), "metadata": try metadata(sample.metadata, type: sample.sampleType)
        ]
        if let quantity = sample as? HKQuantitySample {
            let unit = try registry.unit(for: quantity.quantityType)
            fields["kind"] = .string("quantity")
            fields["value"] = .finite(quantity.quantity.doubleValue(for: unit))
            fields["unit"] = .string(unit.unitString)
        } else if let category = sample as? HKCategorySample {
            fields["kind"] = .string("category"); fields["value"] = .number(Double(category.value))
            fields["value_label"] = .optional(categoryLabel(category))
        } else if let workout = sample as? HKWorkout {
            fields["kind"] = .string("workout")
            fields["activity_type"] = .number(Double(workout.workoutActivityType.rawValue))
            fields["activity_name"] = .string(activityName(workout.workoutActivityType))
            fields["duration_s"] = .finite(workout.duration)
            fields["events"] = .array(try (workout.workoutEvents ?? []).map { event in
                .object(["type": .number(Double(event.type.rawValue)),
                         "start": .string(dateString(event.dateInterval.start)),
                         "end": .string(dateString(event.dateInterval.end)),
                         "metadata": try metadata(event.metadata, type: nil)])
            })
            fields["activities"] = .array(try workout.workoutActivities.map { activity in
                let type = activity.workoutConfiguration.activityType
                return .object(["uuid": .string(activity.uuid.uuidString),
                    "activity_type": .number(Double(type.rawValue)), "activity_name": .string(activityName(type)),
                    "start": .string(dateString(activity.startDate)),
                    "end": activity.endDate.map { .string(dateString($0)) } ?? .null,
                    "metadata": try metadata(activity.metadata, type: nil),
                    "statistics": try statistics(activity.allStatistics)])
            })
            fields["statistics"] = try statistics(workout.allStatistics)
        } else if let correlation = sample as? HKCorrelation {
            fields["kind"] = .string("correlation")
            fields["objects"] = .array(correlation.objects.map { .string($0.uuid.uuidString) }.sorted {
                ($0.stringValue ?? "") < ($1.stringValue ?? "")
            })
        } else if sample is HKWorkoutRoute {
            fields["kind"] = .string("route")
        } else if sample is HKHeartbeatSeriesSample {
            fields["kind"] = .string("heartbeat")
        } else if let ecg = sample as? HKElectrocardiogram {
            fields["kind"] = .string("ecg")
            fields["classification"] = .number(Double(ecg.classification.rawValue))
            fields["symptoms_status"] = .number(Double(ecg.symptomsStatus.rawValue))
            fields["avg_hr"] = .finite(ecg.averageHeartRate?.doubleValue(for: .count().unitDivided(by: .minute())))
            fields["sampling_hz"] = .finite(ecg.samplingFrequency?.doubleValue(for: .hertz()))
        } else if let mind = sample as? HKStateOfMind {
            fields["kind"] = .string("state_of_mind")
            fields["state_kind"] = .number(Double(mind.kind.rawValue)); fields["valence"] = .finite(mind.valence)
            fields["labels"] = .array(mind.labels.map { .number(Double($0.rawValue)) })
            fields["associations"] = .array(mind.associations.map { .number(Double($0.rawValue)) })
        } else {
            fields["kind"] = .string("other")
            fields["payload"] = try otherPayload(sample)
        }
        return Sample(fields)
    }

    func deletion(uuid: UUID, type: HKSampleType) -> Deletion {
        Deletion(uuid: uuid.uuidString, type: type.identifier)
    }

    func statistics(_ values: [HKQuantityType: HKStatistics]) throws -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (type, stats) in values {
            let unit = try registry.unit(for: type)
            result[type.identifier] = .object([
                "sum": .finite(stats.sumQuantity()?.doubleValue(for: unit)),
                "min": .finite(stats.minimumQuantity()?.doubleValue(for: unit)),
                "avg": .finite(stats.averageQuantity()?.doubleValue(for: unit)),
                "max": .finite(stats.maximumQuantity()?.doubleValue(for: unit)), "unit": .string(unit.unitString)])
        }
        return .object(result)
    }

    func metadata(_ values: [String: Any]?, type: HKSampleType?) throws -> JSONValue {
        guard let values else { return .null }
        var output: [String: JSONValue] = [:]
        for (key, value) in values { output[key] = try json(value, type: type) }
        return .object(output)
    }

    private func json(_ value: Any, type: HKSampleType?) throws -> JSONValue {
        if value is NSNull { return .null }
        if let date = value as? Date { return .string(dateString(date)) }
        if let quantity = value as? HKQuantity {
            var candidates: [HKUnit] = []
            if let type = type as? HKQuantityType { candidates.append(try registry.unit(for: type)) }
            candidates += registry.units.keys.sorted().compactMap { registry.units[$0] }
            candidates += [.count(), .percent(), .meter(), .gramUnit(with: .kilo), .gram(), .second(),
                .secondUnit(with: .milli), .degreeCelsius(), .kilocalorie(), .watt(),
                .count().unitDivided(by: .minute()), .meter().unitDivided(by: .second()),
                .millimeterOfMercury(), .liter(), .hertz(), .siemenUnit(with: .micro),
                .decibelAWeightedSoundPressureLevel(), .internationalUnit(), .diopter(), .degreeAngle(), .lux()]
            // Never call doubleValue with an incompatible unit (it raises an ObjC exception). An unknown unit keeps
            // HealthKit's own text ("1250 lx") rather than failing the whole sync on one metadata key.
            guard let unit = candidates.first(where: { quantity.is(compatibleWith: $0) }) else {
                return .string(quantity.description)
            }
            return .object(["value": .finite(quantity.doubleValue(for: unit)), "unit": .string(unit.unitString)])
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .finite(number.doubleValue)
        }
        if let text = value as? String { return .string(text) }
        if let values = value as? [String: Any] { return try metadata(values, type: type) }
        if let values = value as? [Any] { return .array(try values.map { try json($0, type: type) }) }
        if let data = value as? Data { return .string(data.base64EncodedString()) }
        if let url = value as? URL { return .string(url.absoluteString) }
        if let uuid = value as? UUID { return .string(uuid.uuidString) }
        // HealthKit metadata is normally property-list data; preserve any future value as text.
        Self.logger.notice("Stringifying unknown metadata class \(String(describing: Swift.type(of: value)), privacy: .public)")
        return .string(String(describing: value))
    }

    private func device(_ device: HKDevice?) -> JSONValue {
        guard let device else { return .null }
        return .object(["name": .optional(device.name), "manufacturer": .optional(device.manufacturer),
            "model": .optional(device.model), "hardware_version": .optional(device.hardwareVersion),
            "firmware_version": .optional(device.firmwareVersion), "software_version": .optional(device.softwareVersion),
            "local_identifier": .optional(device.localIdentifier), "udi_device_identifier": .optional(device.udiDeviceIdentifier)])
    }

    private func categoryLabel(_ sample: HKCategorySample) -> String? {
        let id = sample.categoryType.identifier
        if id == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue: return "inBed"
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: return "asleepUnspecified"
            case HKCategoryValueSleepAnalysis.awake.rawValue: return "awake"
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue: return "asleepCore"
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: return "asleepDeep"
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue: return "asleepREM"
            default: return nil
            }
        }
        if id == HKCategoryTypeIdentifier.appleStandHour.rawValue {
            return sample.value == HKCategoryValueAppleStandHour.stood.rawValue ? "stood" :
                sample.value == HKCategoryValueAppleStandHour.idle.rawValue ? "idle" : nil
        }
        if id == HKCategoryTypeIdentifier.menstrualFlow.rawValue {
            return [HKCategoryValueMenstrualFlow.unspecified.rawValue: "unspecified",
                HKCategoryValueMenstrualFlow.light.rawValue: "light", HKCategoryValueMenstrualFlow.medium.rawValue: "medium",
                HKCategoryValueMenstrualFlow.heavy.rawValue: "heavy", HKCategoryValueMenstrualFlow.none.rawValue: "none"][sample.value]
        }
        if id == HKCategoryTypeIdentifier.ovulationTestResult.rawValue {
            return [HKCategoryValueOvulationTestResult.negative.rawValue: "negative",
                HKCategoryValueOvulationTestResult.luteinizingHormoneSurge.rawValue: "luteinizingHormoneSurge",
                HKCategoryValueOvulationTestResult.indeterminate.rawValue: "indeterminate",
                HKCategoryValueOvulationTestResult.estrogenSurge.rawValue: "estrogenSurge"][sample.value]
        }
        if id == HKCategoryTypeIdentifier.pregnancyTestResult.rawValue || id == HKCategoryTypeIdentifier.progesteroneTestResult.rawValue {
            return [HKCategoryValuePregnancyTestResult.negative.rawValue: "negative",
                HKCategoryValuePregnancyTestResult.positive.rawValue: "positive",
                HKCategoryValuePregnancyTestResult.indeterminate.rawValue: "indeterminate"][sample.value]
        }
        if Self.severityTypes.contains(id) {
            return [HKCategoryValueSeverity.notPresent.rawValue: "notPresent", HKCategoryValueSeverity.mild.rawValue: "mild",
                HKCategoryValueSeverity.moderate.rawValue: "moderate", HKCategoryValueSeverity.severe.rawValue: "severe",
                HKCategoryValueSeverity.unspecified.rawValue: "unspecified"][sample.value]
        }
        return nil
    }
    private static let severityTypes: Set<String> = Set([
        HKCategoryTypeIdentifier.abdominalCramps, .bloating, .constipation, .diarrhea, .heartburn, .nausea, .vomiting,
        .chills, .dizziness, .fatigue, .generalizedBodyAche, .headache, .lowerBackPain, .breastPain, .pelvicPain,
        .acne, .drySkin, .hairLoss, .coughing, .shortnessOfBreath, .soreThroat, .runnyNose, .sinusCongestion
    ].map(\.rawValue))

    func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .americanFootball: "americanFootball"
        case .archery: "archery"
        case .australianFootball: "australianFootball"
        case .badminton: "badminton"
        case .barre: "barre"
        case .baseball: "baseball"
        case .basketball: "basketball"
        case .bowling: "bowling"
        case .boxing: "boxing"
        case .cardioDance: "cardioDance"
        case .climbing: "climbing"
        case .cooldown: "cooldown"
        case .coreTraining: "coreTraining"
        case .cricket: "cricket"
        case .crossCountrySkiing: "crossCountrySkiing"
        case .crossTraining: "crossTraining"
        case .curling: "curling"
        case .cycling: "cycling"
        case .dance: "dance"
        case .danceInspiredTraining: "danceInspiredTraining"
        case .discSports: "discSports"
        case .downhillSkiing: "downhillSkiing"
        case .elliptical: "elliptical"
        case .equestrianSports: "equestrianSports"
        case .fencing: "fencing"
        case .fishing: "fishing"
        case .fitnessGaming: "fitnessGaming"
        case .flexibility: "flexibility"
        case .functionalStrengthTraining: "functionalStrengthTraining"
        case .golf: "golf"
        case .gymnastics: "gymnastics"
        case .handCycling: "handCycling"
        case .handball: "handball"
        case .highIntensityIntervalTraining: "highIntensityIntervalTraining"
        case .hiking: "hiking"
        case .hockey: "hockey"
        case .hunting: "hunting"
        case .jumpRope: "jumpRope"
        case .kickboxing: "kickboxing"
        case .lacrosse: "lacrosse"
        case .martialArts: "martialArts"
        case .mindAndBody: "mindAndBody"
        case .mixedCardio: "mixedCardio"
        case .mixedMetabolicCardioTraining: "mixedMetabolicCardioTraining"
        case .other: "other"
        case .paddleSports: "paddleSports"
        case .pickleball: "pickleball"
        case .pilates: "pilates"
        case .play: "play"
        case .preparationAndRecovery: "preparationAndRecovery"
        case .racquetball: "racquetball"
        case .rowing: "rowing"
        case .rugby: "rugby"
        case .running: "running"
        case .sailing: "sailing"
        case .skatingSports: "skatingSports"
        case .snowSports: "snowSports"
        case .snowboarding: "snowboarding"
        case .soccer: "soccer"
        case .socialDance: "socialDance"
        case .softball: "softball"
        case .squash: "squash"
        case .stairClimbing: "stairClimbing"
        case .stairs: "stairs"
        case .stepTraining: "stepTraining"
        case .surfingSports: "surfingSports"
        case .swimBikeRun: "swimBikeRun"
        case .swimming: "swimming"
        case .tableTennis: "tableTennis"
        case .taiChi: "taiChi"
        case .tennis: "tennis"
        case .trackAndField: "trackAndField"
        case .traditionalStrengthTraining: "traditionalStrengthTraining"
        case .transition: "transition"
        case .underwaterDiving: "underwaterDiving"
        case .volleyball: "volleyball"
        case .walking: "walking"
        case .waterFitness: "waterFitness"
        case .waterPolo: "waterPolo"
        case .waterSports: "waterSports"
        case .wheelchairRunPace: "wheelchairRunPace"
        case .wheelchairWalkPace: "wheelchairWalkPace"
        case .wrestling: "wrestling"
        case .yoga: "yoga"
        default: "unknown_\(type.rawValue)"
        }
    }

    private func otherPayload(_ sample: HKSample) throws -> JSONValue {
        if let audiogram = sample as? HKAudiogramSample {
            return .object(["sensitivity_points": .array(audiogram.sensitivityPoints.map { point in
                .object(["frequency_hz": .finite(point.frequency.doubleValue(for: .hertz())),
                    "left_dbhl": .finite(point.leftEarSensitivity?.doubleValue(for: .decibelHearingLevel())),
                    "right_dbhl": .finite(point.rightEarSensitivity?.doubleValue(for: .decibelHearingLevel()))])
            })])
        }
        if let prescription = sample as? HKVisionPrescription {
            return visionPayload(prescription)
        }
        if let assessment = sample as? HKScoredAssessment {
            return assessmentPayload(assessment)
        }
        return .object([:])
    }

    private func assessmentPayload(_ sample: HKScoredAssessment) -> JSONValue {
        var fields: [String: JSONValue] = ["score": .number(Double(sample.score))]
        if let sample = sample as? HKGAD7Assessment {
            fields["answers"] = .array(sample.answers.map { .number(Double($0.rawValue)) })
            fields["risk"] = .number(Double(sample.risk.rawValue))
        }
        if let sample = sample as? HKPHQ9Assessment {
            fields["answers"] = .array(sample.answers.map { .number(Double($0.rawValue)) })
            fields["risk"] = .number(Double(sample.risk.rawValue))
        }
        return .object(fields)
    }

    private func visionPayload(_ prescription: HKVisionPrescription) -> JSONValue {
        var fields: [String: JSONValue] = ["prescription_type": .number(Double(prescription.prescriptionType.rawValue)),
            "date_issued": .string(dateString(prescription.dateIssued)),
            "expiration_date": prescription.expirationDate.map { .string(dateString($0)) } ?? .null]
        if let glasses = prescription as? HKGlassesPrescription {
            fields["left_eye"] = lens(glasses.leftEye); fields["right_eye"] = lens(glasses.rightEye)
        }
        if let contacts = prescription as? HKContactsPrescription {
            fields["left_eye"] = lens(contacts.leftEye); fields["right_eye"] = lens(contacts.rightEye)
            fields["brand"] = .optional(contacts.brand)
        }
        return .object(fields)
    }
    private func lens(_ lens: HKLensSpecification?) -> JSONValue {
        guard let lens else { return .null }
        var fields: [String: JSONValue] = ["sphere_diopters": .finite(lens.sphere.doubleValue(for: .diopter())),
            "cylinder_diopters": .finite(lens.cylinder?.doubleValue(for: .diopter())),
            "axis_deg": .finite(lens.axis?.doubleValue(for: .degreeAngle())),
            "add_power_diopters": .finite(lens.addPower?.doubleValue(for: .diopter()))]
        if let contacts = lens as? HKContactsLensSpecification {
            fields["base_curve_mm"] = .finite(contacts.baseCurve?.doubleValue(for: .meterUnit(with: .milli)))
            fields["diameter_mm"] = .finite(contacts.diameter?.doubleValue(for: .meterUnit(with: .milli)))
        }
        if let glasses = lens as? HKGlassesLensSpecification {
            fields["vertex_distance_mm"] = .finite(glasses.vertexDistance?.doubleValue(for: .meterUnit(with: .milli)))
            fields["far_pd_mm"] = .finite(glasses.farPupillaryDistance?.doubleValue(for: .meterUnit(with: .milli)))
            fields["near_pd_mm"] = .finite(glasses.nearPupillaryDistance?.doubleValue(for: .meterUnit(with: .milli)))
            if let prism = glasses.prism {
                fields["prism"] = .object(["horizontal_amount": .finite(prism.horizontalAmount.doubleValue(for: .prismDiopter())),
                    "horizontal_base": .number(Double(prism.horizontalBase.rawValue)),
                    "amount": .finite(prism.amount.doubleValue(for: .prismDiopter())),
                    "angle_deg": .finite(prism.angle.doubleValue(for: .degreeAngle())),
                    "eye": .number(Double(prism.eye.rawValue)),
                    "vertical_amount": .finite(prism.verticalAmount.doubleValue(for: .prismDiopter())),
                    "vertical_base": .number(Double(prism.verticalBase.rawValue))])
            } else { fields["prism"] = .null }
        }
        return .object(fields)
    }
}
