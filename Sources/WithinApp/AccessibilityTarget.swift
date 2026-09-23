import AppKit
import Carbon
import ApplicationServices
import WithinCore

/// Conservative adapter. Retains AX identities, never field values or window titles.
@MainActor
final class AccessibilityTarget {
    let application: NSRunningApplication
    let appElement: AXUIElement
    let window: AXUIElement
    let element: AXUIElement
    private var observer: AXObserver?
    private(set) var focusChanged = false

    var appName: String { application.localizedName ?? "Original app" }

    private init(application: NSRunningApplication, app: AXUIElement,
                 window: AXUIElement, element: AXUIElement) {
        self.application = application
        self.appElement = app
        self.window = window
        self.element = element
    }

    static func capture(allowUnsupported: Bool = false) -> Result<AccessibilityTarget, TargetError> {
        guard !IsSecureEventInputEnabled() else { return .failure(.blocked(.secureField)) }
        guard AXIsProcessTrusted() else { return .failure(.blocked(.permissionRequired)) }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .failure(.blocked(.targetUnavailable))
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        guard let window = axElement(axApp, kAXFocusedWindowAttribute),
              let element = axElement(axApp, kAXFocusedUIElementAttribute),
              let elementWindow = axElement(element, kAXWindowAttribute),
              CFEqual(window, elementWindow) else { return .failure(.blocked(.targetUnavailable)) }
        let target = AccessibilityTarget(application: app, app: axApp, window: window, element: element)
        if let reason = target.evidence().blockReason, reason != .unsupported || !allowUnsupported { return .failure(.blocked(reason)) }
        // If an app cannot publish focus changes, Within refuses automatic insertion.
        guard target.startObserving() else { return .failure(.blocked(.unsupported)) }
        return .success(target)
    }

    func evidence(ignoreFocusHistory: Bool = false, forCompatibilityPaste: Bool = false) -> TargetEvidence {
        guard !IsSecureEventInputEnabled() else { return .init(secure: true) }
        guard AXIsProcessTrusted() else { return .init(permissionGranted: false) }
        guard !application.isTerminated,
              let currentWindow = Self.axElement(appElement, kAXFocusedWindowAttribute),
              let currentElement = Self.axElement(appElement, kAXFocusedUIElementAttribute),
              let owningWindow = Self.axElement(element, kAXWindowAttribute),
              CFEqual(window, owningWindow) else { return .init(targetAlive: false) }
        var settable = DarwinBoolean(false)
        let canWrite = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        return TargetEvidence(
            sameApplication: NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
            sameWindow: CFEqual(currentWindow, window),
            sameElement: CFEqual(currentElement, element),
            focusChanged: !ignoreFocusHistory && focusChanged,
            secure: Self.secureStatus(element),
            canReplaceSelection: canWrite || forCompatibilityPaste
        )
    }

    func replaceSelection(with text: String) -> Bool {
        // Revalidate again as close as possible to the write. AX does not offer an atomic
        // focus-and-write transaction; the remaining race is a Phase 0 test requirement.
        guard evidence().blockReason == nil else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    func restoreOriginalTarget() -> Bool {
        stopObserving()
        guard AXIsProcessTrusted(), !application.isTerminated,
              Self.secureStatus(element) == false,
              let owningWindow = Self.axElement(element, kAXWindowAttribute), CFEqual(owningWindow, window) else { return false }
        guard application.activate(options: []),
              AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success,
              AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
        focusChanged = false
        return true
    }

    func markFocusChanged() { focusChanged = true }

    func stopObserving() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    private func startObserving() -> Bool {
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<AccessibilityTarget>.fromOpaque(context).takeUnretainedValue().markFocusChanged()
            }
        }
        guard AXObserverCreate(application.processIdentifier, callback, &newObserver) == .success,
              let newObserver else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            guard AXObserverAddNotification(newObserver, appElement, name as CFString, context) == .success else { return false }
        }
        observer = newObserver
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        return true
    }

    private static func secureStatus(_ element: AXUIElement) -> Bool? {
        guard let role = string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }
        var cursor: AXUIElement? = element
        // Inspect non-content ancestors too; never ask for AXValue or AXSelectedText.
        for _ in 0..<16 {
            guard let node = cursor else { return nil }
            let role = string(node, kAXRoleAttribute)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &value)
            if error == .success, let value, CFGetTypeID(value) == CFStringGetTypeID(),
               (value as! String) == kAXSecureTextFieldSubrole { return true }
            guard [.success, .noValue, .attributeUnsupported].contains(error) else { return nil }
            if role == kAXWindowRole || role == kAXApplicationRole { return false }
            cursor = axElement(node, kAXParentAttribute)
        }
        return nil
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }
}

enum TargetError: Error {
    case blocked(RecoveryReason)
    var reason: RecoveryReason { switch self { case .blocked(let reason): return reason } }
}
