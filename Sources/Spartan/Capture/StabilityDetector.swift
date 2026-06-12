import Foundation
import CoreVideo
import CoreGraphics

/// Decides when window content has "settled" (user stopped scrolling/typing).
///
/// Every incoming frame is reduced to a 512-bit gradient hash computed from a
/// 17×17 luminance grid sampled directly out of the BGRA buffer (~1,150 pixel
/// reads — no full-frame decode, which at 10fps on a 5K window was the single
/// biggest constant CPU cost). Hamming distance > 12 vs. the previous frame
/// counts as change. Grid resolution matters: at 9×8, scrolling a page of
/// prose barely moved the hash. Vertical gradients track text-line positions.
///
/// Two-stage settle for latency:
///   • preSettle (250ms stable) — caller can start OCR speculatively
///   • settle    (500ms stable) — caller renders / queries detection
/// SCStream only delivers frames when content changes, so silence also counts
/// as stability. Runs entirely on the capture queue.
final class StabilityDetector: @unchecked Sendable {
    /// Called on the capture queue the moment content changes.
    var onUnsettled: (() -> Void)?
    /// Called on the capture queue after `preSettleInterval` of stability.
    var onPreSettled: ((CVPixelBuffer, [UInt64]) -> Void)?
    /// Called on the capture queue with the frame to scan once content settles.
    var onSettled: ((CVPixelBuffer, [UInt64]) -> Void)?

    private let queue: DispatchQueue
    private let preSettleInterval: TimeInterval
    private let settleInterval: TimeInterval
    private let hammingThreshold = 12  // of 512 bits (~2.3%); cursor blink stays below

    private var timer: DispatchSourceTimer?
    private var lastHash: [UInt64]?
    private var lastChange = Date.distantPast
    private var latestBuffer: CVPixelBuffer?
    private var lastPreHash: [UInt64]?
    private var lastScannedHash: [UInt64]?
    private var wasStable = true

    init(
        queue: DispatchQueue,
        preSettleInterval: TimeInterval = 0.25,
        settleInterval: TimeInterval = 0.5
    ) {
        self.queue = queue
        self.preSettleInterval = preSettleInterval
        self.settleInterval = settleInterval
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Clears all frame state (e.g., after a window switch). Timer keeps running.
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastHash = nil
            self.latestBuffer = nil
            self.lastPreHash = nil
            self.lastScannedHash = nil
            self.lastChange = Date()  // fresh window: wait a full settle interval
            self.wasStable = true
        }
    }

    /// Must be called on the capture queue.
    func ingest(_ buffer: CVPixelBuffer) {
        latestBuffer = buffer
        guard let hash = Self.frameHash(of: buffer) else { return }
        defer { lastHash = hash }
        guard let previous = lastHash else {
            lastChange = Date()
            wasStable = false
            return
        }
        if Self.hamming(previous, hash) > hammingThreshold {
            lastChange = Date()
            if wasStable {
                wasStable = false
                onUnsettled?()
            }
        }
    }

    private func tick() {
        guard let buffer = latestBuffer, let hash = lastHash else { return }
        let stableFor = Date().timeIntervalSince(lastChange)
        guard stableFor >= preSettleInterval else { return }

        // Sub-threshold drift (cursor blink, one new log line) must not
        // re-trigger work every tick — require a real change since last time.
        if lastPreHash.map({ Self.hamming($0, hash) > hammingThreshold }) ?? true {
            lastPreHash = hash
            onPreSettled?(buffer, hash)
        }
        guard stableFor >= settleInterval else { return }
        if lastScannedHash.map({ Self.hamming($0, hash) > hammingThreshold }) ?? true {
            lastScannedHash = hash
            wasStable = true
            onSettled?(buffer, hash)
        }
    }

    // MARK: - Gradient hash

    private static let grid = 17  // 16×16 H-gradients + 16×16 V-gradients = 512 bits

    /// 17×17 luminance grid via strided sampling (4 points per cell), then
    /// horizontal+vertical comparison bits. Requires the BGRA format the
    /// capture stream is configured for.
    static func frameHash(of pixelBuffer: CVPixelBuffer) -> [UInt64]? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let n = grid
        guard width >= n * 2, height >= n * 2 else { return nil }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var cells = [Int](repeating: 0, count: n * n)
        let fractions = [0.25, 0.75]
        for gy in 0..<n {
            for gx in 0..<n {
                var sum = 0
                for fy in fractions {
                    let y = Int((Double(gy) + fy) / Double(n) * Double(height))
                    for fx in fractions {
                        let x = Int((Double(gx) + fx) / Double(n) * Double(width))
                        let p = y * rowBytes + x * 4
                        let b = Int(ptr[p]), g = Int(ptr[p + 1]), r = Int(ptr[p + 2])
                        sum += (r + g + g + b) >> 2
                    }
                }
                cells[gy * n + gx] = sum >> 2
            }
        }

        var words = [UInt64](repeating: 0, count: 8)
        var bit = 0
        func push(_ on: Bool) {
            if on { words[bit >> 6] |= 1 << UInt64(bit & 63) }
            bit += 1
        }
        for row in 0..<(n - 1) {
            for col in 0..<(n - 1) {
                push(cells[row * n + col] > cells[row * n + col + 1])      // horizontal
                push(cells[row * n + col] > cells[(row + 1) * n + col])    // vertical
            }
        }
        return words
    }

    static func hamming(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var d = 0
        for i in 0..<min(a.count, b.count) {
            d += (a[i] ^ b[i]).nonzeroBitCount
        }
        return d
    }
}
