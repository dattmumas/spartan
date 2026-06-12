import Foundation

/// LRU cache of detection results, keyed by normalized-passage SHA-256.
///
/// Also keeps a line-hash → passage-hash index for fuzzy reuse: a new passage
/// whose lines are ≥80% covered by already-scored lines inherits the dominant
/// prior passage's score instead of triggering a new (paid) API call.
/// This is what prevents "scroll three lines → re-bill the whole page".
public actor PassageCache {
    public enum Lookup: Sendable {
        case exact(DetectionResult)
        case fuzzy(DetectionResult)
        case miss
    }

    private var results: [String: DetectionResult] = [:]
    private var order: [String] = []
    private var lineIndex: [String: String] = [:]  // line hash → passage hash
    private let capacity: Int
    private let fuzzyCoverage: Double

    public init(capacity: Int = 2000, fuzzyCoverage: Double = 0.8) {
        self.capacity = capacity
        self.fuzzyCoverage = fuzzyCoverage
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
    }

    public var count: Int { results.count }

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
