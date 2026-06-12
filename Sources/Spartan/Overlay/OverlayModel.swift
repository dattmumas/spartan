import Foundation
import SwiftUI

/// One scored passage ready to draw: line rects are window-local points (top-left origin).
struct RenderableRegion: Identifiable {
    let id = UUID()
    let lineRects: [CGRect]
    let likelihood: Double
    let lowConfidence: Bool
}

/// Selection-mode verdict callout, anchored to the selected lines.
struct SelectionVerdict {
    enum Phase {
        case checking
        case tooShort
        case scored(likelihood: Double, lowConfidence: Bool)
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
