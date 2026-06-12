import Foundation
import SwiftUI

/// One scored passage ready to draw: line rects are window-local points
/// (top-left origin). When `lineScores` contains a per-line value derived from
/// Pangram v3's `windows`, the overlay can tint only the AI sentences inside
/// a mixed passage; otherwise every line takes `likelihood`.
struct RenderableRegion: Identifiable {
    let id = UUID()
    let lineRects: [CGRect]
    let lineScores: [Double]
    let likelihood: Double
    let headline: String?
    let lowConfidence: Bool
}

/// Selection-mode verdict callout, anchored to the selected lines.
struct SelectionVerdict {
    enum Phase {
        case checking
        case tooShort
        case scored(likelihood: Double, headline: String?, lowConfidence: Bool)
        case error(String)
    }

    let phase: Phase
    /// Union of the selected lines' rects, window-local points.
    let anchor: CGRect
    let lineRects: [CGRect]
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var regions: [RenderableRegion] = []
    @Published var selection: SelectionVerdict?
}
