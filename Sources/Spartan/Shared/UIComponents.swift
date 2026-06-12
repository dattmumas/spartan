import AppKit
import SwiftUI

/// Colored percentage capsule shared by the History and Document Report rows.
struct ScoreCapsule: View {
    let score: Double

    var body: some View {
        let pct = Int((score * 100).rounded())
        let color: Color = score >= 0.5 ? .red : .green
        Text("\(pct)%")
            .font(.caption.monospacedDigit().bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.85), in: Capsule())
            .frame(width: 52, alignment: .center)
    }
}

/// Standard report-window construction shared by the History and Document
/// Report controllers.
@MainActor
func makeReportWindow<Root: View>(title: String, size: NSSize, root: Root) -> NSWindow {
    let w = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered, defer: false
    )
    w.title = title
    w.isReleasedWhenClosed = false
    w.center()
    w.contentView = NSHostingView(rootView: root)
    return w
}
