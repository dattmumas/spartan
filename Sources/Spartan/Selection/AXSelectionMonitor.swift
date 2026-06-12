import AppKit
import ApplicationServices

/// Polls the frontmost app's accessibility tree for the selected text.
///
/// Primary capture path for selection mode: byte-exact text and ~250–500ms
/// response, no OCR involved. Apps that don't expose `AXSelectedText`
/// (some Electron/PDF viewers) simply yield nothing here and fall through to
/// the visual classifier. Polling (4 Hz) is deliberately used instead of
/// AXObserver: observers are frequently unreliable in Chromium-based apps,
/// and the poll is a sub-millisecond IPC call.
@MainActor
final class AXSelectionMonitor {
    var pidProvider: (() -> pid_t?)?
    /// Fired once per distinct selection, after it has been stable for one poll.
    var onSelection: ((String, CGRect?) -> Void)?
    /// Fired when a previously reported selection goes away.
    var onCleared: (() -> Void)?

    private var timer: Timer?
    private var lastText = ""
    private var reportedText = ""
    private var emptyPolls = 0

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!)
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        reset()
    }

    func reset() {
        lastText = ""
        reportedText = ""
        emptyPolls = 0
    }

    private func poll() {
        guard Self.isTrusted, let pid = pidProvider?() else { return }
        let selection = Self.currentSelection(pid: pid)
        let text = selection?.text ?? ""

        if text.isEmpty {
            lastText = ""
            emptyPolls += 1
            if emptyPolls >= 2, !reportedText.isEmpty {
                reportedText = ""
                onCleared?()
            }
            return
        }
        emptyPolls = 0
        // Report only once the drag has finished (same text two polls running).
        if text == lastText, text != reportedText {
            reportedText = text
            onSelection?(text, selection?.bounds)
        }
        lastText = text
    }

    /// Selected text + global screen bounds (CG top-left coords) of the
    /// frontmost app's focused element, if it exposes them.
    static func currentSelection(pid: pid_t) -> (text: String, bounds: CGRect?)? {
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &textRef
        ) == .success, let text = textRef as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var bounds: CGRect?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeRef, &boundsRef
            ) == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(unsafeDowncast(boundsRef as AnyObject, to: AXValue.self),
                                   .cgRect, &rect),
                   rect.width > 0, rect.height > 0 {
                    bounds = rect
                }
            }
        }
        return (text, bounds)
    }
}
