import SwiftUI
import SpartanCore

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var state: AppState

    var body: some View {
        Canvas { context, size in
            for region in model.regions
            where (region.lineScores.max() ?? region.likelihood) >= state.threshold {
                draw(region, in: &context)
            }
            if let selection = model.selection {
                draw(selection, in: &context, canvasSize: size)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Selection verdict callout

    private func draw(
        _ selection: SelectionVerdict,
        in context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        // Subtle outline so the user sees what Spartan thinks is selected.
        for rect in selection.lineRects {
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 3),
                with: .color(.blue.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
            )
        }

        let (label, tint): (String, Color)
        switch selection.phase {
        case .checking:
            (label, tint) = ("Checking…", .gray)
        case .tooShort:
            (label, tint) = ("Selection too short to score (need ~15+ words)", .orange)
        case .scored(let likelihood, let headline, let lowConfidence):
            let pct = Int((likelihood * 100).rounded())
            let verdict = headline ?? (likelihood >= 0.5 ? "AI Generated" : "Human-written")
            let suffix = lowConfidence ? " · short sample" : ""
            (label, tint) = ("\(verdict) · \(pct)% AI\(suffix)",
                             likelihood >= 0.5 ? .red : .green)
        case .error(let message):
            (label, tint) = (message, .orange)
        }

        let text = Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
        let resolved = context.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: 420, height: 60))
        let padding: CGFloat = 10
        let badgeSize = CGSize(width: textSize.width + padding * 2,
                               height: textSize.height + padding)

        let anchor = selection.anchor
        var origin = CGPoint(
            x: anchor.midX - badgeSize.width / 2,
            y: anchor.maxY + 8
        )
        if origin.y + badgeSize.height > canvasSize.height - 4 {
            origin.y = anchor.minY - badgeSize.height - 8  // flip above
        }
        origin.x = min(max(12, origin.x), canvasSize.width - badgeSize.width - 12)
        origin.y = min(max(4, origin.y), canvasSize.height - badgeSize.height - 4)

        let badgeRect = CGRect(origin: origin, size: badgeSize)
        context.fill(
            Path(roundedRect: badgeRect, cornerRadius: badgeSize.height / 2),
            with: .color(tint.opacity(0.92))
        )
        context.draw(resolved, at: CGPoint(x: badgeRect.midX, y: badgeRect.midY))
    }

    private func draw(_ region: RenderableRegion, in context: inout GraphicsContext) {
        // Per-line drawing: only render lines whose own score crosses the
        // threshold. A mixed passage shows the AI sentences and leaves the
        // human ones alone.
        var drawnRects: [CGRect] = []
        for (rect, score) in zip(region.lineRects, region.lineScores)
        where score >= state.threshold {
            let path = Path(roundedRect: rect, cornerRadius: 3)
            switch state.mode {
            case .highlight:
                let opacity = 0.18 + 0.25 * score
                context.fill(path, with: .color(.red.opacity(opacity)))
                context.stroke(path, with: .color(.red.opacity(0.7)), lineWidth: 1)
            case .block:
                context.fill(path, with: .color(.black))
            }
            drawnRects.append(rect)
        }
        guard !drawnRects.isEmpty else { return }
        let union = GeometryMapping.union(of: drawnRects)
        let badgeScore = region.lineScores.max() ?? region.likelihood

        // Score badge at the passage's top-right corner.
        let prefix = region.headline ?? "AI"
        let suffix = region.lowConfidence ? "?" : ""
        let label = "\(prefix) \(Int(badgeScore * 100))%\(suffix)"
        let text = Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
        let resolved = context.resolve(text)
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        let badgeRect = CGRect(
            x: min(union.maxX - size.width - 8, union.maxX - size.width),
            y: max(union.minY - size.height - 4, 0),
            width: size.width + 10,
            height: size.height + 4
        )
        context.fill(
            Path(roundedRect: badgeRect, cornerRadius: badgeRect.height / 2),
            with: .color(.red.opacity(0.92))
        )
        context.draw(resolved, at: CGPoint(x: badgeRect.midX, y: badgeRect.midY))
    }
}
