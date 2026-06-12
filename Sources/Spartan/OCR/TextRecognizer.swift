import Foundation
import Vision
import CoreVideo
import SpartanCore

struct TextRecognizer {
    /// Recognize text lines in a captured frame. Safe to call from any context;
    /// Vision does its own internal multithreading.
    func recognize(_ pixelBuffer: CVPixelBuffer) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // Skip per-frame language detection; meaningfully faster.
                request.automaticallyDetectsLanguage = false
                request.recognitionLanguages = ["en-US"]

                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
                do {
                    try handler.perform([request])
                    let lines: [OCRLine] = (request.results ?? []).compactMap { obs in
                        guard let candidate = obs.topCandidates(1).first else { return nil }
                        return OCRLine(
                            text: candidate.string,
                            bbox: obs.boundingBox,
                            confidence: candidate.confidence
                        )
                    }
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
