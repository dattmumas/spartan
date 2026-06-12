import Foundation

/// LRU cache of detection results, keyed by normalized-passage SHA-256.
///
/// Also keeps a line-hash → passage-hash index for fuzzy reuse: a new passage
/// whose lines are ≥80% covered by already-scored lines inherits the dominant
/// prior passage's score instead of triggering a new (paid) API call.
/// This is what prevents "scroll three lines → re-bill the whole page".
///
/// If a `persistURL` is supplied the cache loads from disk on init and writes
/// back on demand via `saveIfDirty()` — the caller is expected to call that on
/// a timer (Spartan: every 60s). Up to one timer-interval of new scores can be
/// lost on a crash; acceptable since every Pangram call is also de-duplicated
/// for the current process via the in-memory cache.
public actor PassageCache {
    public enum Lookup: Sendable {
        case exact(DetectionResult)
        case fuzzy(DetectionResult)
        case miss
    }

    private struct Snapshot: Codable {
        var results: [String: DetectionResult]
        var order: [String]
        var lineIndex: [String: String]
    }

    private var results: [String: DetectionResult] = [:]
    private var order: [String] = []
    private var lineIndex: [String: String] = [:]  // line hash → passage hash
    private let capacity: Int
    private let fuzzyCoverage: Double
    private let persistURL: URL?
    private var dirty = false

    public init(
        capacity: Int = 2000,
        fuzzyCoverage: Double = 0.8,
        persistURL: URL? = nil
    ) {
        self.capacity = capacity
        self.fuzzyCoverage = fuzzyCoverage
        self.persistURL = persistURL
        if let persistURL,
           let data = try? Data(contentsOf: persistURL),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            results = snap.results
            order = snap.order
            lineIndex = snap.lineIndex
            // The snapshot may have been written before the configured
            // capacity shrank; trim now without going through the
            // isolated-method path (init isn't isolated-as-self).
            while results.count > capacity, let oldest = order.first {
                order.removeFirst()
                results.removeValue(forKey: oldest)
                lineIndex = lineIndex.filter { $0.value != oldest }
            }
        }
    }

    public func lookup(_ passage: Passage) -> Lookup {
        if let exact = results[passage.hash] {
            touch(passage.hash)
            return .exact(exact)
        }
        guard !passage.lineHashes.isEmpty else { return .miss }

        var votes: [String: Int] = [:]
        var covered = 0
        for lh in passage.lineHashes {
            if let owner = lineIndex[lh], results[owner] != nil {
                covered += 1
                votes[owner, default: 0] += 1
            }
        }
        let coverage = Double(covered) / Double(passage.lineHashes.count)
        if coverage >= fuzzyCoverage,
           let dominant = votes.max(by: { $0.value < $1.value })?.key,
           let result = results[dominant] {
            touch(dominant)
            return .fuzzy(result)
        }
        return .miss
    }

    public func store(_ result: DetectionResult, for passage: Passage) {
        if results[passage.hash] == nil {
            order.append(passage.hash)
        }
        results[passage.hash] = result
        touch(passage.hash)
        for lh in passage.lineHashes {
            lineIndex[lh] = passage.hash
        }
        evictIfNeeded()
        dirty = true
    }

    public var count: Int { results.count }

    public func saveIfDirty() {
        guard dirty, let persistURL else { return }
        let snap = Snapshot(results: results, order: order, lineIndex: lineIndex)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: persistURL, options: .atomic)
        dirty = false
    }

    private func touch(_ hash: String) {
        if let idx = order.firstIndex(of: hash) {
            order.remove(at: idx)
            order.append(hash)
        }
    }

    private func evictIfNeeded() {
        while results.count > capacity, let oldest = order.first {
            order.removeFirst()
            results.removeValue(forKey: oldest)
            lineIndex = lineIndex.filter { $0.value != oldest }
        }
    }
}
