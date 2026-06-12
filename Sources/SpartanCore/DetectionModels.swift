import Foundation
import CoreGraphics

/// One recognized line of text. `bbox` is Vision-normalized (0–1, bottom-left origin).
public struct OCRLine: Sendable, Equatable {
    public let text: String
    public let bbox: CGRect
    public let confidence: Float

    public init(text: String, bbox: CGRect, confidence: Float) {
        self.text = text
        self.bbox = bbox
        self.confidence = confidence
    }

    public var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// A detection-sized passage assembled from one or more OCR lines.
public struct Passage: Sendable {
    public let text: String
    public let lines: [OCRLine]
    public let wordCount: Int
    public let hash: String
    public let lineHashes: [String]
    /// Per-line ranges within `text` (unicodeScalar offsets). Populated by
    /// `TextChunker.lineRanges`; empty for caller-built passages.
    public let lineRanges: [Range<Int>]
    /// Below Pangram's reliable minimum (75 words); scored but flagged.
    public let lowConfidence: Bool

    public init(text: String, lines: [OCRLine], lowConfidence: Bool) {
        self.text = text
        self.lines = lines
        self.wordCount = text.split(whereSeparator: \.isWhitespace).count
        self.hash = TextNormalizer.hash(text)
        self.lineHashes = lines.map { TextNormalizer.hash($0.text) }
        self.lineRanges = TextChunker.lineRanges(of: lines, in: text)
        self.lowConfidence = lowConfidence
    }
}

/// Per-window (≈ per-sentence) classification from Pangram v3's `windows`.
public struct DetectionWindow: Sendable, Codable, Equatable {
    public let label: String
    public let aiAssistanceScore: Double
    public let confidence: String?
    public let startIndex: Int
    public let endIndex: Int

    public init(
        label: String,
        aiAssistanceScore: Double,
        confidence: String?,
        startIndex: Int,
        endIndex: Int
    ) {
        self.label = label
        self.aiAssistanceScore = aiAssistanceScore
        self.confidence = confidence
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}

public struct DetectionResult: Sendable, Codable {
    public let aiLikelihood: Double
    public let prediction: String?
    public let requestID: String?
    public let date: Date
    public let windows: [DetectionWindow]

    public init(
        aiLikelihood: Double,
        prediction: String?,
        requestID: String?,
        date: Date = Date(),
        windows: [DetectionWindow] = []
    ) {
        self.aiLikelihood = aiLikelihood
        self.prediction = prediction
        self.requestID = requestID
        self.date = date
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case aiLikelihood, prediction, requestID, date, windows
    }

    /// Pre-windows snapshots in the disk cache lack `windows`; default to [].
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aiLikelihood = try c.decode(Double.self, forKey: .aiLikelihood)
        prediction = try c.decodeIfPresent(String.self, forKey: .prediction)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        windows = (try? c.decode([DetectionWindow].self, forKey: .windows)) ?? []
    }
}

/// Pangram v3 response (model 3.3.x). Lenient decode: only the fraction fields
/// are required; falls back to the legacy `ai_likelihood` shape if present.
/// The legacy endpoint (text.api.pangramlabs.com, sunset 2026-04-01) kept
/// answering with a stale model that scored known-AI text as human — never
/// reintroduce it.
public struct PangramResponse: Decodable, Sendable {
    public let aiLikelihood: Double
    public let prediction: String?
    public let windows: [DetectionWindow]

    enum CodingKeys: String, CodingKey {
        case fractionAI = "fraction_ai"
        case fractionAIAssisted = "fraction_ai_assisted"
        case headline
        case prediction
        case aiLikelihoodLegacy = "ai_likelihood"
        case windows
    }

    private struct RawWindow: Decodable {
        let label: String
        let aiAssistanceScore: Double
        let confidence: String?
        let startIndex: Int
        let endIndex: Int

        enum CodingKeys: String, CodingKey {
            case label
            case aiAssistanceScore = "ai_assistance_score"
            case confidence
            case startIndex = "start_index"
            case endIndex = "end_index"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let fractionAI = try? c.decode(Double.self, forKey: .fractionAI) {
            let assisted = (try? c.decode(Double.self, forKey: .fractionAIAssisted)) ?? 0
            aiLikelihood = min(1.0, fractionAI + assisted)
            prediction = (try? c.decode(String.self, forKey: .headline))
                ?? (try? c.decode(String.self, forKey: .prediction))
            let raws = (try? c.decode([RawWindow].self, forKey: .windows)) ?? []
            windows = raws.map {
                DetectionWindow(
                    label: $0.label,
                    aiAssistanceScore: $0.aiAssistanceScore,
                    confidence: $0.confidence,
                    startIndex: $0.startIndex,
                    endIndex: $0.endIndex
                )
            }
        } else {
            aiLikelihood = try c.decode(Double.self, forKey: .aiLikelihoodLegacy)
            prediction = try? c.decode(String.self, forKey: .prediction)
            windows = []
        }
    }
}

public enum DetectorError: Error, CustomStringConvertible {
    case missingAPIKey
    case invalidAPIKey
    case outOfCredits
    case rateLimited
    case server(Int)
    case network(String)
    case badResponse

    public var description: String {
        switch self {
        case .missingAPIKey: return "No Pangram API key set"
        case .invalidAPIKey: return "Pangram API key rejected (401/403)"
        case .outOfCredits: return "Pangram account out of credits (402)"
        case .rateLimited: return "Pangram rate limit hit (429)"
        case .server(let code): return "Pangram server error (\(code))"
        case .network(let msg): return "Network error: \(msg)"
        case .badResponse: return "Unparseable Pangram response"
        }
    }
}

public protocol AIDetector: Sendable {
    func detect(_ text: String) async throws -> DetectionResult
}
