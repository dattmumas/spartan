import Foundation
import CoreVideo
import CoreGraphics

/// Detects which OCR lines the user has text-selected, purely from pixels.
///
/// Strategy: per line, estimate the background color from ~24 samples in the
/// ascender/descender gutters using a per-channel median (rejects glyph-pixel
/// outliers). A line is a selection candidate when its background departs from
/// the page background. The system accent color acts only as a prior that
/// lowers the contrast threshold — many apps don't derive their highlight from
/// it. When a previous settled frame exists, candidates are confirmed by
/// frame-diff (a real selection appeared; zebra stripes pre-existed).
/// Cost: lines × ~48 pixel reads — sub-millisecond.
public struct SelectionClassifier: Sendable {
    public struct RGB: Sendable, Equatable {
        public var r: Int, g: Int, b: Int
        public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }

        func distance(to other: RGB) -> Int {
            max(abs(r - other.r), max(abs(g - other.g), abs(b - other.b)))
        }
    }

    public struct SamplePoint: Sendable, Equatable {
        public let x: Int, y: Int
    }

    public struct Result: Sendable {
        public let selectedLines: [OCRLine]
        /// Sample points of the selected lines (for later "is the highlight
        /// still on screen" re-checks).
        public let samplePoints: [SamplePoint]
        public let highlightColor: RGB
    }

    /// Per-line background observations from the previous settled scan.
    public struct History: Sendable {
        public var byHash: [String: RGB]
        public var lines: [(bbox: CGRect, bg: RGB)]
        public init(byHash: [String: RGB] = [:], lines: [(bbox: CGRect, bg: RGB)] = []) {
            self.byHash = byHash
            self.lines = lines
        }
        public var isEmpty: Bool { byHash.isEmpty && lines.isEmpty }
    }

    /// Required background departure from the page background (max channel Δ).
    public var contrastThreshold = 24
    /// Lowered threshold when a line's background sits near an accent color.
    public var priorThreshold = 12
    public var accentMatchDistance = 40
    /// Candidates must agree on one highlight color within this tolerance.
    public var clusterTolerance = 18
    public var samplesPerRow = 12
    public var accentColors: [RGB]

    public init(accentColors: [RGB] = []) {
        self.accentColors = accentColors
    }

    // MARK: - Classification

    /// The decisive selection signal is **same line, changed background**:
    /// scrolled-in text fails (no history for it), static chrome/zebra rows
    /// fail (background never changes), and a fresh window (no history)
    /// detects nothing until the next settle. History is matched by line-text
    /// hash first, then by bbox overlap (OCR can re-read a selected line
    /// slightly differently, which would break a hash-only match).
    ///
    /// Returns the selection (if any), this frame's observations for the next
    /// call, and a one-line diagnostic for logging.
    public func classify(
        lines: [OCRLine],
        buffer: CVPixelBuffer,
        history: History?
    ) -> (result: Result?, observed: History, debug: String) {
        guard !lines.isEmpty, let reader = PixelReader(buffer) else {
            return (nil, History(), "no-lines-or-bad-buffer")
        }

        var lineBGs: [RGB] = []
        var linePoints: [[SamplePoint]] = []
        var observed = History()
        for line in lines {
            let points = samplePoints(for: line.bbox, width: reader.width, height: reader.height)
            let bg = Self.median(points.map(reader.color(at:)))
            linePoints.append(points)
            lineBGs.append(bg)
            observed.byHash[TextNormalizer.hash(line.text)] = bg
            observed.lines.append((line.bbox, bg))
        }
        guard let history, !history.isEmpty else {
            return (nil, observed, "no-history")  // never guess on first sight
        }

        let pageBG = Self.median(lineBGs)
        var offPage = 0, withHistory = 0
        var candidates: [Int] = []
        for (i, bg) in lineBGs.enumerated() {
            // Must depart from the page background…
            let nearAccent = accentColors.contains { bg.distance(to: $0) <= accentMatchDistance }
            let threshold = nearAccent ? priorThreshold : contrastThreshold
            guard bg.distance(to: pageBG) > threshold else { continue }
            offPage += 1
            // …AND be a line we saw before whose background just changed.
            var prevBG = history.byHash[TextNormalizer.hash(lines[i].text)]
            if prevBG == nil {
                prevBG = Self.bestOverlap(for: lines[i].bbox, in: history.lines)
            }
            guard let prevBG else { continue }
            withHistory += 1
            if prevBG.distance(to: bg) > clusterTolerance {
                candidates.append(i)
            }
        }
        let debugBase = "lines=\(lines.count) offPage=\(offPage) matched=\(withHistory) changed=\(candidates.count)"
        guard !candidates.isEmpty else { return (nil, observed, debugBase) }

        // One selection = one highlight color: cluster around the candidate median.
        let highlight = Self.median(candidates.map { lineBGs[$0] })
        candidates = candidates.filter { lineBGs[$0].distance(to: highlight) <= clusterTolerance }

        // A single-line "selection" is indistinguishable from a clicked button,
        // selected sidebar item, or hover highlight — reject outright. Real
        // single-line drag selections are caught by the AX path instead.
        guard candidates.count >= 2 else {
            return (nil, observed, debugBase + " rejected=single-line")
        }

        // Vertical contiguity: keep the largest contiguous run (sorted by top edge).
        let sorted = candidates.sorted { lines[$0].bbox.maxY > lines[$1].bbox.maxY }
        let run = Self.largestContiguousRun(of: sorted, in: lines)

        let selected = run.map { lines[$0] }
        let points = run.flatMap { linePoints[$0] }
        let result = Result(
            selectedLines: selected,
            samplePoints: Array(points.prefix(120)),
            highlightColor: highlight
        )
        return (result, observed, debugBase + " selected=\(selected.count)")
    }

    /// Background of the best-overlapping previous line (IoU ≥ 0.5), if any.
    static func bestOverlap(for bbox: CGRect, in previous: [(bbox: CGRect, bg: RGB)]) -> RGB? {
        var best: (iou: CGFloat, bg: RGB)?
        for prev in previous {
            let inter = bbox.intersection(prev.bbox)
            guard !inter.isNull, inter.width > 0 else { continue }
            let interArea = inter.width * inter.height
            let unionArea = bbox.width * bbox.height + prev.bbox.width * prev.bbox.height - interArea
            let iou = interArea / max(unionArea, .leastNonzeroMagnitude)
            if iou >= 0.5, iou > (best?.iou ?? 0) {
                best = (iou, prev.bg)
            }
        }
        return best?.bg
    }

    /// True if the stored sample points still show the stored highlight color
    /// (used to keep a pinned popup alive through OCR jitter).
    public func pointsStillHighlighted(
        _ points: [SamplePoint],
        color: RGB,
        in buffer: CVPixelBuffer
    ) -> Bool {
        guard !points.isEmpty, let reader = PixelReader(buffer) else { return false }
        let inBounds = points.filter { $0.x < reader.width && $0.y < reader.height }
        guard !inBounds.isEmpty else { return false }
        let median = Self.median(inBounds.map(reader.color(at:)))
        return median.distance(to: color) <= clusterTolerance
    }

    // MARK: - Sampling

    /// ~36 points per line: `samplesPerRow` x-positions × 3 mid-line rows.
    /// Mid-line rows sit inside even a tight highlight band (PDF selections
    /// hug the glyph box); the per-channel median rejects the glyph pixels
    /// these rows inevitably hit.
    func samplePoints(for bbox: CGRect, width: Int, height: Int) -> [SamplePoint] {
        // Vision bbox is normalized, bottom-left origin.
        let xMin = bbox.minX + bbox.width * 0.02
        let xSpan = bbox.width * 0.96
        let yTopNorm = 1 - bbox.maxY
        let rows = [0.25, 0.5, 0.75].map { yTopNorm + bbox.height * $0 }

        var points: [SamplePoint] = []
        points.reserveCapacity(samplesPerRow * 2)
        for rowNorm in rows {
            let y = min(height - 1, max(0, Int(rowNorm * CGFloat(height))))
            for i in 0..<samplesPerRow {
                let fx = xMin + xSpan * CGFloat(i) / CGFloat(max(1, samplesPerRow - 1))
                let x = min(width - 1, max(0, Int(fx * CGFloat(width))))
                points.append(SamplePoint(x: x, y: y))
            }
        }
        return points
    }

    // MARK: - Helpers

    static func median(_ colors: [RGB]) -> RGB {
        guard !colors.isEmpty else { return RGB(r: 0, g: 0, b: 0) }
        func mid(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        return RGB(
            r: mid(colors.map(\.r)),
            g: mid(colors.map(\.g)),
            b: mid(colors.map(\.b))
        )
    }

    static func largestContiguousRun(of sortedIndices: [Int], in lines: [OCRLine]) -> [Int] {
        guard sortedIndices.count > 1 else { return sortedIndices }
        let heights = sortedIndices.map { lines[$0].bbox.height }.sorted()
        let maxGap = heights[heights.count / 2] * 2.5

        var best: [Int] = []
        var current: [Int] = []
        for idx in sortedIndices {
            if let prev = current.last {
                let gap = lines[prev].bbox.minY - lines[idx].bbox.maxY
                if gap > maxGap {
                    if current.count > best.count { best = current }
                    current = []
                }
            }
            current.append(idx)
        }
        if current.count > best.count { best = current }
        return best
    }
}

/// Locked BGRA pixel access; the read-only base-address lock is held for the
/// reader's lifetime and released in deinit.
final class PixelReader {
    let width: Int
    let height: Int
    private let rowBytes: Int
    private let ptr: UnsafePointer<UInt8>
    private let buffer: CVPixelBuffer

    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return nil
        }
        self.buffer = buffer
        self.width = CVPixelBufferGetWidth(buffer)
        self.height = CVPixelBufferGetHeight(buffer)
        self.rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        self.ptr = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
    }

    deinit {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }

    func color(at point: SelectionClassifier.SamplePoint) -> SelectionClassifier.RGB {
        let p = point.y * rowBytes + point.x * 4
        return .init(r: Int(ptr[p + 2]), g: Int(ptr[p + 1]), b: Int(ptr[p]))
    }
}
