import AppKit
import Carbon
import WithinCore

@MainActor
final class ShortcutManager {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onTap: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var activationMode: (() -> ActivationMode)?
    private var registrationID: UInt32 = 10
    private var modifierGlobalMonitor: Any?
    private var modifierLocalMonitor: Any?
    private var modifierTimer: Timer?
    private var modifierGesture = ModifierShortcutGesture()
    private var modifierPressed = false
    private var modifierPressedAt: TimeInterval = 0
    private var modifierMode: ActivationMode = .hold
    private var missingReleaseSince: TimeInterval?
    private let modifierArmDelay: TimeInterval = 0.35
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
                } else if key.id == owner.registrationID, owner.reference != nil {
                    if GetEventKind(event) == UInt32(kEventHotKeyPressed) { owner.onDown?() }
                    else { owner.onUp?() }
                }
            }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func unregisterDictation() {
        registrationID &+= 1
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let modifierGlobalMonitor { NSEvent.removeMonitor(modifierGlobalMonitor) }
        if let modifierLocalMonitor { NSEvent.removeMonitor(modifierLocalMonitor) }
        modifierGlobalMonitor = nil; modifierLocalMonitor = nil
        modifierTimer?.invalidate(); modifierTimer = nil
        modifierGesture = ModifierShortcutGesture(); modifierPressed = false; missingReleaseSince = nil
    }
    func register(_ binding: DictationShortcut) -> Bool {
        unregisterDictation()
        guard binding.isValid else { return false }
        if binding.isModifierOnly {
            let generation = registrationID
            // Do not treat a key already held when editing finishes as a new press.
            modifierPressed = CGEventSource.keyState(.hidSystemState, key: binding.keyCode)
            if modifierPressed { modifierGesture.down(isAlone: false) }
            let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            modifierLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated {
                    if self?.registrationID == generation { self?.handleModifier(event, binding: binding) }
                }
                return event
            }
            if AXIsProcessTrusted() {
                modifierGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
                    MainActor.assumeIsolated {
                        if self?.registrationID == generation { self?.handleModifier(event, binding: binding) }
                    }
                }
            }
            if modifierPressed { armModifierTimer(binding) }
            return modifierGlobalMonitor != nil
        }
        var flags: UInt32 = 0
        if binding.modifiers & DictationShortcut.command != 0 { flags |= UInt32(cmdKey) }
        if binding.modifiers & DictationShortcut.option != 0 { flags |= UInt32(optionKey) }
        if binding.modifiers & DictationShortcut.control != 0 { flags |= UInt32(controlKey) }
        if binding.modifiers & DictationShortcut.shift != 0 { flags |= UInt32(shiftKey) }
        return RegisterEventHotKey(UInt32(binding.keyCode), flags, EventHotKeyID(signature: 0x57495448, id: registrationID), GetApplicationEventTarget(), 0, &reference) == noErr
    }
    private func modifierIsAlone(_ binding: DictationShortcut) -> Bool {
        let modifierCodes: [CGKeyCode] = [54, 55, 56, 60, 58, 61, 59, 62, 63]
        return modifierCodes.filter { $0 != binding.keyCode }.allSatisfy { !CGEventSource.keyState(.hidSystemState, key: $0) }
    }
    // Per-event side bits from IOKit/hidsystem/IOLLEvent.h. The aggregate Control
    // bit cannot distinguish releasing Right Control while Left Control is held.
    static func modifierIsDown(keyCode: UInt16, eventFlags: UInt) -> Bool {
        let masks: [UInt16: UInt] = [59: 0x1, 56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 62: 0x2000]
        guard let mask = masks[keyCode] else { return false }
        return eventFlags & mask != 0
    }
    private func armModifierTimer(_ binding: DictationShortcut) {
        modifierTimer?.invalidate()
        // Only polls during the selected key press. No idle keyboard polling.
        let generation = registrationID
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.registrationID == generation { self?.pollModifier(binding) }
            }
        }
        modifierTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func handleModifier(_ event: NSEvent, binding: DictationShortcut) {
        guard !IsSecureEventInputEnabled() else { resetModifier(); return }
        if event.type != .flagsChanged {
            emit(modifierGesture.interrupt())
            return
        }
        let down = Self.modifierIsDown(keyCode: binding.keyCode, eventFlags: event.modifierFlags.rawValue)
        if event.keyCode != binding.keyCode {
            // Read the event itself: a quick second modifier may already be up
            // in hardware by the time its queued flagsChanged event is delivered.
            let otherHeld = [UInt16(54), 55, 56, 60, 58, 61, 59, 62].contains {
                $0 != binding.keyCode && Self.modifierIsDown(keyCode: $0, eventFlags: event.modifierFlags.rawValue)
            }
            if modifierPressed && (otherHeld || event.modifierFlags.contains(.function)) { emit(modifierGesture.interrupt()) }
            return
        }
        if down && !modifierPressed {
            modifierPressed = true; modifierPressedAt = event.timestamp
            modifierMode = activationMode?() ?? .hold; missingReleaseSince = nil
            let noOtherKey = (UInt16(0)...126).filter { $0 != binding.keyCode && $0 != 57 }
                .allSatisfy { !CGEventSource.keyState(.hidSystemState, key: $0) }
            modifierGesture.down(isAlone: modifierIsAlone(binding) && noOtherKey)
            armModifierTimer(binding)
        } else if !down && modifierPressed {
            modifierPressed = false; modifierTimer?.invalidate(); modifierTimer = nil
            // If the main thread was busy, a long press is still not a toggle tap.
            if modifierGesture.isArmed && event.timestamp - modifierPressedAt >= modifierArmDelay {
                _ = modifierGesture.activateIfStillHeld()
            }
            emit(modifierGesture.up())
        }
    }
    private func pollModifier(_ binding: DictationShortcut) {
        guard modifierPressed else { return }
        guard !IsSecureEventInputEnabled() else { resetModifier(); return }
        if !CGEventSource.keyState(.hidSystemState, key: binding.keyCode) {
            // Give the already-queued release event a bounded chance to deliver a tap.
            if modifierGesture.isArmed {
                if missingReleaseSince == nil { missingReleaseSince = ProcessInfo.processInfo.systemUptime }
                if ProcessInfo.processInfo.systemUptime - missingReleaseSince! < 0.3 { return }
            }
            modifierPressed = false; modifierTimer?.invalidate(); modifierTimer = nil
            // A missed release can stop a hold, but cannot start a new toggle recording.
            emit(modifierGesture.up(observed: false))
        } else if !modifierIsAlone(binding) {
            emit(modifierGesture.interrupt())
        } else if ProcessInfo.processInfo.systemUptime - modifierPressedAt >= modifierArmDelay {
            emit(modifierGesture.activateIfStillHeld())
        }
    }
    private func resetModifier() {
        modifierTimer?.invalidate(); modifierTimer = nil
        emit(modifierGesture.interrupt()); modifierGesture = ModifierShortcutGesture(); modifierPressed = false
    }
    private func emit(_ action: ModifierShortcutAction?) {
        switch action {
        case .press: if modifierMode == .hold { onDown?() }
        case .release: onUp?()
        case .tap: if modifierMode == .toggle { onTap?() }
        case .cancel: onInterrupted?()
        case nil: break
        }
    }
    func isHeld(_ binding: DictationShortcut) -> Bool {
        guard CGEventSource.keyState(.hidSystemState, key: binding.keyCode) else { return false }
        // Only this manager owns modifier interruption/cancellation. The hold
        // watchdog must not race it by transcribing on an extra modifier.
        if binding.isModifierOnly { return true }
        let flags = Self.modifiers(CGEventSource.flagsState(.hidSystemState))
        return flags & binding.modifiers == binding.modifiers
    }
    static func modifiers(_ flags: CGEventFlags) -> UInt8 {
        var value: UInt8 = 0
        if flags.contains(.maskCommand) { value |= DictationShortcut.command }
        if flags.contains(.maskAlternate) { value |= DictationShortcut.option }
        if flags.contains(.maskControl) { value |= DictationShortcut.control }
        if flags.contains(.maskShift) { value |= DictationShortcut.shift }
        return value
    }
    func chordState(_ binding: DictationShortcut, source: CGEventSourceStateID = .hidSystemState) -> ShortcutChordState {
        // The release watchdog needs hardware state, not the session table
        // that also combines events posted by software.
        let flags = CGEventSource.flagsState(source)
        return ShortcutChordState(controlHeld: flags.contains(.maskControl), shiftHeld: flags.contains(.maskShift),
            triggerHeld: CGEventSource.keyState(source, key: binding.keyCode))
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
        unregisterDictation()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
