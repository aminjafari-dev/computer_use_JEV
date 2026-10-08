import CoreGraphics
import PilotCore
import Vision

enum VisionOCRService {
    static func recognize(capture: WindowCapture) throws -> [UIElementObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: capture.image)
        try handler.perform([request])
        let results = request.results ?? []
        return results.enumerated().compactMap { index, observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = observation.boundingBox
            let bounds = CoordinateConverter.visionBoxToGlobal(
                originX: box.origin.x,
                originY: box.origin.y,
                boxWidth: box.width,
                boxHeight: box.height,
                imageWidth: Double(capture.image.width),
                imageHeight: Double(capture.image.height),
                captureGlobal: capture.globalRect,
                scale: capture.scale
            )
            return UIElementObservation(
                id: "ocr-\(index)-\(text.prefix(24))",
                label: text,
                role: "OCRText",
                enabled: true,
                bounds: bounds,
                supportedActions: [],
                sources: [.ocr]
            )
        }
    }
}
