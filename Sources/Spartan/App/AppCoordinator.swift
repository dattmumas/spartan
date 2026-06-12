import AppKit
import CoreVideo
import os.log
import SpartanCore

let logger = Logger(subsystem: "com.mdumas.spartan", category: "pipeline")

extension String {
    func appendToFile(at url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(utf8))
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Wires tracker → capture → stability → OCR → chunker → cache/Pangram → overlay.
///
/// A generation counter guards against staleness: any content change or window
/// switch bumps it, and in-flight scan results from older generations are not
/// rendered (their paid API responses still go into the cache).
@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    let state = AppState()

    private let tracker = ActiveWindowTracker()
    private let capture = CaptureEngine()
    private let stability: StabilityDetector
    private let recognizer = TextRecognizer()
    private let chunker = TextChunker()
    let cache = PassageCache(
        persistURL: SpartanPaths.dir().appendingPathComponent("cache.json")
    )
    let detector: PangramClient
    private lazy var overlay = OverlayWindowController(state: state)

    private var tracked: TrackedWindow?
    private var generation = 0
    private var currentRegions: [RenderableRegion] = []
    private var restartToken = 0
    private var started = false
    private var scanInFlight = false
    /// OCR started at preSettle (250ms of stillness) so results are ready when
    /// the 500ms settle confirms — hides OCR latency behind the debounce.
    private var speculation: (hash: [UInt64], gen: Int, task: Task<[OCRLine]?, Never>)?
    private var settledAt = Date()
    /// Per-line background observations from the previous selection-mode scan.
    /// "Same line, changed background" = a selection appeared.
    private var selectionHistory: SelectionClassifier.History?
    /// The currently pinned selection verdict (selection mode).
    private var pinnedSelection: (hash: String, points: [SelectionClassifier.SamplePoint],
                                  color: SelectionClassifier.RGB)?
    /// True while the pinned selection came from the Accessibility monitor;
    /// the visual classifier stands down until AX reports the selection gone.
    private var axPinned = false
    private let axMonitor = AXSelectionMonitor()
    private var cacheFlushTimer: Timer?

    private let perSettleBudget = 8

    private init() {
        stability = StabilityDetector(queue: capture.captureQueue)
        detector = PangramClient(apiKeyProvider: { KeychainStore.apiKey() })
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        state.hasScreenPermission = CGPreflightScreenCaptureAccess()
        logger.info("startup: screenPermission=\(self.state.hasScreenPermission) apiKey=\(self.state.apiKeyPresent)")
        guard state.hasScreenPermission else {
            state.statusText = "Screen Recording permission needed"
            return
        }
        beginWatching()
    }

    func requestScreenPermission() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )!)
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func beginWatching() {
        state.statusText = "Watching"

        tracker.onWindowChanged = { [weak self] window in
            self?.handleWindowChanged(window, debounce: .zero)
        }
        tracker.onWindowResized = { [weak self] window in
            // Content reflows on resize: clear and restart capture (stream size
            // is fixed). Debounced — live-resize fires this every poll tick.
            self?.handleWindowChanged(window, debounce: .milliseconds(350))
        }
        tracker.onWindowMoved = { [weak self] window in
            guard let self else { return }
            self.tracked = window
            self.overlay.show(overCGFrame: window.frame)
        }

        stability.onUnsettled = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.generation += 1
                self.currentRegions = []
                self.overlay.clear()
            }
        }
        stability.onPreSettled = { [weak self] buffer, hash in
            Task { @MainActor in
                self?.speculate(buffer, hash: hash)
            }
        }
        stability.onSettled = { [weak self] buffer, hash in
            Task { @MainActor in
                self?.scan(buffer, hash: hash)
            }
        }
        capture.onStreamError = { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.tracked else { return }
                self.handleWindowChanged(window, debounce: .zero)
            }
        }

        axMonitor.pidProvider = { [weak self] in self?.tracked?.ownerPID }
        axMonitor.onSelection = { [weak self] text, bounds in
            self?.handleAXSelection(text: text, bounds: bounds)
        }
        axMonitor.onCleared = { [weak self] in
            guard let self, self.axPinned else { return }
            self.axPinned = false
            self.pinnedSelection = nil
            self.overlay.setSelection(nil)
        }
        updateAXMonitor()

        stability.start()
        tracker.start()
        startCacheFlush()
    }

    private func startCacheFlush() {
        guard cacheFlushTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.cache.saveIfDirty() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cacheFlushTimer = timer
    }

    func setPaused(_ paused: Bool) {
        state.paused = paused
        if paused {
            state.statusText = "Paused"
            generation += 1
            overlay.hide()
            Task { await capture.stop() }
        } else {
            state.statusText = "Watching"
            if let window = tracked {
                handleWindowChanged(window, debounce: .zero)
            }
        }
    }

    // MARK: - Window switching

    func setScanMode(_ mode: ScanMode) {
        guard state.scanMode != mode else { return }
        state.scanMode = mode
        generation += 1
        currentRegions = []
        pinnedSelection = nil
        axPinned = false
        overlay.clear()
        overlay.setSelection(nil)
        updateAXMonitor()
    }

    func requestAccessibility() {
        AXSelectionMonitor.promptForTrust()
    }

    private func updateAXMonitor() {
        if state.scanMode == .selection, started, state.hasScreenPermission {
            state.axTrusted = AXSelectionMonitor.isTrusted
            axMonitor.start()
        } else {
            axMonitor.stop()
        }
    }

    private func handleAXSelection(text: String, bounds: CGRect?) {
        guard state.scanMode == .selection, !state.paused, let window = tracked else { return }
        state.axTrusted = true
        settledAt = Date()
        // AX bounds are global CG top-left; the overlay draws window-local.
        let local = bounds.map {
            CGRect(x: $0.minX - window.frame.minX, y: $0.minY - window.frame.minY,
                   width: $0.width, height: $0.height)
        } ?? CGRect(x: window.frame.width / 2 - 120, y: window.frame.height - 80,
                    width: 240, height: 10)
        axPinned = true
        logger.info("ax selection: \(text.split(whereSeparator: \.isWhitespace).count, privacy: .public) words bounds=\(bounds != nil, privacy: .public)")
        overlay.show(overCGFrame: window.frame)
        scoreSelection(
            text: text, anchor: local, lineRects: bounds != nil ? [local] : [],
            pinPoints: [], pinColor: .init(r: 0, g: 0, b: 0), fromAX: true
        )
    }

    func reapplyExclusions() {
        handleWindowChanged(tracked, debounce: .zero)
    }

    private func handleWindowChanged(_ window: TrackedWindow?, debounce: Duration) {
        var window = window
        if let w = window, let id = w.bundleID {
            state.currentApp = CurrentApp(name: w.appName, bundleID: id)
        } else {
            state.currentApp = nil
        }
        if let id = window?.bundleID, state.excludedBundleIDs.contains(id) {
            state.statusText = "Excluded: \(window!.appName)"
            logger.info("excluded app: \(id, privacy: .public)")
            window = nil
        }

        tracked = window
        generation += 1
        currentRegions = []
        speculation = nil
        selectionHistory = nil
        pinnedSelection = nil
        axPinned = false
        axMonitor.reset()
        overlay.hide()
        stability.reset()

        restartToken += 1
        let token = restartToken
        guard let window, !state.paused, state.hasScreenPermission else {
            Task { await capture.stop() }
            return
        }

        Task {
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard token == restartToken else { return }
            await capture.stop()
            guard token == restartToken else { return }
            do {
                let queue = capture.captureQueue
                capture.onFrame = { [stability] buffer in
                    queue.async { stability.ingest(buffer) }
                }
                try await capture.start(windowID: window.windowID)
                state.statusText = "Watching \(window.appName)"
                logger.info("capture started: \(window.appName) window=\(window.windowID)")
            } catch {
                state.statusText = "Capture failed: \(window.appName)"
                logger.error("capture failed: \(window.appName) — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Scan pipeline

    private func speculate(_ buffer: CVPixelBuffer, hash: [UInt64]) {
        guard tracked != nil, !state.paused else { return }
        if let s = speculation, s.gen == generation,
           StabilityDetector.hamming(s.hash, hash) == 0 {
            return
        }
        let recognizer = self.recognizer
        speculation = (hash, generation, Task(priority: .userInitiated) {
            try? await recognizer.recognize(buffer)
        })
    }

    private func scan(_ buffer: CVPixelBuffer, hash: [UInt64]) {
        guard let window = tracked, !state.paused, !scanInFlight else { return }
        scanInFlight = true
        let gen = generation
        let windowSize = window.frame.size
        let windowFrame = window.frame
        settledAt = Date()
        state.statusText = "Scanning \(window.appName)…"

        Task {
            defer { scanInFlight = false }
            var lines: [OCRLine]?
            var ocrSource = "fresh"
            if let s = speculation, s.gen == gen,
               StabilityDetector.hamming(s.hash, hash) <= 12 {
                lines = await s.task.value
                ocrSource = "speculative"
            }
            if lines == nil {
                lines = try? await recognizer.recognize(buffer)
                ocrSource = "fresh"
            }
            guard let lines else {
                state.statusText = "OCR failed"
                return
            }
            let ocrWaitMs = Int(Date().timeIntervalSince(settledAt) * 1000)
            logger.info("ocr ready in \(ocrWaitMs, privacy: .public)ms (\(ocrSource, privacy: .public))")
            guard gen == generation else { return }

            if state.scanMode == .selection {
                selectionScan(lines: lines, buffer: buffer,
                              windowSize: windowSize, windowFrame: windowFrame)
                state.statusText = "Selection mode — \(window.appName)"
                return
            }

            let passages = chunker.passages(from: lines)
            logger.info("settled scan: \(lines.count) lines → \(passages.count) passages in \(window.appName, privacy: .public)")
            Self.debugDump(lines: lines, passages: passages, app: window.appName)
            guard !passages.isEmpty else {
                state.statusText = "Watching \(window.appName) — no text"
                return
            }

            var misses: [Passage] = []
            for passage in passages {
                switch await cache.lookup(passage) {
                case .exact(let result):
                    addRegion(for: passage, result: result, windowSize: windowSize,
                              gen: gen, source: "cache")
                case .fuzzy(let result):
                    addRegion(for: passage, result: result, windowSize: windowSize,
                              gen: gen, source: "fuzzy")
                case .miss:
                    misses.append(passage)
                }
            }
            if gen == generation {
                overlay.show(overCGFrame: windowFrame)
            }

            // Longest passages first: most reliable and most informative.
            let toQuery = misses.sorted { $0.wordCount > $1.wordCount }.prefix(perSettleBudget)
            let skipped = misses.count - toQuery.count
            if skipped > 0 {
                state.addLog(ScanLogEntry(
                    preview: "\(skipped) passage(s) deferred (per-scan budget)",
                    words: 0, score: nil, source: "info"
                ))
            }

            for passage in toQuery {
                if state.requestsToday >= state.dailyCap {
                    state.lastError = "Daily budget (\(state.dailyCap)) reached — paused"
                    setPaused(true)
                    return
                }
                state.requestsToday += 1
                query(passage, windowSize: windowSize, gen: gen)
            }
            if gen == generation {
                state.statusText = "Watching \(window.appName)"
            }
        }
    }

    private func query(_ passage: Passage, windowSize: CGSize, gen: Int) {
        Task {
            do {
                let result = try await detector.detect(passage.text)
                await cache.store(result, for: passage)
                addRegion(for: passage, result: result, windowSize: windowSize,
                          gen: gen, source: "api")
            } catch let error as DetectorError {
                logger.error("pangram error: \(error.description)")
                state.lastError = error.description
                state.addLog(ScanLogEntry(
                    preview: error.description, words: passage.wordCount,
                    score: nil, source: "error"
                ))
                switch error {
                case .invalidAPIKey, .outOfCredits, .missingAPIKey:
                    setPaused(true)
                default:
                    break
                }
            } catch {
                state.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Selection mode

    private static func accentColors() -> [SelectionClassifier.RGB] {
        [NSColor.selectedTextBackgroundColor, NSColor.controlAccentColor].compactMap {
            guard let c = $0.usingColorSpace(.sRGB) else { return nil }
            return SelectionClassifier.RGB(
                r: Int(c.redComponent * 255),
                g: Int(c.greenComponent * 255),
                b: Int(c.blueComponent * 255)
            )
        }
    }

    private func selectionScan(
        lines: [OCRLine],
        buffer: CVPixelBuffer,
        windowSize: CGSize,
        windowFrame: CGRect
    ) {
        let classifier = SelectionClassifier(accentColors: Self.accentColors())
        let (result, observed, debug) = classifier.classify(
            lines: lines, buffer: buffer, history: selectionHistory
        )
        logger.info("selection classify: \(debug, privacy: .public)")
        // Merge hash history so brief OCR dropouts don't erase a line; the
        // positional list is always the latest frame only.
        var merged = observed
        if var byHash = selectionHistory?.byHash {
            byHash.merge(observed.byHash) { _, new in new }
            if byHash.count > 3000 { byHash = observed.byHash }
            merged.byHash = byHash
        }
        selectionHistory = merged

        guard let result, !result.selectedLines.isEmpty else {
            // No selection found. OCR jitter can drop lines for one frame —
            // keep the pinned popup if its highlight is still on screen.
            if let pinned = pinnedSelection,
               classifier.pointsStillHighlighted(pinned.points, color: pinned.color, in: buffer) {
                return
            }
            pinnedSelection = nil
            overlay.setSelection(nil)
            return
        }

        // The AX monitor owns the pinned selection while it has one — the
        // visual path only fills in for apps that don't expose AX selections.
        guard !axPinned else { return }

        let ordered = result.selectedLines.sorted { $0.bbox.maxY > $1.bbox.maxY }
        let text = TextChunker.joinLines(ordered)
        let rects = ordered.map {
            GeometryMapping.windowRect(fromNormalized: $0.bbox, windowSize: windowSize, inflateBy: 2)
        }
        logger.info("selection (visual): \(ordered.count, privacy: .public) lines")
        overlay.show(overCGFrame: windowFrame)
        scoreSelection(
            text: text, anchor: GeometryMapping.union(of: rects), lineRects: rects,
            pinPoints: result.samplePoints, pinColor: result.highlightColor, fromAX: false
        )
    }

    /// Shared scoring + popup path for both AX and visual selection capture.
    private func scoreSelection(
        text: String,
        anchor: CGRect,
        lineRects: [CGRect],
        pinPoints: [SelectionClassifier.SamplePoint],
        pinColor: SelectionClassifier.RGB,
        fromAX: Bool
    ) {
        let hash = TextNormalizer.hash(text)
        let words = text.split(whereSeparator: \.isWhitespace).count
        if pinnedSelection?.hash == hash { return }  // same selection, popup stays
        pinnedSelection = (hash, pinPoints, pinColor)

        guard words >= 15 else {
            // Visual detections below the floor stay silent (they're often UI
            // noise, not deliberate selections). AX selections of a few words
            // get the explanatory popup; 1–2 words (a double-clicked word) stay
            // silent too.
            if fromAX, words >= 3 {
                overlay.setSelection(SelectionVerdict(phase: .tooShort, anchor: anchor, lineRects: lineRects))
            } else {
                overlay.setSelection(nil)
            }
            return
        }
        overlay.setSelection(SelectionVerdict(phase: .checking, anchor: anchor, lineRects: lineRects))

        let passage = Passage(text: text, lines: [], lowConfidence: words < 75)
        Task {
            var detection: DetectionResult?
            var errorText: String?
            switch await cache.lookup(passage) {
            case .exact(let r), .fuzzy(let r):
                detection = r
            case .miss:
                if state.requestsToday >= state.dailyCap {
                    errorText = "Daily budget (\(state.dailyCap)) reached"
                } else {
                    state.requestsToday += 1
                    do {
                        let r = try await detector.detect(text)
                        await cache.store(r, for: passage)
                        detection = r
                    } catch let error as DetectorError {
                        errorText = error.description
                        state.lastError = error.description
                        switch error {
                        case .invalidAPIKey, .outOfCredits, .missingAPIKey:
                            setPaused(true)
                        default: break
                        }
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
            guard pinnedSelection?.hash == hash else { return }  // superseded
            if let detection {
                let latencyMs = Int(Date().timeIntervalSince(settledAt) * 1000)
                logger.info("selection score=\(String(format: "%.4f", detection.aiLikelihood), privacy: .public) words=\(words, privacy: .public) +\(latencyMs, privacy: .public)ms")
                state.addLog(ScanLogEntry(
                    preview: String(text.prefix(60)), words: words,
                    score: detection.aiLikelihood, source: "select"
                ))
                overlay.setSelection(SelectionVerdict(
                    phase: .scored(
                        likelihood: detection.aiLikelihood,
                        headline: detection.prediction,
                        lowConfidence: words < 40
                    ),
                    anchor: anchor, lineRects: lineRects
                ))
            } else {
                overlay.setSelection(SelectionVerdict(
                    phase: .error(errorText ?? "Detection failed"),
                    anchor: anchor, lineRects: lineRects
                ))
            }
        }
    }

    // Diagnostics: dump what OCR saw and what was sent for scoring to
    // /tmp/spartan-scan-debug.txt. Captures everything on screen — leave off.
    static let debugDumpEnabled = false
    private static let debugDumpURL = URL(fileURLWithPath: "/tmp/spartan-scan-debug.txt")

    nonisolated static func debugDump(lines: [OCRLine], passages: [Passage], app: String) {
        guard debugDumpEnabled else { return }
        var out = "===== scan \(Date()) app=\(app) =====\n"
        out += "--- OCR lines (\(lines.count)) ---\n"
        for l in lines {
            out += String(format: "[conf %.2f, %d w, y %.3f] %@\n",
                          l.confidence, l.wordCount, l.bbox.minY, l.text)
        }
        out += "--- passages (\(passages.count)) ---\n"
        for (i, p) in passages.enumerated() {
            out += "[\(i)] \(p.wordCount) words lowConf=\(p.lowConfidence)\n\(p.text)\n\n"
        }
        try? out.appendToFile(at: debugDumpURL)
    }

    nonisolated static func debugDumpScore(_ score: Double, source: String, passageHash: String) {
        guard debugDumpEnabled else { return }
        try? "score=\(score) source=\(source) passage=\(passageHash.prefix(12))\n"
            .appendToFile(at: debugDumpURL)
    }

    private func addRegion(
        for passage: Passage,
        result: DetectionResult,
        windowSize: CGSize,
        gen: Int,
        source: String
    ) {
        let latencyMs = Int(Date().timeIntervalSince(settledAt) * 1000)
        logger.info("score=\(String(format: "%.4f", result.aiLikelihood), privacy: .public) source=\(source, privacy: .public) words=\(passage.wordCount) +\(latencyMs, privacy: .public)ms \"\(String(passage.text.prefix(40)))…\"")
        Self.debugDumpScore(result.aiLikelihood, source: source, passageHash: passage.hash)
        state.addLog(ScanLogEntry(
            preview: String(passage.text.prefix(60)),
            words: passage.wordCount,
            score: result.aiLikelihood,
            source: source
        ))
        guard gen == generation else { return }

        let rects = passage.lines.map {
            GeometryMapping.windowRect(
                fromNormalized: $0.bbox, windowSize: windowSize, inflateBy: 2
            )
        }
        let scores = WindowMapping.perLineScores(
            lineRanges: passage.lineRanges,
            windows: result.windows,
            fallback: result.aiLikelihood
        )
        currentRegions.append(RenderableRegion(
            lineRects: rects,
            lineScores: scores.isEmpty
                ? Array(repeating: result.aiLikelihood, count: rects.count)
                : scores,
            likelihood: result.aiLikelihood,
            headline: result.prediction,
            lowConfidence: passage.lowConfidence
        ))
        overlay.setRegions(currentRegions)
    }
}
