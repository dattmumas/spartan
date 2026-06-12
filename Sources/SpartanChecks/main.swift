// Assertion-based logic checks (Command Line Tools ship no XCTest).
// Run with: make check
import Foundation
import CoreGraphics
import CoreVideo
import SpartanCore

var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("  ok  \(name)")
    } else {
        print("FAIL  \(name)")
        failures += 1
    }
}

func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.6, h: CGFloat = 0.02,
          conf: Float = 0.9) -> OCRLine {
    OCRLine(text: text, bbox: CGRect(x: x, y: y, width: w, height: h), confidence: conf)
}

func words(_ n: Int, seed: String = "word") -> String {
    (0..<n).map { "\(seed)\($0)" }.joined(separator: " ")
}

// MARK: - TextNormalizer

print("TextNormalizer")
check(TextNormalizer.normalize("  Hello\n\tWORLD  ") == "hello world", "collapses whitespace + lowercases")
check(TextNormalizer.normalize("soft\u{00AD}hyphen") == "softhyphen", "strips soft hyphens")
check(TextNormalizer.hash("Hello  World") == TextNormalizer.hash("hello world\n"), "hash ignores formatting")
check(TextNormalizer.hash("alpha") != TextNormalizer.hash("beta"), "different text, different hash")

// MARK: - TextChunker

print("TextChunker")
let chunker = TextChunker()

// A paragraph of 5 lines x 20 words = 100 words → one reliable passage.
let para = (0..<5).map { i in
    line(words(20, seed: "p\(i)w"), x: 0.1, y: 0.8 - CGFloat(i) * 0.025)
}
let p1 = chunker.passages(from: para)
check(p1.count == 1, "contiguous lines merge into one passage")
check(p1.first.map { $0.wordCount >= 75 && !$0.lowConfidence } ?? false, "merged passage is reliable size")
check(p1.first?.lines.count == 5, "passage keeps all source lines")

// Noise filtering: low confidence and single-word lines dropped.
let noisy = para + [
    line("OK", x: 0.1, y: 0.3),
    line(words(10), x: 0.1, y: 0.25, conf: 0.2),
]
check(chunker.passages(from: noisy).count == 1, "noise lines are filtered out")

// Hyphenation joins across lines.
let hyph = [
    line(words(40) + " transfor-", x: 0.1, y: 0.8),
    line("mation " + words(40), x: 0.1, y: 0.775),
]
let p2 = chunker.passages(from: hyph)
check(p2.first?.text.contains("transformation") ?? false, "hyphenated line breaks rejoin")

// Two distant 40-word paragraphs → each scored on its own (low-confidence),
// never merged: merging dilutes a lone AI paragraph below threshold.
let blockA = (0..<2).map { i in line(words(20, seed: "a\(i)"), x: 0.1, y: 0.9 - CGFloat(i) * 0.025) }
let blockB = (0..<2).map { i in line(words(20, seed: "b\(i)"), x: 0.1, y: 0.4 - CGFloat(i) * 0.025) }
let p3 = chunker.passages(from: blockA + blockB)
check(p3.count == 2 && p3.allSatisfy { $0.wordCount == 40 && $0.lowConfidence },
      "40+ word paragraphs are scored individually")

// Enumerator-led paragraph at normal leading splits from preceding prose
// (the "8 C)" case: visually contiguous, semantically a separate paragraph).
let intro = (0..<3).map { i in line(words(20, seed: "h\(i)"), x: 0.1, y: 0.9 - CGFloat(i) * 0.022) }
let cPara = [
    line("C) " + words(19, seed: "c0"), x: 0.1, y: 0.9 - 3 * 0.022),
    line(words(20, seed: "c1"), x: 0.1, y: 0.9 - 4 * 0.022),
    line(words(20, seed: "c2"), x: 0.1, y: 0.9 - 5 * 0.022),
]
let p7 = chunker.passages(from: intro + cPara)
check(p7.count == 2 && p7[1].text.hasPrefix("C) "), "enumerator starts a new scored paragraph")

check(TextChunker.startsNewParagraph("C) Highest likelihood") , "detects letter enumerator")
check(TextChunker.startsNewParagraph("12. Gate the acquisition"), "detects numeric enumerator")
check(TextChunker.startsNewParagraph("• bullet item"), "detects bullet")
check(!TextChunker.startsNewParagraph("of the mandate; and"), "plain prose is not a paragraph start")
check(!TextChunker.startsNewParagraph("e.g. something"), "abbreviations are not enumerators")

// A lone 20-word fragment → discarded entirely (< 40-word floor).
check(chunker.passages(from: [line(words(20), x: 0.1, y: 0.5)]).isEmpty, "tiny fragments are discarded")

// A lone 50-word block → kept but flagged low-confidence (only text on screen).
let p4 = chunker.passages(from: [
    line(words(25, seed: "x"), x: 0.1, y: 0.5),
    line(words(25, seed: "y"), x: 0.1, y: 0.475),
])
check(p4.count == 1 && p4[0].lowConfidence, "lone 40–74-word block kept as low-confidence")

// Two columns: lines at x 0.05 and x 0.55 never merge into one passage text-wise.
let colL = (0..<4).map { i in line(words(20, seed: "L\(i)"), x: 0.05, y: 0.8 - CGFloat(i) * 0.025, w: 0.4) }
let colR = (0..<4).map { i in line(words(20, seed: "R\(i)"), x: 0.55, y: 0.8 - CGFloat(i) * 0.025, w: 0.4) }
let p5 = chunker.passages(from: colL + colR)
check(p5.count == 2, "columns chunk independently")
check(p5.allSatisfy { p in
    p.text.contains("L00") != p.text.contains("R00")
}, "column text does not interleave")

// Oversized block splits into multiple passages with sentences intact.
let bigLines = (0..<25).map { i in
    line(words(24, seed: "s\(i)") + ".", x: 0.1, y: 0.95 - CGFloat(i) * 0.025)
}
let p6 = chunker.passages(from: bigLines)  // 600 words
check(p6.count >= 2, "oversized block splits (600 words → \(p6.count) passages)")
check(p6.allSatisfy { !$0.lines.isEmpty }, "every split passage retains line geometry")
check(p6.reduce(0) { $0 + $1.lines.count } == 25, "split passages cover all lines exactly once")

// MARK: - PangramResponse decoding

print("PangramResponse")
let v3JSON = #"{"version":"3.3.2","headline":"AI Generated","prediction":"We believe...","fraction_ai":0.8,"fraction_ai_assisted":0.2,"fraction_human":0.0}"#
let v3 = try? JSONDecoder().decode(PangramResponse.self, from: Data(v3JSON.utf8))
check(v3.map { abs($0.aiLikelihood - 1.0) < 0.0001 && $0.prediction == "AI Generated" } ?? false,
      "v3 response: fraction_ai + assisted, headline as prediction")
check(v3?.windows.isEmpty ?? false, "v3 response without windows decodes to []")

let v3WindowsJSON = #"""
{"version":"3.3.2","headline":"Mixed","fraction_ai":0.5,"fraction_ai_assisted":0.0,"windows":[{"label":"AI-Generated","ai_assistance_score":0.97,"confidence":"High","start_index":12,"end_index":45,"word_count":6,"token_length":8},{"label":"Human","ai_assistance_score":0.03,"confidence":"Medium","start_index":46,"end_index":80,"word_count":6,"token_length":8}]}
"""#
let v3w = try? JSONDecoder().decode(PangramResponse.self, from: Data(v3WindowsJSON.utf8))
check(v3w?.windows.count == 2 && v3w?.windows.first?.label == "AI-Generated"
        && v3w?.windows.first?.startIndex == 12 && v3w?.windows.first?.endIndex == 45,
      "v3 windows array decodes with field renames")

let legacyJSON = #"{"ai_likelihood":0.93,"prediction":"Likely AI"}"#
let legacy = try? JSONDecoder().decode(PangramResponse.self, from: Data(legacyJSON.utf8))
check(legacy.map { $0.aiLikelihood == 0.93 && $0.prediction == "Likely AI" && $0.windows.isEmpty } ?? false,
      "legacy response shape still decodes; windows = []")

// DetectionResult cache compatibility: old snapshot lacks `windows` key.
let oldSnapshot = #"{"aiLikelihood":0.42,"prediction":"AI","requestID":null,"date":768000000}"#
let oldDR = try? JSONDecoder().decode(DetectionResult.self, from: Data(oldSnapshot.utf8))
check(oldDR?.aiLikelihood == 0.42 && (oldDR?.windows.isEmpty ?? false),
      "DetectionResult decodes pre-windows snapshot with default []")

// lineRanges: 3 synthetic lines join (incl. hyphen rejoin) — each range
// should overlap the line's first identifiable word.
let lr0 = OCRLine(text: "Renewable energy is power-", bbox: .zero, confidence: 1)
let lr1 = OCRLine(text: "ful and clean", bbox: .zero, confidence: 1)
let lr2 = OCRLine(text: "The future is here", bbox: .zero, confidence: 1)
let joinedLR = TextChunker.joinLines([lr0, lr1, lr2])
let ranges = TextChunker.lineRanges(of: [lr0, lr1, lr2], in: joinedLR)
check(ranges.count == 3, "lineRanges returns one range per line")
let scalars = Array(joinedLR.unicodeScalars)
func slice(_ r: Range<Int>) -> String {
    String(String.UnicodeScalarView(scalars[r.clamped(to: 0..<scalars.count)]))
        .lowercased()
}
check(slice(ranges[0]).contains("renewable"), "first line range contains its text")
check(slice(ranges[2]).contains("future"), "third line range contains its text")

// perLineScores: window spanning only line 2 at 0.99 with fallback 0.1 →
// [0.1, 0.99, 0.1].
let win1 = DetectionWindow(label: "AI", aiAssistanceScore: 0.99, confidence: "High",
                           startIndex: ranges[1].lowerBound, endIndex: ranges[1].upperBound)
let perLine = WindowMapping.perLineScores(
    lineRanges: ranges, windows: [win1], fallback: 0.1
)
check(perLine.count == 3 && abs(perLine[0] - 0.1) < 0.001
        && abs(perLine[1] - 0.99) < 0.001 && abs(perLine[2] - 0.1) < 0.001,
      "perLineScores assigns window to overlapping line only")

check(WindowMapping.perLineScores(lineRanges: ranges, windows: [], fallback: 0.42)
        == [0.42, 0.42, 0.42],
      "empty windows array yields fallback per line")

// MARK: - GeometryMapping

print("GeometryMapping")
let win = CGSize(width: 1000, height: 500)
let r1 = GeometryMapping.windowRect(
    fromNormalized: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.1), windowSize: win
)
check(abs(r1.minX - 100) < 0.001 && abs(r1.minY - 50) < 0.001, "normalized → window points flips Y")
check(abs(r1.width - 500) < 0.001 && abs(r1.height - 50) < 0.001, "normalized → window points scales size")

let cocoa = GeometryMapping.cocoaFrame(
    fromCGFrame: CGRect(x: 100, y: 200, width: 800, height: 600), primaryScreenHeight: 1080
)
check(cocoa == CGRect(x: 100, y: 280, width: 800, height: 600), "CG → Cocoa frame conversion")

let u = GeometryMapping.union(of: [
    CGRect(x: 0, y: 0, width: 10, height: 10),
    CGRect(x: 20, y: 20, width: 10, height: 10),
])
check(u == CGRect(x: 0, y: 0, width: 30, height: 30), "union of rects")

// MARK: - PassageCache

print("PassageCache")
let sem = DispatchSemaphore(value: 0)
Task {
    let cache = PassageCache(capacity: 3)
    let passage = Passage(text: words(80, seed: "c"), lines: (0..<4).map { i in
        line(words(20, seed: "c\(i)"), x: 0.1, y: 0.8 - CGFloat(i) * 0.025)
    }, lowConfidence: false)

    if case .miss = await cache.lookup(passage) {
        check(true, "empty cache misses")
    } else {
        check(false, "empty cache misses")
    }

    let result = DetectionResult(aiLikelihood: 0.93, prediction: "Likely AI", requestID: "r1")
    await cache.store(result, for: passage)

    if case .exact(let hit) = await cache.lookup(passage), hit.aiLikelihood == 0.93 {
        check(true, "exact hit after store")
    } else {
        check(false, "exact hit after store")
    }

    // Same 4 lines plus 1 new one (80% line coverage) → fuzzy hit.
    let scrolled = Passage(
        text: passage.text + " " + words(20, seed: "new"),
        lines: passage.lines + [line(words(20, seed: "new"), x: 0.1, y: 0.7)],
        lowConfidence: false
    )
    if case .fuzzy(let hit) = await cache.lookup(scrolled), hit.aiLikelihood == 0.93 {
        check(true, "scrolled passage reuses score via fuzzy line match")
    } else {
        check(false, "scrolled passage reuses score via fuzzy line match")
    }

    // Mostly-new passage (1 of 4 lines known, 25%) → miss.
    let fresh = Passage(
        text: words(80, seed: "f"),
        lines: [passage.lines[0]] + (0..<3).map { i in
            line(words(20, seed: "f\(i)"), x: 0.1, y: 0.5 - CGFloat(i) * 0.025)
        },
        lowConfidence: false
    )
    if case .miss = await cache.lookup(fresh) {
        check(true, "low line coverage misses")
    } else {
        check(false, "low line coverage misses")
    }

    // LRU eviction at capacity 3.
    for i in 0..<4 {
        let p = Passage(text: words(80, seed: "evict\(i)"), lines: [], lowConfidence: false)
        await cache.store(DetectionResult(aiLikelihood: 0.1, prediction: nil, requestID: nil), for: p)
    }
    let evicted = Passage(text: words(80, seed: "evict0"), lines: [], lowConfidence: false)
    if case .miss = await cache.lookup(evicted) {
        check(true, "LRU evicts oldest beyond capacity")
    } else {
        check(false, "LRU evicts oldest beyond capacity")
    }

    // Persistence round-trip.
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".json")
    let persistA = PassageCache(capacity: 10, persistURL: tmpURL)
    let p = Passage(text: words(80, seed: "persist"), lines: [], lowConfidence: false)
    await persistA.store(
        DetectionResult(aiLikelihood: 0.42, prediction: "AI", requestID: nil),
        for: p
    )
    await persistA.saveIfDirty()
    let persistB = PassageCache(capacity: 10, persistURL: tmpURL)
    if case .exact(let hit) = await persistB.lookup(p), hit.aiLikelihood == 0.42 {
        check(true, "cache reloads from disk after saveIfDirty")
    } else {
        check(false, "cache reloads from disk after saveIfDirty")
    }
    try? FileManager.default.removeItem(at: tmpURL)
    sem.signal()
}
sem.wait()

// MARK: - SelectionClassifier

print("SelectionClassifier")

func makeBuffer(_ size: Int, paint: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<size {
        for x in 0..<size {
            let (r, g, b) = paint(x, y)
            let p = y * rowBytes + x * 4
            base[p] = b; base[p + 1] = g; base[p + 2] = r; base[p + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

let S = 400
// Six "lines" of 20 words each, stacked top-to-bottom; lines 2 and 3 selected.
let selLines: [OCRLine] = (0..<6).map { i in
    let maxY = 0.9 - CGFloat(i) * 0.08
    return OCRLine(
        text: words(20, seed: "sel\(i)"),
        bbox: CGRect(x: 0.1, y: maxY - 0.05, width: 0.8, height: 0.05),
        confidence: 1.0
    )
}
func bandRange(_ i: Int) -> ClosedRange<Int> {
    let maxY = 0.9 - Double(i) * 0.08
    return Int((1 - maxY) * Double(S))...Int((1 - maxY + 0.05) * Double(S))
}
let selBands = [bandRange(2), bandRange(3)]
let highlight: (UInt8, UInt8, UInt8) = (178, 200, 255)

let plain = makeBuffer(S) { _, _ in (255, 255, 255) }
let withSelection = makeBuffer(S) { x, y in
    if selBands.contains(where: { $0.contains(y) }) {
        // Glyph noise: every 3rd column is text-colored; median must reject it.
        return x % 3 == 0 ? (20, 20, 20) : highlight
    }
    return (255, 255, 255)
}

let classifier = SelectionClassifier()

// First scan establishes history; detection must never fire without history.
let (selR0, plainHistory, _) = classifier.classify(lines: selLines, buffer: plain, history: nil)
check(selR0 == nil && plainHistory.byHash.count == 6 && plainHistory.lines.count == 6,
      "first scan (no history) never detects, records observations")

let (selR1, selHistory, _) = classifier.classify(
    lines: selLines, buffer: withSelection, history: plainHistory
)
if let selR1 {
    let texts = selR1.selectedLines.map(\.text)
    check(texts.count == 2 && texts.contains(selLines[2].text) && texts.contains(selLines[3].text),
          "same text + changed background selects exactly the highlighted lines")
    check(classifier.pointsStillHighlighted(selR1.samplePoints, color: selR1.highlightColor, in: withSelection),
          "stored points re-verify on the same frame")
    check(!classifier.pointsStillHighlighted(selR1.samplePoints, color: selR1.highlightColor, in: plain),
          "stored points fail on a frame without the highlight")
} else {
    check(false, "same text + changed background selects exactly the highlighted lines")
    check(false, "stored points re-verify on the same frame")
    check(false, "stored points fail on a frame without the highlight")
}

check(classifier.classify(lines: selLines, buffer: withSelection, history: selHistory).result == nil,
      "unchanged highlight (pre-existing decoration) does not re-trigger")
check(classifier.classify(lines: selLines, buffer: plain, history: plainHistory).result == nil,
      "uniform page yields no selection")

// OCR re-reads a selected line differently (hash miss) → bbox-overlap fallback.
var reread = selLines
reread[2] = OCRLine(text: selLines[2].text + " xtra", bbox: selLines[2].bbox, confidence: 1.0)
let (selR2, _, _) = classifier.classify(lines: reread, buffer: withSelection, history: plainHistory)
check(selR2?.selectedLines.count == 2, "bbox-overlap fallback survives OCR re-reads")

// Single-line highlight = clicked button / sidebar item / hover — always
// rejected (single-line drag selections are the AX path's job).
let oneBand = makeBuffer(S) { x, y in
    bandRange(2).contains(y) ? (x % 3 == 0 ? (20, 20, 20) : highlight) : (255, 255, 255)
}
check(classifier.classify(lines: selLines, buffer: oneBand, history: plainHistory).result == nil,
      "single-line highlight (button/hover) is always rejected")
let accentAware = SelectionClassifier(accentColors: [
    .init(r: Int(highlight.0), g: Int(highlight.1), b: Int(highlight.2))
])
check(accentAware.classify(lines: selLines, buffer: oneBand, history: plainHistory).result == nil,
      "even accent-colored single lines are rejected")

check(TextChunker.joinLines([
    OCRLine(text: "first part trans-", bbox: .zero, confidence: 1),
    OCRLine(text: "formation done", bbox: .zero, confidence: 1),
]) == "first part transformation done", "joinLines rejoins hyphenated breaks")

// MARK: - VerdictStore

print("VerdictStore")
let storeSem = DispatchSemaphore(value: 0)
Task {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("spartan-verdicts-" + UUID().uuidString)
    let store = VerdictStore(directory: dir)
    let now = Date()
    let recA = VerdictRecord(
        date: now, appName: "TestApp", source: "continuous",
        passageHash: "aaaa", text: "First, quoted \"value\"\nand a newline",
        words: 5, score: 0.91, headline: "AI Generated", lowConfidence: false
    )
    let wroteA = await store.append(recA, screenshot: Data([0x89, 0x50, 0x4E, 0x47]))
    check(wroteA, "first append returns true")
    let dupA = await store.append(recA, screenshot: nil)
    check(!dupA, "same-day duplicate passageHash is skipped")
    let recB = VerdictRecord(
        date: now, appName: "TestApp", source: "selection",
        passageHash: "bbbb", text: "Second record",
        words: 2, score: 0.12, headline: "Human", lowConfidence: true
    )
    _ = await store.append(recB, screenshot: nil)
    let listed = await store.recent(limit: 10)
    check(listed.count == 2, "recent returns both records")
    check(listed.first?.passageHash == "bbbb", "newest record is first")

    let csv = store.csv(records: listed)
    check(csv.contains("\"First, quoted \"\"value\"\" and a newline\""),
          "csv quotes commas, escapes quotes, and flattens newlines")
    check(csv.contains("Second record"), "csv includes both rows")

    // Purge old days: write a fake 2000-01-01 file.
    let oldFile = dir.appendingPathComponent("2000-01-01.jsonl")
    try? Data("\n".utf8).write(to: oldFile)
    await store.purge(olderThanDays: 1)
    check(!FileManager.default.fileExists(atPath: oldFile.path),
          "purge deletes files older than cutoff")

    try? FileManager.default.removeItem(at: dir)
    storeSem.signal()
}
storeSem.wait()

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
