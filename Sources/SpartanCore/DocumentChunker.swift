import Foundation

public enum DocumentChunker {
    public struct Section: Sendable, Equatable {
        public let text: String
        public let lowConfidence: Bool
        public init(text: String, lowConfidence: Bool) {
            self.text = text
            self.lowConfidence = lowConfidence
        }
    }

    private static let reliableWords = 75
    private static let lowConfidenceFloorWords = 40
    private static let maxPassageWords = 400
    private static let splitTargetWords = 250

    /// Mirrors `TextChunker.pack` on a plain-string input: paragraph by
    /// blank-line, then pack to scoring-sized sections. The small duplication
    /// is intentional — the OCR-line chunker keeps line geometry that document
    /// mode doesn't need.
    public static func sections(from text: String) -> [Section] {
        let paragraphs = paragraphs(in: text)
        var sections: [Section] = []
        var pending = ""

        func wc(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
        func flushPending() {
            let n = wc(pending)
            if n >= lowConfidenceFloorWords {
                sections.append(Section(text: pending, lowConfidence: n < reliableWords))
            }
            pending = ""
        }

        for paragraph in paragraphs {
            let n = wc(paragraph)
            if n >= lowConfidenceFloorWords {
                flushPending()
                if n > maxPassageWords {
                    sections.append(contentsOf: split(paragraph))
                } else {
                    sections.append(Section(text: paragraph, lowConfidence: n < reliableWords))
                }
            } else {
                pending = pending.isEmpty ? paragraph : pending + "\n\n" + paragraph
                if wc(pending) >= reliableWords {
                    flushPending()
                }
            }
        }
        flushPending()
        return sections
    }

    private static func paragraphs(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    out.append(current)
                    current = ""
                }
            } else {
                current = current.isEmpty ? trimmed : current + " " + trimmed
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func split(_ paragraph: String) -> [Section] {
        var sentences: [String] = []
        var current = ""
        for ch in paragraph {
            current.append(ch)
            if ".!?".contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current)
        }

        var sections: [Section] = []
        var chunk = ""
        var chunkWords = 0
        for s in sentences {
            let w = s.split(whereSeparator: \.isWhitespace).count
            if chunkWords + w > splitTargetWords, chunkWords >= reliableWords {
                sections.append(Section(text: chunk.trimmingCharacters(in: .whitespaces),
                                        lowConfidence: false))
                chunk = ""
                chunkWords = 0
            }
            chunk += s
            chunkWords += w
        }
        if chunkWords > 0 {
            sections.append(Section(text: chunk.trimmingCharacters(in: .whitespaces),
                                    lowConfidence: chunkWords < reliableWords))
        }
        return sections
    }
}
