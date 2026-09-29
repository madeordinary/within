import AppKit
import SwiftUI
import WithinCore

struct MicrophoneControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Microphone", selection: $model.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(model.devices) { Text($0.name).tag($0.id) }
                    if !model.microphoneUID.isEmpty && !model.selectedInputAvailable {
                        Text("Selected microphone unavailable").tag(model.microphoneUID)
                    }
                }.disabled(model.workerBusy || model.phase != .ready)
                Button(action: model.refreshPermissions) {
                    Image(systemName: "arrow.clockwise")
                }.help("Refresh microphones and permissions")
                    .accessibilityLabel("Refresh microphones and permissions")
            }
            if !model.selectedInputAvailable {
                Label(model.devices.isEmpty ? "No microphone found. Connect one, then refresh." : "This microphone is disconnected. Choose another or reconnect it.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.onAppear { model.refreshPermissions() }
    }
}

struct ActivationControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                modeOption(.hold, title: "Hold to talk", detail: "Hold the shortcut while speaking. Release to finish.")
                modeOption(.toggle, title: "Press to start / stop", detail: "Press once to start and again to finish.")
            }.disabled(model.workerBusy || model.phase != .ready)
                .accessibilityElement(children: .contain).accessibilityLabel("Recording gesture")
            ShortcutControl(model: model)
            if model.dictationShortcut.isModifierOnly && !model.accessibilityAllowed {
                HStack(alignment: .top) {
                    Text("Allow Accessibility to use this modifier key outside Within. Practice can still use its Start button.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Button("Allow…", action: model.requestAccessibility).accessibilityLabel("Allow Accessibility for shortcut")
                }
            } else if !model.shortcutAvailable {
                Label("Shortcut unavailable. Choose another or use the menu bar.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Palette.warning)
            }
            if !model.shortcutMessage.isEmpty { Text(model.shortcutMessage).font(.system(size: 12)).foregroundStyle(Palette.warning) }
            Text("Escape cancels. Recording stops at five minutes.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
    }
    private func modeOption(_ mode: ActivationMode, title: String, detail: String) -> some View {
        let selected = model.mode == mode
        return Button { model.mode = mode } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                    .foregroundStyle(selected ? Palette.accent : Palette.secondary.opacity(0.6)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(selected ? Palette.tint.opacity(0.75) : Palette.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? Palette.accent.opacity(0.55) : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Shared by Home, setup and Settings so each entry point uses the same editing boundary.
struct ShortcutControl: View {
    @ObservedObject var model: AppModel
    var hero = false
    @State private var recordingShortcut = false
    var body: some View {
        Group {
            if hero {
                VStack(spacing: 16) {
                    Keycaps(shortcut: model.dictationShortcut, large: true)
                    Button("Change shortcut…") { recordingShortcut = model.beginShortcutEditing() }.quietAction()
                        .accessibilityLabel("Change dictation shortcut")
                }
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Shortcut").font(.system(size: 13, weight: .medium))
                        Text(model.mode == .hold ? "Hold to talk. Release to finish." : "Press once to start, again to finish.")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 8)
                    Keycaps(shortcut: model.dictationShortcut)
                    Button("Change…") { recordingShortcut = model.beginShortcutEditing() }.quietAction()
                        .accessibilityLabel("Change dictation shortcut")
                }
            }
        }.disabled(model.workerBusy || model.phase != .ready || model.editingShortcut)
        .sheet(isPresented: $recordingShortcut, onDismiss: model.endShortcutEditing) {
            ShortcutRecorderView(model: model)
        }
    }
}

struct ShortcutRecorderView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: DictationShortcut?
    @State private var keysReleased = true
    @State private var hint = "Press a key combination, or press and release Right Control."
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose your shortcut").font(.system(size: 24, weight: .semibold))
            Text("Try Right Control, or a combination such as Control + Shift + D. Dictation is paused while you choose.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
            VStack(spacing: 10) {
                Text(candidate?.displayName ?? "Press your shortcut")
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .accessibilityHidden(true)
                Text(keysReleased ? hint : "Release all keys to use this shortcut.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 105).padding(16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
                .overlay(ShortcutCaptureField { binding, released, explanation in
                    candidate = binding; keysReleased = released
                    if let explanation { hint = explanation }
                })
            Text("Choose a key you don’t use for typing or another dictation app. Control, Right Option and Right Command can work alone. Left and right are separate choices.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            if !model.shortcutMessage.isEmpty { Text(model.shortcutMessage).font(.system(size: 12)).foregroundStyle(Palette.warning) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use shortcut") {
                    if let candidate, model.chooseShortcut(candidate) { dismiss() }
                }.primaryAction().disabled(candidate == nil || !keysReleased)
            }
        }.padding(28).frame(width: 430).background(Palette.canvas).foregroundStyle(Palette.text)
            .onDisappear { model.endShortcutEditing() }
    }
}

/// An explicit, window-local recorder. Events are never saved; only its chosen binding is returned.
private struct ShortcutCaptureField: NSViewRepresentable {
    let changed: (DictationShortcut?, Bool, String?) -> Void
    func makeNSView(context: Context) -> ShortcutCaptureNSView { ShortcutCaptureNSView(changed: changed) }
    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {}
}

final class ShortcutCaptureNSView: NSView {
    let changed: (DictationShortcut?, Bool, String?) -> Void
    private var candidate: DictationShortcut?
    private var modifierCandidate: UInt16?
    private var sawKey = false
    private var keyIsDown = false
    private var invalidCombination = false
    private var lastAnnouncement: String?
    init(changed: @escaping (DictationShortcut?, Bool, String?) -> Void) {
        self.changed = changed; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Dictation shortcut recorder")
        setAccessibilityValue("Press your shortcut")
        setAccessibilityHelp("Press Control, Right Option or Right Command alone, or a combination containing Control or Command. Tab moves to the buttons. Click this box to record again.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func draw(_ dirtyRect: NSRect) {
        guard window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        ring.lineWidth = 3; ring.stroke()
    }
    private func publish(released: Bool, explanation: String? = nil) {
        let detail = released && candidate != nil ? "Shortcut selected. Click here or press another shortcut to change it." : explanation
        changed(candidate, released, detail)
        let value = candidate?.accessibilityName ?? "No shortcut selected"
        setAccessibilityValue(value)
        if released {
            let announcement = candidate.map { "\($0.accessibilityName) selected" } ?? detail
            if let announcement, announcement != lastAnnouncement {
                lastAnnouncement = announcement
                NSAccessibility.post(element: self, notification: .announcementRequested,
                    userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { DispatchQueue.main.async { [weak self, weak window] in if let self { window?.makeFirstResponder(self) } } }
    }
    private func modifiers(_ event: NSEvent) -> UInt8 {
        ShortcutManager.modifiers(CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if event.keyCode == 53 || (event.keyCode == 48 && modifiers(event) & ~DictationShortcut.shift == 0) { return false }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.cancelOperation(nil); return }
        if event.keyCode == 48 && modifiers(event) & ~DictationShortcut.shift == 0 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(nil) }
            else { window?.selectNextKeyView(nil) }
            return
        }
        guard !event.isARepeat else { return }
        sawKey = true; keyIsDown = true
        let special: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 117: "Forward Delete",
            65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "Keypad Enter", 78: "Keypad -", 81: "Keypad =",
            82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9"]
        let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let binding = DictationShortcut(keyCode: event.keyCode, modifiers: modifiers(event), keyLabel: label)
        candidate = binding.isValid ? binding : nil
        invalidCombination = !binding.isValid
        publish(released: false, explanation: binding.isValid ? "Release all keys to use this shortcut." : "Use Control or Command with a key that isn’t reserved for editing or macOS. Escape cancels.")
    }
    override func keyUp(with event: NSEvent) {
        keyIsDown = false
        let released = modifiers(event) == 0
        publish(released: released)
        if released { sawKey = false; modifierCandidate = nil; invalidCombination = false }
    }
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 63 || event.keyCode == 57 {
            candidate = nil; modifierCandidate = nil; invalidCombination = true
            publish(released: false, explanation: "Fn/Globe and Caps Lock aren’t supported here. Choose another key.")
            return
        }
        let flags = modifiers(event)
        if !sawKey {
            if flags != 0, DictationShortcut.modifierName(for: event.keyCode) != nil {
                let held: [UInt16] = [54, 55, 56, 60, 58, 61, 59, 62].filter {
                    ShortcutManager.modifierIsDown(keyCode: $0, eventFlags: event.modifierFlags.rawValue)
                }
                if held.count == 1 && modifierCandidate == nil && !invalidCombination {
                    modifierCandidate = event.keyCode
                } else if held.count > 1 { invalidCombination = true; modifierCandidate = nil; candidate = nil }
            }
            if flags == 0, let code = modifierCandidate, !invalidCombination {
                let binding = DictationShortcut(keyCode: code, modifiers: 0, keyLabel: DictationShortcut.modifierName(for: code)!)
                candidate = binding.isValid ? binding : nil
                invalidCombination = !binding.isValid
            }
        }
        publish(released: flags == 0 && !keyIsDown, explanation: invalidCombination ? "Use Control, Right Option or Right Command alone, or a combination containing Control or Command." : nil)
        if flags == 0 && !keyIsDown { modifierCandidate = nil; sawKey = false; invalidCombination = false }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pasteDisclosure = false
    @State private var showingDiagnostics = false
    @State private var confirmingClear = false
    @State private var pendingRetention: HistoryRetention?
    static let sections = [("General", "slider.horizontal.3"), ("Audio", "mic"), ("History", "clock.arrow.circlepath"), ("Privacy", "hand.raised"), ("Model", "internaldrive"), ("About", "info.circle")]
    var body: some View {
            page {
                switch model.settingsSection {
            case "General":
                heading("Your everyday rhythm", detail: "Choose how you start and finish dictation.")
                ActivationControls(model: model).withinSurface()
                VStack(alignment: .leading, spacing: 12) {
                    row("Start Within at login", detail: model.loginMessage.isEmpty ? nil : model.loginMessage) {
                        Toggle("Start Within at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLaunchAtLogin)).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    row("Play start and stop sounds") {
                        Toggle("Play start and stop sounds", isOn: $model.soundsEnabled).labelsHidden().toggleStyle(.switch)
                    }
                }.withinSurface(padding: 16)
                Text("Closing Home keeps Within available in the Dock and menu bar. Quit Within exits the app completely.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            case "Audio":
                heading("Your microphone", detail: "Choose an input. Within never silently switches it during dictation.")
                MicrophoneControls(model: model).withinSurface()
                VStack(alignment: .leading, spacing: 18) {
                    PermissionRow(title: "Microphone", detail: "Used only after you start dictation.", allowed: model.microphoneAllowed, action: model.requestMicrophone)
                    Divider()
                    PermissionRow(title: "Accessibility", detail: "Inserts into your original field and checks focus. Optional for practice and Copy.", allowed: model.accessibilityAllowed, action: model.requestAccessibility)
                }.withinSurface()
                VStack(alignment: .leading, spacing: 12) {
                    row("Mute this Mac’s sound while dictating", detail: "When another app is playing, Within silences your Mac’s sound output while you dictate and turns it back on when you stop. Videos and music keep playing silently. Nothing is muted while another app is using a microphone, such as a call. Within’s start and stop sounds are muted too. Pausing instead of muting is planned.") {
                        Toggle("Mute this Mac’s sound while dictating", isOn: $model.muteOutputWhileDictating).labelsHidden().toggleStyle(.switch)
                    }
                }.withinSurface(padding: 16)
            case "History":
                heading("Your dictation history", detail: "Saved only on this Mac, left out of Time Machine backups and never uploaded.")
                VStack(alignment: .leading, spacing: 14) {
                    Text("Keep dictations").font(.system(size: 13, weight: .medium))
                    HistoryRetentionPicker(selection: Binding(get: { model.effectiveRetention }, set: requestRetention))
                    Text(model.historyRetention == nil ? "You haven’t chosen yet, so nothing is saved." : model.effectiveRetention.keepsHistory ? "Only words you insert or copy are kept. Practice, canceled and discarded words never are." : "Dictations aren’t saved.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }.withinSurface()
                VStack(alignment: .leading, spacing: 12) {
                    row(model.history.count == 1 ? "1 saved dictation" : "\(model.history.count) saved dictations",
                        detail: "Deleting removes words from Within’s history file. Like other deleted files, it isn’t a secure erase of the disk.") {
                        Button("Clear history…", role: .destructive) { confirmingClear = true }.quietAction().disabled(model.history.isEmpty)
                    }
                }.withinSurface(padding: 16)
            case "Privacy":
                heading("Your words stay with you", detail: "Nothing crosses a boundary without your choice.")
                VStack(alignment: .leading, spacing: 15) {
                    Label("On-device transcription", systemImage: "desktopcomputer")
                    Label(model.effectiveRetention.keepsHistory ? "No recordings saved · dictation history stays on this Mac" : "No recordings or dictation history saved", systemImage: "clock.badge.xmark")
                    Label("No account, analytics, or cloud fallback", systemImage: "lock.shield")
                    Text("Audio and pending words stay in memory. Copy uses your clipboard only when you choose it. Quitting clears pending text.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }.withinSurface()
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Compatibility paste · experimental", isOn: Binding(get: { model.compatibilityPaste }, set: { value in
                        if value { pasteDisclosure = true } else { model.compatibilityPaste = false }
                    })).disabled(model.workerBusy || model.phase != .ready)
                    Text("Off by default. Uses your clipboard and a paste shortcut only for an eligible field that cannot accept direct insertion. Protected or unknown fields still go to recovery.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    if model.compatibilityPaste {
                        Text("Other apps and Universal Clipboard may read or sync the text. Within tries to restore your clipboard and asks you to check the result.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                }.withinSurface()
            case "Model":
                heading("One local speech model", detail: "Prepare it once. Dictate without a network connection.")
                ModelPanel(model: model).withinSurface()
            case "About":
                Brand()
                Text("A little more room to think.").font(Typography.display(24))
                Text("Within, by Made Ordinary\nEngineering preview · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                Text("A free, open-source Mac app for local English dictation. This build is for local evaluation; release signing, supported-system and broader app compatibility checks remain pending.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Divider()
                Text("Within: MIT · FluidAudio: Apache 2.0\nParakeet TDT v3: CC BY 4.0\nCore ML conversion by Fluid Inference")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Link("Source & app license ↗", destination: URL(string: "https://github.com/madeordinary/within")!)
                Link("FluidAudio source & license ↗", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
                Text("Links open in your browser.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                UpdatesPanel(model: model).withinSurface(padding: 16)
                Button("Review diagnostics…") { showingDiagnostics = true }
                Text("Review content-free status and error information before choosing to save a report. Nothing is sent automatically.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                default: EmptyView()
                }
            }
        .frame(minWidth: 460, minHeight: 420).foregroundStyle(Palette.text).tint(Palette.accent)
            .onAppear { model.refreshPermissions() }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsView(text: model.diagnostics()) }
            .confirmationDialog("Clear all dictation history?", isPresented: $confirmingClear) {
                Button("Clear history", role: .destructive, action: model.clearHistory)
                Button("Keep history", role: .cancel) {}
            } message: { Text("This deletes every saved dictation from this Mac. It cannot be undone.") }
            .confirmationDialog(retentionPrompt, isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })) {
                Button(pendingRetention == .off ? "Delete and turn off" : "Delete older dictations", role: .destructive) {
                    if let pendingRetention { model.chooseHistoryRetention(pendingRetention) }
                    pendingRetention = nil
                }
                Button("Keep them", role: .cancel) { pendingRetention = nil }
            } message: { Text("Removed dictations cannot be recovered.") }
            .confirmationDialog("Enable compatibility paste?", isPresented: $pasteDisclosure) {
                Button("Enable compatibility paste") { model.compatibilityPaste = true }
                Button("Keep it off", role: .cancel) {}
            } message: {
                Text("Your words will temporarily enter the clipboard. Other apps, clipboard managers, and Universal Clipboard may read or sync them. Clipboard restoration is best effort; you must review the insertion result.")
            }
    }
    /// Shortening retention or turning history off asks before anything is deleted.
    private func requestRetention(_ retention: HistoryRetention) {
        let remaining = HistoryPolicy.prune(model.history, now: Date(), retention: retention).count
        if remaining < model.history.count { pendingRetention = retention } else { model.chooseHistoryRetention(retention) }
    }
    private var retentionPrompt: String {
        guard let pendingRetention else { return "" }
        let removed = model.history.count - HistoryPolicy.prune(model.history, now: Date(), retention: pendingRetention).count
        let noun = removed == 1 ? "1 saved dictation" : "\(removed) saved dictations"
        return pendingRetention == .off ? "Turn off history and delete \(noun)?" : "Keep \(pendingRetention.title) and delete \(noun)?"
    }
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 20, content: content).font(.system(size: 13)).padding(.horizontal, 32).padding(.vertical, 30).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typography.display(26)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }
    private func row<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

struct HelpView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("A little help with Within.").font(Typography.display(30)).accessibilityAddTraits(.isHeader)
                help("Start with your cursor", icon: "cursorarrow", text: "Choose an editable field in another app, then use \(model.shortcutLabel). \(model.mode == .hold ? "Hold while speaking and release to finish." : "Press once to start and again to finish.") Escape cancels without transcribing.")
                help("Try it here first", icon: "waveform", text: "Expand Try dictation on Home. Opening the practice area does not record; choose Start practice or use the shortcut while the area is open and Within is active. Your practice words stay until you clear them or quit.")
                Button("Try dictation") { model.showPractice?() }.disabled(model.workerBusy)
                help("When words need review", icon: "text.bubble", text: "If the destination changes or insertion is uncertain, Within keeps your words for review. Return rechecks the original field. Copy uses the clipboard only when you choose it. Closing recovery keeps pending words in memory; Discard removes them after confirmation.")
                help("Check the selected microphone", icon: "mic", text: "If an input disappears, reconnect it or choose another in Settings → Audio. Within does not switch devices or restart capture silently.")
                help("One window, fewer interruptions", icon: "macwindow", text: "Dictation, Settings and Help share this window’s sidebar. Command-comma opens Settings. Closing the window leaves Within in the Dock and menu bar; Quit Within exits completely and asks before discarding active or pending dictation.")
                help("Made to stay local", icon: "lock.shield", text: "The speech model is a separate, explicit download. Dictation itself runs on your Mac. No recordings are saved. Dictation history is kept only if you turn it on, only on this Mac, for as long as you choose. This engineering preview has no automatic updater.")
            }.padding(.horizontal, 32).padding(.vertical, 30).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 460, minHeight: 420).foregroundStyle(Palette.text).tint(Palette.accent)
    }
    private func help(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(3)
        }
    }
}

/// Explicit or opt-in weekly checks. Download hands the DMG to the browser; nothing installs itself.
struct UpdatesPanel: View {
    @ObservedObject var model: AppModel
    /// Where this copy runs from, so the new one replaces it instead of landing beside it.
    private var installFolder: String {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent().path
        if folder.hasPrefix("/Volumes/") || folder.contains("/AppTranslocation/") { return "Applications" }
        return (folder as NSString).abbreviatingWithTildeInPath
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Updates").font(.system(size: 13, weight: .semibold))
                    Text(model.updateSummary).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 8)
                if model.checkingForUpdates { ProgressView().controlSize(.small).accessibilityLabel("Checking for updates") }
                Button("Check for Updates", action: model.checkForUpdates).quietAction().disabled(model.checkingForUpdates)
            }
            if let release = model.availableUpdate {
                let notes = UpdateCheck.displayNotes(release.notes)
                VStack(alignment: .leading, spacing: 8) {
                    if !notes.isEmpty {
                        Text(notes).font(.system(size: 12)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Download…") { NSWorkspace.shared.open(release.downloadURL ?? release.pageURL) }.primaryAction()
                            .accessibilityHint(release.downloadURL == nil ? "Opens the release page in your browser" : "Downloads the update in your browser")
                        Text("Then quit Within, open the download and drag Within over the copy in \(installFolder). Your settings, history and notes stay.")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Link("Release page ↗", destination: release.pageURL).font(.system(size: 11))
                }
            }
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check automatically once a week").font(.system(size: 13, weight: .medium))
                    Text("Sends one request to GitHub (api.github.com). No dictation, notes, history or usage data. Off unless you turn it on.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Check automatically once a week", isOn: Binding(get: { model.automaticUpdateChecks == true }, set: model.setAutomaticUpdateChecks))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
    }
}
