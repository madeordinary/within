import AppKit
import Carbon
import WithinCore

@MainActor
final class ShortcutManager {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private var escapeMonitor: Any?
    private var escapeReference: EventHotKeyRef?
    private var onEscape: (() -> Void)?

    init() {
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                  key.signature == 0x57495448 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
                if key.id == 2 {
                    if GetEventKind(event) == UInt32(kEventHotKeyPressed) { owner.onEscape?() }
                } else if GetEventKind(event) == UInt32(kEventHotKeyPressed) { owner.onDown?() }
                else { owner.onUp?() }
            }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(alternate: Bool) -> Bool {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        return RegisterEventHotKey(UInt32(alternate ? kVK_ANSI_D : kVK_Space), UInt32(controlKey | shiftKey), EventHotKeyID(signature: 0x57495448, id: 1), GetApplicationEventTarget(), 0, &reference) == noErr
    }
    func physicalChordHeld(alternate: Bool) -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(.maskControl) && flags.contains(.maskShift)
            && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(alternate ? kVK_ANSI_D : kVK_Space))
    }
    func monitorEscape(_ action: @escaping () -> Void) {
        stopEscapeMonitor()
        onEscape = action
        if RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x57495448, id: 2), GetApplicationEventTarget(), 0, &escapeReference) == noErr { return }
        guard AXIsProcessTrusted() else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { MainActor.assumeIsolated { action() } }
        }
    }
    func stopEscapeMonitor() {
        if let escapeReference { UnregisterEventHotKey(escapeReference); self.escapeReference = nil }
        onEscape = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
    func shutdown() {
        stopEscapeMonitor()
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
