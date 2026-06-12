import AppKit
import SwiftUI
import SpartanCore

/// A transparent, click-through panel pinned over the tracked window.
/// Excluded from screen capture (`sharingType = .none`) so its own highlights
/// can never feed back into the stability hash or OCR.
@MainActor
final class OverlayWindowController {
    let model = OverlayModel()
    private var panel: NSPanel?
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func show(overCGFrame cgFrame: CGRect) {
        let panel = ensurePanel()
        let frame = cocoaFrame(from: cgFrame)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        logger.debug("overlay show: cg=\(String(describing: cgFrame), privacy: .public) cocoa=\(String(describing: frame), privacy: .public) visible=\(panel.isVisible, privacy: .public)")
    }

    func setRegions(_ regions: [RenderableRegion]) {
        model.regions = regions
        let scores = regions.map { String(format: "%.2f", $0.likelihood) }.joined(separator: ",")
        logger.debug("overlay regions: \(regions.count, privacy: .public) [\(scores, privacy: .public)] panelVisible=\(self.panel?.isVisible ?? false, privacy: .public)")
    }

    func setSelection(_ verdict: SelectionVerdict?) {
        model.selection = verdict
        let phase = verdict.map { String(describing: $0.phase) } ?? "nil"
        let frame = panel?.frame ?? .zero
        logger.info("overlay selection: \(phase, privacy: .public) anchor=\(verdict.map { String(describing: $0.anchor) } ?? "-", privacy: .public) panelVisible=\(self.panel?.isVisible ?? false, privacy: .public) panelFrame=\(String(describing: frame), privacy: .public) screens=\(NSScreen.screens.count, privacy: .public)")
    }

    func clear() {
        model.regions = []
    }

    func hide() {
        clear()
        model.selection = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: OverlayView(model: model, state: state))
        panel = p
        return p
    }

    /// CG global coords (top-left origin) → Cocoa global coords (bottom-left origin).
    private func cocoaFrame(from cg: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
        return GeometryMapping.cocoaFrame(fromCGFrame: cg, primaryScreenHeight: primaryHeight)
    }
}
