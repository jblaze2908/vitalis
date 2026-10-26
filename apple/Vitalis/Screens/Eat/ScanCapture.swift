import AVFoundation
import SwiftUI
import UIKit
import Vision
#if canImport(VisionKit)
import VisionKit
#endif

/// Live barcode scanning with VisionKit (EAN-8, EAN-13, UPC-E). Unavailable on the simulator, where ScanScreen offers typing.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    /// The device can scan at all (not the simulator, has VisionKit's scanner).
    static var isSupported: Bool {
        #if canImport(VisionKit) && !targetEnvironment(simulator)
        DataScannerViewController.isSupported
        #else
        false
        #endif
    }

    /// Supported and allowed right now. VisionKit reports false until camera access is granted, so ask with `CameraAccess.resolve()` first.
    static var isAvailable: Bool {
        #if canImport(VisionKit) && !targetEnvironment(simulator)
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        #else
        false
        #endif
    }

    #if canImport(VisionKit)
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean8, .ean13, .upce])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue { onCode(payload); return }
            }
        }
    }
    #endif
}

/// Camera (or the photo library when there is no camera, e.g. the simulator) for a nutrition-label photo.
/// Whether the barcode camera can run. Without an explicit request the system prompt never appears,
/// because the scanner is only created once VisionKit says it's available.
enum CameraAccess: Equatable {
    case checking, ready, denied, unsupported

    @MainActor static func resolve() async -> CameraAccess {
        guard BarcodeScannerView.isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        default: return .denied
        }
        return BarcodeScannerView.isAvailable ? .ready : .denied
    }
}

struct LabelPhotoPicker: UIViewControllerRepresentable {
    let done: (LabelImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (LabelImage?) -> Void
        init(done: @escaping (LabelImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done((info[.originalImage] as? UIImage).flatMap(LabelImage.init))
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

/// A photo ready for Vision: the pixels plus their orientation (camera images arrive rotated).
struct LabelImage: @unchecked Sendable {
    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        cgImage = cg
        orientation = switch image.imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// On-device text recognition, rebuilt into table rows so a label and its values on one line stay together.
enum LabelReader {
    static func rows(from image: LabelImage) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                // Language correction rewrites digits ("10g" → "log"), so numbers are read raw.
                request.usesLanguageCorrection = false
                try? VNImageRequestHandler(cgImage: image.cgImage, orientation: image.orientation).perform([request])
                let pieces = (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { (box: o.boundingBox, text: $0.string) } }
                continuation.resume(returning: group(pieces))
            }
        }
    }

    /// Joins observations whose vertical centres are within half a line of each other, left to right, top to bottom.
    static func group(_ pieces: [(box: CGRect, text: String)]) -> [String] {
        var rows: [(midY: CGFloat, height: CGFloat, items: [(x: CGFloat, text: String)])] = []
        for p in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let i = rows.lastIndex(where: { abs($0.midY - p.box.midY) < max($0.height, p.box.height) / 2 }) {
                rows[i].items.append((p.box.minX, p.text))
            } else {
                rows.append((p.box.midY, p.box.height, [(p.box.minX, p.text)]))
            }
        }
        return rows.map { $0.items.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
    }
}
