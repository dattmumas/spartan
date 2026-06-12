import Foundation
import CoreGraphics

/// Assembles raw OCR lines into Pangram-sized passages.
///
/// Pipeline: filter noise → cluster lines into columns by horizontal overlap →
/// merge vertically-adjacent lines into paragraph blocks → pack blocks into
/// 75–400-word passages (Pangram needs ~75+ words for reliable scores).
public struct TextChunker: Sendable {
    public var minLineConfidence: Float = 0.4
    public var minLineWords = 2
    public var reliableWords = 75
    public var lowConfidenceFloorWords = 40
    public var maxPassageWords = 400
    public var splitTargetWords = 250
    /// Vertical gap (in multiples of median line height) above which a new block starts.
    public var blockGapFactor: CGFloat = 1.6
    /// Minimum horizontal overlap (fraction of the narrower line) for same-column membership.
    public var columnOverlap: CGFloat = 0.5

    public init() {}

    public func passages(from rawLines: [OCRLine]) -> [Passage] {
        let lines = rawLines.filter {
            $0.confidence >= minLineConfidence && $0.wordCount >= minLineWords
        }
        guard !lines.isEmpty else { return [] }

        let columns = clusterIntoColumns(lines)
        var blocks: [[OCRLine]] = []
        for column in columns {
            blocks.append(contentsOf: mergeIntoBlocks(column))
        }
        return pack(blocks: blocks)
    }

    // MARK: - Columns

    private func clusterIntoColumns(_ lines: [OCRLine]) -> [[OCRLine]] {
        var columns: [(range: ClosedRange<CGFloat>, lines: [OCRLine])] = []
        for line in lines {
            let lo = line.bbox.minX, hi = line.bbox.maxX
            var matched = false
            for i in columns.indices {
                let r = columns[i].range
                let overlap = min(hi, r.upperBound) - max(lo, r.lowerBound)
                let narrower = min(hi - lo, r.upperBound - r.lowerBound)
                if narrower > 0, overlap / narrower >= columnOverlap {
                    columns[i].lines.append(line)
                    columns[i].range = min(lo, r.lowerBound)...max(hi, r.upperBound)
                    matched = true
                    break
                }
            }
            if !matched {
                columns.append((lo...hi, [line]))
            }
        }
        // Read order: left-to-right columns.
        return columns
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map { $0.lines }
    }

    // MARK: - Blocks

    private func mergeIntoBlocks(_ column: [OCRLine]) -> [[OCRLine]] {
        // Vision is bottom-left origin: top of frame = high y. Sort top-to-bottom.
        let sorted = column.sorted { $0.bbox.maxY > $1.bbox.maxY }
        let heights = sorted.map { $0.bbox.height }.sorted()
        let median = heights[heights.count / 2]
        let maxGap = median * blockGapFactor

        var blocks: [[OCRLine]] = []
        var current: [OCRLine] = []
        for line in sorted {
            if let prev = current.last {
                let gap = prev.bbox.minY - line.bbox.maxY
                if gap > maxGap || Self.startsNewParagraph(line.text) {
                    blocks.append(current)
                    current = []
                }
            }
            current.append(line)
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    /// Heuristic paragraph boundary: enumerators ("A)", "3.", "12)") and bullets.
    /// Visual gaps alone miss list items set at normal leading, which then blend
    /// into one passage and dilute per-paragraph detection.
    public static func startsNewParagraph(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return false }
        if "•‣▪◦*–—".contains(first), t.count > 1,
           t[t.index(after: t.startIndex)] == " " {
            return true
        }
        var idx = t.startIndex
        var alnum = 0
        while idx < t.endIndex, t[idx].isLetter || t[idx].isNumber, alnum < 3 {
            idx = t.index(after: idx)
            alnum += 1
        }
        guard (1...2).contains(alnum), idx < t.endIndex,
              t[idx] == ")" || t[idx] == "." else { return false }
        let after = t.index(after: idx)
        return after < t.endIndex && t[after] == " "
    }

    /// Joins lines in the given order, rejoining hyphenated line breaks.
    /// Shared by the chunker and the selection-mode text assembly.
    public static func joinLines(_ lines: [OCRLine]) -> String {
        var out = ""
        for line in lines {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            if out.isEmpty {
                out = t
            } else if out.hasSuffix("-") {
                out.removeLast()
                out += t
            } else {
                out += " " + t
            }
        }
        return out
    }

    private func joinedText(_ lines: [OCRLine]) -> String {
        Self.joinLines(lines)
    }

    // MARK: - Passages

    /// Packing rules (per-paragraph granularity — a lone AI paragraph amid human
    /// text must be scored on its own, or the mix dilutes it below threshold):
    ///   ≥75 words  → its own passage (split if >400)
    ///   40–74 words → its own passage, flagged low-confidence
    ///   <40 words  → concatenated with adjacent fragments; the accumulation is
    ///                flushed at ≥75 (full) or, when interrupted/at end, ≥40
    ///                (low-confidence); smaller leftovers are discarded.
    private func pack(blocks: [[OCRLine]]) -> [Passage] {
        var passages: [Passage] = []
        var pendingLines: [OCRLine] = []
        var pendingText = ""

        func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

        func flushPending() {
            let wc = wordCount(pendingText)
            if wc >= lowConfidenceFloorWords {
                passages.append(Passage(
                    text: pendingText, lines: pendingLines,
                    lowConfidence: wc < reliableWords
                ))
            }
            pendingLines = []
            pendingText = ""
        }

        for block in blocks {
            let text = joinedText(block)
            let wc = wordCount(text)
            if wc >= lowConfidenceFloorWords {
                flushPending()
                if wc > maxPassageWords {
                    passages.append(contentsOf: split(block: block, text: text))
                } else {
                    passages.append(Passage(
                        text: text, lines: block,
                        lowConfidence: wc < reliableWords
                    ))
                }
            } else {
                if pendingText.isEmpty {
                    pendingText = text
                } else {
                    pendingText += "\n\n" + text
                }
                pendingLines.append(contentsOf: block)
                if wordCount(pendingText) >= reliableWords {
                    flushPending()
                }
            }
        }
        flushPending()
        return passages
    }

    /// Split an oversized block at sentence boundaries into ~splitTargetWords passages,
    /// distributing the block's lines by cumulative word count.
    private func split(block: [OCRLine], text: String) -> [Passage] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?".contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current) }

        var chunks: [String] = []
        var chunk = ""
        var chunkWords = 0
        for s in sentences {
            let w = s.split(whereSeparator: \.isWhitespace).count
            if chunkWords + w > splitTargetWords, chunkWords >= reliableWords {
                chunks.append(chunk)
                chunk = ""
                chunkWords = 0
            }
            chunk += s
            chunkWords += w
        }
        if chunkWords > 0 { chunks.append(chunk) }

        // Distribute lines across chunks by cumulative word count.
        var passages: [Passage] = []
        var lineIdx = 0
        var consumedWords = 0
        var runningTarget = 0
        for (i, chunkText) in chunks.enumerated() {
            runningTarget += chunkText.split(whereSeparator: \.isWhitespace).count
            var lines: [OCRLine] = []
            if i == chunks.count - 1 {
                if lineIdx < block.count { lines = Array(block[lineIdx...]) }
                lineIdx = block.count
            } else {
                while lineIdx < block.count,
                      lines.isEmpty || consumedWords + block[lineIdx].wordCount / 2 <= runningTarget {
                    lines.append(block[lineIdx])
                    consumedWords += block[lineIdx].wordCount
                    lineIdx += 1
                }
            }
            if !lines.isEmpty {
                passages.append(Passage(
                    text: chunkText.trimmingCharacters(in: .whitespaces),
                    lines: lines,
                    lowConfidence: false
                ))
            }
        }
        return passages
    }
}
