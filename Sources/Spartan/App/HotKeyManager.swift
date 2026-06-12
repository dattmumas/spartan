import AppKit
import Carbon.HIToolbox

/// Registers ⌘⇧A via Carbon RegisterEventHotKey. Carbon hotkeys do NOT
/// require Accessibility; they are independent of TCC. The C callback can't
/// close over Swift state, so it shuttles to a singleton.
@MainActor
final class HotKeyManager {
    static var trigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        guard hotKeyRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ in
                Task { @MainActor in HotKeyManager.trigger?() }
                return noErr
            },
            1, &eventType, nil, &handlerRef
        )
        guard status == noErr else { return }

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x5350_5254),  // 'SPRT'
            id: 1
        )
        RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
