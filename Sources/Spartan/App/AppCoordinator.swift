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
    private let cache = PassageCache(
        persistURL: SpartanPaths.dir().appendingPathComponent("cache.json")
    )
    private let detector: PangramClient
    private let verdicts = VerdictStore(directory: SpartanPaths.dir("History"))
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
    private let hotKey = HotKeyManager()
    private var cacheFlushTimer: Timer?
    private var transientMessageToken = 0

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

        HotKeyManager.trigger = { [weak self] in self?.hotkeyScore() }
        hotKey.register()

        stability.start()
        tracker.start()
        startCacheFlush()
        let retention = state.retentionDays
        Task { await verdicts.purge(olderThanDays: retention) }
    }

    // History passthroughs (verdicts must stay an actor, but the History UI
    // doesn't need to know that or share state).
    func verdictsRecent(limit: Int) async -> [VerdictRecord] {
        await verdicts.recent(limit: limit)
    }
    nonisolated func verdictsCSV(_ records: [VerdictRecord]) -> String {
        verdicts.csv(records: records)
    }
    func verdictsDirectory() -> URL { SpartanPaths.dir("History") }
    func verdictScreenshotURL(_ record: VerdictRecord) async -> URL? {
        await verdicts.url(forScreenshot: record)
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

    func hotkeyScore() {
        guard let window = tracked else { return }
        guard AXSelectionMonitor.isTrusted,
              let sel = AXSelectionMonitor.currentSelection(pid: window.ownerPID),
              !sel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            let message = AXSelectionMonitor.isTrusted
                ? "⌘⇧A: nothing selected"
                : "⌘⇧A needs Accessibility — grant it from the popover"
            transientMessage(message, over: window)
            return
        }
        handleAXSelection(text: sel.text, bounds: sel.bounds, force: true)

        // Outside selection mode the AX monitor is stopped, so its onCleared
        // (the normal popup-clearing path) never fires — without this timeout
        // a hotkey verdict would stay pinned until the next window switch.
        if state.scanMode != .selection {
            let hash = TextNormalizer.hash(sel.text)
            Task {
                try? await Task.sleep(for: .seconds(12))
                guard pinnedSelection?.hash == hash else { return }
                axPinned = false
                pinnedSelection = nil
                overlay.setSelection(nil)
            }
        }
    }

    private func transientMessage(_ message: String, over window: TrackedWindow) {
        overlay.show(overCGFrame: window.frame)
        let anchor = CGRect(
            x: window.frame.width / 2 - 140, y: 24,
            width: 280, height: 10
        )
        overlay.setSelection(SelectionVerdict(
            phase: .error(message), anchor: anchor, lineRects: []
        ))
        transientMessageToken &+= 1
        let token = transientMessageToken
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard token == transientMessageToken,
                  case .error(let current) = overlay.model.selection?.phase,
                  current == message
            else { return }
            overlay.setSelection(nil)
        }
    }

    private func handleAXSelection(text: String, bounds: CGRect?, force: Bool = false) {
        guard force || state.scanMode == .selection,
              !state.paused, let window = tracked else { return }
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
        }
        // window == nil usually means Spartan itself became frontmost (the
        // popover is opening) — keep the last real app so the "Exclude X"
        // button still refers to the app the user was just in.
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

            let appName = window.appName
            var misses: [Passage] = []
            for passage in passages {
                switch await cache.lookup(passage) {
                case .exact(let result):
                    addRegion(for: passage, result: result, windowSize: windowSize,
                              gen: gen, source: "cache")
                    recordHit(passage, appName: appName)
                case .fuzzy(let result):
                    addRegion(for: passage, result: result, windowSize: windowSize,
                              gen: gen, source: "fuzzy")
                    recordHit(passage, appName: appName)
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

            // One full-frame decode serves every passage's screenshot crop;
            // both run off the main actor.
            let frameImage = toQuery.isEmpty ? nil : await FrameCropper.image(from: buffer)
            for passage in toQuery {
                let bbox = GeometryMapping.union(of: passage.lines.map(\.bbox))
                Task {
                    let shot = await FrameCropper.png(
                        from: frameImage, normalizedRect: bbox
                    )
                    let outcome = await self.obtainScore(
                        for: passage, appName: appName,
                        recordSource: "continuous", screenshot: shot
                    )
                    switch outcome {
                    case .scored(let result, let source):
                        self.addRegion(for: passage, result: result,
                                       windowSize: windowSize, gen: gen, source: source)
                    case .budgetExhausted:
                        self.state.lastError = "Daily budget (\(self.state.dailyCap)) reached — paused"
                        self.setPaused(true)
                    case .failed(let message):
                        self.state.addLog(ScanLogEntry(
                            preview: message, words: passage.wordCount,
                            score: nil, source: "error"
                        ))
                    }
                }
            }
            if gen == generation {
                state.statusText = "Watching \(window.appName)"
            }
        }
    }

    /// Hits already have a result; route through obtainScore anyway so the
    /// history record comes from the single recording path (it re-resolves
    /// from cache instantly and the store dedupes per day).
    private func recordHit(_ passage: Passage, appName: String) {
        Task {
            _ = await self.obtainScore(
                for: passage, appName: appName, recordSource: "continuous"
            )
        }
    }

    // MARK: - Shared scoring service

    enum ScoreOutcome {
        case scored(DetectionResult, source: String)  // "cache" | "fuzzy" | "api"
        case budgetExhausted
        case failed(String)
    }

    /// The ONE path from passage to score: cache lookup → budget check →
    /// Pangram call → cache store → history record → credential-error pausing.
    /// Continuous, selection, hotkey, and document scoring all go through
    /// here so billing policy can never diverge between them. Cache hits are
    /// recorded to history too (the store dedupes per passage per day) so the
    /// "everything highlighted is in History" invariant holds across launches.
    func obtainScore(
        for passage: Passage,
        appName: String,
        recordSource: String,
        screenshot: Data? = nil
    ) async -> ScoreOutcome {
        func record(_ result: DetectionResult, shot: Data?) async {
            let record = VerdictRecord(
                appName: appName, source: recordSource,
                passageHash: passage.hash, text: passage.text,
                words: passage.wordCount, score: result.aiLikelihood,
                headline: result.prediction, lowConfidence: passage.lowConfidence
            )
            await verdicts.append(record, screenshot: shot)
        }

        switch await cache.lookup(passage) {
        case .exact(let result):
            await record(result, shot: nil)
            return .scored(result, source: "cache")
        case .fuzzy(let result):
            await record(result, shot: nil)
            return .scored(result, source: "fuzzy")
        case .miss:
            break
        }

        guard state.requestsToday < state.dailyCap else { return .budgetExhausted }
        state.requestsToday += 1
        do {
            let result = try await detector.detect(passage.text)
            await cache.store(result, for: passage)
            await record(result, shot: screenshot)
            return .scored(result, source: "api")
        } catch let error as DetectorError {
            logger.error("pangram error: \(error.description)")
            state.lastError = error.description
            switch error {
            case .invalidAPIKey, .outOfCredits, .missingAPIKey:
                setPaused(true)
            default:
                break
            }
            return .failed(error.description)
        } catch {
            state.lastError = error.localizedDescription
            return .failed(error.localizedDescription)
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
        let appName = tracked?.appName ?? "?"
        Task {
            let outcome = await obtainScore(
                for: passage, appName: appName, recordSource: "selection"
            )
            guard pinnedSelection?.hash == hash else { return }  // superseded
            switch outcome {
            case .scored(let detection, _):
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
            case .budgetExhausted:
                overlay.setSelection(SelectionVerdict(
                    phase: .error("Daily budget (\(state.dailyCap)) reached"),
                    anchor: anchor, lineRects: lineRects
                ))
            case .failed(let message):
                overlay.setSelection(SelectionVerdict(
                    phase: .error(message),
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
        // Fuzzy hits reuse a DIFFERENT passage's result: its window offsets
        // index into the original text, not this one — mapping them here would
        // tint the wrong lines. Fall back to passage-level scoring.
        let usableWindows = source == "fuzzy" ? [] : result.windows
        let scores = WindowMapping.perLineScores(
            lineRanges: passage.lineRanges,
            windows: usableWindows,
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
