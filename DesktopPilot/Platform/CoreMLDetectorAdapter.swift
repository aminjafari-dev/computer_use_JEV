import CoreML
import PilotCore
import Vision

/// Loads a bundled `UIDetector.mlmodelc` when one is present.
/// A missing or incompatible model yields no detections. Nothing is invented.
final class CoreMLDetectorAdapter: @unchecked Sendable {
    private let model: MLModel?
    let status: String

    init(model: MLModel?, status: String) {
        self.model = model
        self.status = status
    }

    static func bundled() -> CoreMLDetectorAdapter {
        guard let url = Bundle.main.url(forResource: "UIDetector", withExtension: "mlmodelc") else {
            return CoreMLDetectorAdapter(model: nil, status: "No Core ML model is installed. Accessibility and text recognition are active.")
        }
        do {
            let model = try MLModel(contentsOf: url)
            return CoreMLDetectorAdapter(model: model, status: "Core ML model loaded.")
        } catch {
            return CoreMLDetectorAdapter(model: nil, status: "The Core ML model could not be loaded. Accessibility and text recognition are active.")
        }
    }

    func detect(capture: WindowCapture) -> [UIElementObservation] {
        guard let model, let visionModel = try? VNCoreMLModel(for: model) else { return [] }
        let request = VNCoreMLRequest(model: visionModel)
        let handler = VNImageRequestHandler(cgImage: capture.image)
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let objects = request.results as? [VNRecognizedObjectObservation] else { return [] }
        return objects.enumerated().compactMap { index, object in
            guard let label = object.labels.first?.identifier, !label.isEmpty else { return nil }
            let box = object.boundingBox
            let bounds = CoordinateConverter.visionBoxToGlobal(
                originX: box.origin.x, originY: box.origin.y, boxWidth: box.width, boxHeight: box.height,
                imageWidth: Double(capture.image.width), imageHeight: Double(capture.image.height),
                captureGlobal: capture.globalRect, scale: capture.scale
            )
            return UIElementObservation(
                id: "ml-\(index)-\(label)",
                label: label,
                role: "DetectedControl",
                enabled: true,
                bounds: bounds,
                supportedActions: [],
                sources: [.coreML]
            )
        }
    }
}
