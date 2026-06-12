import Foundation

public enum WindowMapping {
    /// Per-line score = max `aiAssistanceScore` of any window overlapping the
    /// line's range; lines with no overlapping window inherit `fallback` (the
    /// passage-level `aiLikelihood`), which is the safe default — we report
    /// what the whole passage looked like to the model rather than implying
    /// the line was scored clean.
    public static func perLineScores(
        lineRanges: [Range<Int>],
        windows: [DetectionWindow],
        fallback: Double
    ) -> [Double] {
        guard !windows.isEmpty else {
            return Array(repeating: fallback, count: lineRanges.count)
        }
        var scores: [Double] = []
        scores.reserveCapacity(lineRanges.count)
        for range in lineRanges {
            var best: Double?
            for window in windows {
                if window.startIndex < range.upperBound,
                   window.endIndex > range.lowerBound {
                    if best == nil || window.aiAssistanceScore > best! {
                        best = window.aiAssistanceScore
                    }
                }
            }
            scores.append(best ?? fallback)
        }
        return scores
    }
}
