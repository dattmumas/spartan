import AppKit

struct TrackedWindow: Equatable {
    let windowID: CGWindowID
    /// Global frame in CoreGraphics coordinates (top-left origin, primary display).
    let frame: CGRect
    let ownerPID: pid_t
    let appName: String
}

/// Polls for the frontmost app's frontmost window (4 Hz) and reports
/// window identity changes, pure moves, and resizes separately.
@MainActor
final class ActiveWindowTracker {
    var onWindowChanged: ((TrackedWindow?) -> Void)?
    var onWindowMoved: ((TrackedWindow) -> Void)?
    var onWindowResized: ((TrackedWindow) -> Void)?

    private var timer: Timer?
    private var current: TrackedWindow?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var activationObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // App switches shouldn't wait for the next poll tick.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        current = nil
    }

    private func poll() {
        let found = frontmostWindow()
        switch (current, found) {
        case (nil, nil):
            return
        case (nil, .some(let new)):
            current = new
            onWindowChanged?(new)
        case (.some, nil):
            current = nil
            onWindowChanged?(nil)
        case (.some(let old), .some(let new)):
            current = new
            if old.windowID != new.windowID {
                onWindowChanged?(new)
            } else if old.frame.size != new.frame.size {
                onWindowResized?(new)
            } else if old.frame.origin != new.frame.origin {
                onWindowMoved?(new)
            }
        }
    }

    private func frontmostWindow() -> TrackedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID else { return nil }
        let pid = app.processIdentifier

        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }

        // The list is front-to-back; the first layer-0 window owned by the
        // frontmost app of a sensible size is the active window.
        for entry in info {
            guard let ownerPID = entry[kCGWindowOwnerPID] as? pid_t, ownerPID == pid,
                  let layer = entry[kCGWindowLayer] as? Int, layer == 0,
                  let windowID = entry[kCGWindowNumber] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 300, bounds.height >= 200
            else { continue }
            return TrackedWindow(
                windowID: windowID,
                frame: bounds,
                ownerPID: ownerPID,
                appName: app.localizedName ?? "app"
            )
        }
        return nil
    }
}
