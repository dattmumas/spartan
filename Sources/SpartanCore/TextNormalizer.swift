import Foundation
import CryptoKit

public enum TextNormalizer {
    /// NFKC, lowercased, whitespace collapsed, soft hyphens / zero-width chars stripped.
    public static func normalize(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping.lowercased()
        s = s.replacingOccurrences(of: "\u{00AD}", with: "")
        s = s.replacingOccurrences(of: "\u{200B}", with: "")
        s = s.replacingOccurrences(of: "\u{200C}", with: "")
        s = s.replacingOccurrences(of: "\u{200D}", with: "")
        s = s.replacingOccurrences(of: "\u{FEFF}", with: "")
        let parts = s.split(whereSeparator: \.isWhitespace)
        return parts.joined(separator: " ")
    }

    public static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(normalize(text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
