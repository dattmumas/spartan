import Foundation
import CoreGraphics

/// All coordinate conversions live here.
///
/// The captured buffer covers exactly the target window's content, so a
/// Vision-normalized rect (0–1, bottom-left origin) maps directly to
/// window-local points (top-left origin) by scaling into the window's point
/// size and flipping Y — Retina scale cancels out entirely.
public enum GeometryMapping {
    /// Vision-normalized (bottom-left origin) → window-local points (top-left origin).
    public static func windowRect(
        fromNormalized bb: CGRect,
        windowSize: CGSize,
        inflateBy inset: CGFloat = 0
    ) -> CGRect {
        let rect = CGRect(
            x: bb.minX * windowSize.width,
            y: (1 - bb.maxY) * windowSize.height,
            width: bb.width * windowSize.width,
            height: bb.height * windowSize.height
        )
        return rect.insetBy(dx: -inset, dy: -inset)
    }

    /// CoreGraphics global frame (top-left origin at primary display's top-left)
    /// → Cocoa global frame (bottom-left origin at primary display's bottom-left).
    public static func cocoaFrame(fromCGFrame cg: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: cg.minX,
            y: primaryScreenHeight - cg.maxY,
            width: cg.width,
            height: cg.height
        )
    }

    /// Union of a set of rects (used to anchor a passage's score badge).
    public static func union(of rects: [CGRect]) -> CGRect {
        guard var u = rects.first else { return .zero }
        for r in rects.dropFirst() { u = u.union(r) }
        return u
    }
}
