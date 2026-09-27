import AppKit
import SwiftUI
import WithinCore

enum AppPage { case home, settings, help, setup, recovery }

/// Presentation state is transient; navigating never starts capture or clears words.
@MainActor
final class AppNavigation: ObservableObject {
    @Published private(set) var page: AppPage = .home
    @Published private(set) var practiceExpanded = false
    @Published var setupStep = 0
    private var history: [AppPage] = []
    var backDestination: AppPage { history.last ?? .home }
    var showsPractice: Bool { page == .home && practiceExpanded }

    @discardableResult
    func navigate(to destination: AppPage, practice: Bool? = nil, back: Bool = false,
                  model: AppModel, blocked: Bool, confirmPracticeExit: () -> Bool) -> Bool {
        guard !blocked, !model.editingShortcut else { return false }
        let leavesPractice = destination != .home || practice == false
        guard !leavesPractice || allowPracticeExit(model: model, confirm: confirmPracticeExit) else { return false }
        guard destination != .recovery || model.phase == .recovery else { return false }
        if destination == .home { history.removeAll() }
        else if destination != page {
            if back { _ = history.popLast() } else { history.append(page) }
        }
        page = destination
        if let practice { practiceExpanded = practice }
        return true
    }

    func allowPracticeExit(model: AppModel, confirm: () -> Bool) -> Bool {
        guard model.hasActivePracticeSession else { return true }
        let id = model.session.id
        guard confirm() else { return false }
        // A result or a later session can arrive while a native alert is open.
        if model.shouldCancelPracticeOnClose(sessionID: id) { model.cancel() }
        return model.phase != .recovery && !model.hasActivePracticeSession
    }

    func recoveryDismissed() { page = .home; history.removeAll() }
}

struct AppWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: AppNavigation
    var togglePractice: (Bool) -> Void
    var body: some View {
        Group {
            switch navigation.page {
            case .home:
                MainView(model: model, practiceExpanded: navigation.practiceExpanded, togglePractice: togglePractice)
            case .settings: SettingsView(model: model)
            case .help: HelpView(model: model)
            case .setup:
                SetupView(model: model, done: { model.showMain?() }, step: $navigation.setupStep)
            case .recovery: RecoveryView(model: model)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var practiceExpanded = false
    var togglePractice: (Bool) -> Void = { _ in }
    private var needsSetup: Bool { !model.modelInstalled || !model.microphoneAllowed }
    private var title: String {
        switch model.phase {
        case .preparing: return "Getting ready to listen"
        case .recording: return model.audioFlowing ? "Listening to you" : "Starting your microphone"
        case .transcribing: return "Finishing your words"
        case .recovery: return "Your words are waiting"
        case .ready:
            if model.editingShortcut { return "Finish choosing your shortcut" }
            if needsSetup { return "Make yourself at home" }
            if !model.selectedInputAvailable { return "Your microphone is unavailable" }
            if model.modelBusy || model.workerBusy { return "Preparing local speech" }
            if !model.modelVerified { return "Your model needs attention" }
            if model.dictationShortcut.isModifierOnly && !model.accessibilityAllowed { return "Allow access for your shortcut" }
            return model.shortcutAvailable ? "Ready to dictate" : "Choose an available shortcut"
        }
    }
    private var subtitle: String {
        switch model.phase {
        case .preparing: return model.isPracticeSession ? "Your words will appear in the practice area below." : "Your words will go to the text field you chose."
        case .recording: return model.mode == .hold ? "Release your shortcut to finish, or Escape to cancel." : "Press your shortcut again to finish, or Escape to cancel."
        case .transcribing: return model.isPracticeSession ? "Your practice words are finishing on this Mac." : "Keep your cursor in place while transcription finishes."
        case .recovery: return "Your words are still here. Review them before starting again."
        case .ready:
            if model.editingShortcut { return "Dictation is paused while the shortcut dialog is open." }
            if needsSetup { return "A few choices, then a little more room to think." }
            if !model.selectedInputAvailable { return "Reconnect your microphone, or choose an input below." }
            if model.modelBusy || model.workerBusy { return "Your microphone stays off while local speech gets ready." }
            if !model.modelVerified { return "Review your local model before you dictate." }
            if !model.shortcutAvailable { return "You can still use the Start button in Practice." }
            return practiceExpanded ? "Try a few words below, or choose a text field in another app." : "Choose a text field in another app, then use your shortcut."
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Brand(compact: true)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                        Text(subtitle)
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                    SessionStatusView(model: model)
                    if model.editingShortcut {
                        Button("Return to shortcut setup") { model.showSettings?() }.primaryAction()
                    }
                    if model.modelInstalled && !model.modelBusy && !model.modelVerified {
                        ModelPanel(model: model).withinSurface()
                    }
                    if needsSetup {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Local model & permissions").fontWeight(.semibold)
                                Text("Nothing records until you start.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Button("Continue setup") { model.showSetup?() }.primaryAction()
                        }.withinSurface()
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ShortcutControl(model: model)
                            Text(model.mode == .hold ? "Hold to talk. Release to finish." : "Press once to start. Press again to finish.")
                                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            Divider()
                            MicrophoneControls(model: model)
                        }.withinSurface()
                        if !model.accessibilityAllowed {
                            PermissionRow(title: "Accessibility", detail: "Allow insertion into other apps. Practice and Copy are available without it.", allowed: false, action: model.requestAccessibility)
                        }
                        if !model.shortcutAvailable && !(model.dictationShortcut.isModifierOnly && !model.accessibilityAllowed) {
                            Label("This shortcut is in use. Choose another in Settings or use the menu bar.", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(Palette.warning)
                        }
                    }
                    DisclosureGroup(isExpanded: Binding(get: { practiceExpanded }, set: togglePractice)) {
                        PracticeView(model: model, embedded: true).padding(.top, 14)
                    } label: {
                        Text("Try dictation").font(.system(size: 14, weight: .semibold))
                    }.id("practice")
                    Text("English · up to 5 minutes").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }.padding(30)
            }
            .onChange(of: practiceExpanded) { _, expanded in
                if expanded { proxy.scrollTo("practice", anchor: .top) }
            }
            .onAppear { if practiceExpanded { proxy.scrollTo("practice", anchor: .top) } }
            }
            PrivacyFooter()
        }.frame(minWidth: 500, minHeight: 490).background(Palette.canvas).foregroundStyle(Palette.text).tint(Palette.accent)
            .onAppear { model.refreshPermissions() }
    }
}

struct SessionStatusView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: model.phase == .recording ? "mic.fill" : model.phase == .recovery ? "text.bubble" : "mic.slash")
                .font(.system(size: 17)).foregroundStyle(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.phase == .recording ? (model.audioFlowing ? "Microphone on · \(Int(model.elapsed))s" : "Starting microphone…") : "Microphone off")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.message).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if model.phase == .recovery { Button("Review words") { model.showRecovery?() } }
            else if model.isActive { Button("Stop", action: model.stop); Button("Cancel", action: model.cancel) }
            else if model.workerBusy { ProgressView().controlSize(.small).accessibilityLabel("Finishing current work") }
        }.padding(15).background(Palette.tint.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    var done: () -> Void = {}
    @Binding var step: Int
    private let steps = ["Welcome", "Microphone", "Local speech", "Shortcut"]
    private var canContinue: Bool {
        if step == 1 { return model.microphoneAllowed && model.selectedInputAvailable }
        if step == 2 { return model.modelVerified && !model.modelBusy }
        return true
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: Double(step + 1), total: Double(steps.count))
                    .accessibilityLabel("Setup progress")
                    .accessibilityValue("Step \(step + 1) of \(steps.count): \(steps[step])")
                HStack {
                    Text(steps[step]).fontWeight(.medium)
                    Spacer()
                    Text("\(step + 1) of \(steps.count)")
                }
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if step == 0 {
                        Brand().padding(.vertical, 8)
                        heading("Your voice, on your Mac.", detail: "Dictate into the text field you choose. Let’s set up your microphone and a shortcut that feels right.")
                        VStack(alignment: .leading, spacing: 20) {
                            welcomeRow("desktopcomputer", title: "Transcribed here", detail: "One model download, then speech to text on your Mac.")
                            welcomeRow("mic", title: "You start every recording", detail: "Setup and permissions never turn on your microphone.")
                            welcomeRow("lock.shield", title: "No account. No dictation history.", detail: "Audio and words stay in memory. Copy is always your choice.")
                        }.withinSurface()
                    } else if step == 1 {
                        heading("Choose your microphone.", detail: "Use your Mac’s mic, a headset, or an external microphone. You can change this again before you practice.")
                        VStack(alignment: .leading, spacing: 16) {
                            MicrophoneControls(model: model)
                            Divider()
                            PermissionRow(title: "Microphone access", detail: "Lets Within hear you when you start dictation. Allowing access doesn’t start a recording.", allowed: model.microphoneAllowed, action: model.requestMicrophone)
                        }.withinSurface()
                        PermissionRow(title: "Type into other apps", detail: "Accessibility places words at your cursor and enables modifier-only shortcuts. You can practice with the Start button without it.", allowed: model.accessibilityAllowed, action: model.requestAccessibility)
                            .withinSurface()
                    } else if step == 2 {
                        heading(model.modelVerified ? "Local speech is ready." : "Keep transcription local.", detail: model.modelVerified ? "Your speech model is installed. You can dictate without an internet connection." : "Download the speech model once. Your recordings and transcripts aren’t sent to a transcription service.")
                        ModelPanel(model: model, allowRemoval: !model.modelVerified).withinSurface()
                    } else {
                        heading("Make the shortcut yours.", detail: "Choose a key and how it behaves. Then try a few words on Home.")
                        ActivationControls(model: model).withinSurface()
                        MicrophoneControls(model: model).withinSurface()
                        if !model.microphoneAllowed {
                            PermissionRow(title: "Microphone access", detail: "Allow access before starting Practice.", allowed: false, action: model.requestMicrophone)
                        } else if !model.modelVerified || model.modelBusy {
                            HStack {
                                Text("Local speech needs to be ready before you practice.").foregroundStyle(Palette.secondary)
                                Spacer()
                                Button("Review model") { step = 2 }
                            }
                        } else {
                            Label("Opening the practice area won’t start recording.", systemImage: "mic.slash")
                                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                    }
                }.font(.system(size: 13)).padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(spacing: 12) {
                if step < 3 {
                    Button { model.refreshPermissions(); step += 1 } label: {
                        Text(step == 0 ? "Get started" : "Continue").frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.primaryAction().disabled(!canContinue).keyboardShortcut(.defaultAction)
                } else {
                    Button { model.completeSetup(); done(); model.showPractice?() } label: {
                        Text("Try dictation").frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.primaryAction()
                        .disabled(!model.canStart).keyboardShortcut(.defaultAction)
                }
                HStack {
                    if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.link) }
                    Spacer()
                    if step == 3 { Button("Finish without practicing") { model.completeSetup(); done() }.buttonStyle(.link) }
                }.font(.system(size: 12))
            }.padding(.horizontal, 28).padding(.vertical, 20)
        }.frame(minWidth: 540, minHeight: 520).background(Palette.canvas).foregroundStyle(Palette.text).tint(Palette.accent)
            .onAppear { model.refreshPermissions() }
    }
    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.5).accessibilityAddTraits(.isHeader)
            Text(detail).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func welcomeRow(_ icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Palette.accent).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PracticeView: View {
    @ObservedObject var model: AppModel
    var embedded = false
    var done: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded { Text("Try your first words.").font(.system(size: 25, weight: .semibold)).tracking(-0.4) }
            Text(model.mode == .hold ? "With this practice area open and Within active, hold \(model.shortcutLabel), speak, then release. Or choose Start practice below." : "With this practice area open and Within active, press \(model.shortcutLabel) to start and again to finish. Or choose Start practice below.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
            if !embedded {
                MicrophoneControls(model: model)
                SessionStatusView(model: model)
            }
            ZStack(alignment: .topLeading) {
                if model.practiceText.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Try saying").font(.system(size: 11, weight: .medium))
                        Text("“A little more room to think.”").font(.system(size: 18))
                        Text("Your words will appear here when you finish.").font(.system(size: 12))
                    }.foregroundStyle(Palette.secondary).padding(.horizontal, 18).padding(.vertical, 20)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                TextEditor(text: $model.practiceText).font(.system(size: 16)).scrollContentBackground(.hidden)
                    .padding(12)
                    .accessibilityLabel("Practice text")
                    .accessibilityHint(model.practiceText.isEmpty ? "Try saying: A little more room to think. Your words appear here after you finish. Kept until you clear them or quit." : "Kept until you clear these words or quit.")
            }.frame(minHeight: 140).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
            HStack {
                if model.isActive && model.isPracticeSession {
                    Button("Stop and transcribe", action: model.stop).primaryAction()
                    Button("Cancel", action: model.cancel)
                } else {
                    Button("Start practice") { model.start(practice: true) }.primaryAction().disabled(!model.canStart)
                }
                Spacer()
                Button("Clear") { model.practiceText = "" }.disabled(model.practiceText.isEmpty || model.workerBusy)
                if !embedded { Button("Done", action: done).disabled(model.hasActivePracticeSession) }
            }
            Text("Practice stays here until you clear it or quit. No history is saved.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }.padding(embedded ? 0 : 28).frame(minWidth: embedded ? 0 : 540, minHeight: embedded ? 0 : 460).background(Palette.canvas).foregroundStyle(Palette.text).tint(Palette.accent)
    }
}

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    @FocusState private var copyFocused: Bool
    @State private var confirmingDiscard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Your words are here.", systemImage: "text.bubble").font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.accent)
            Text(model.recoveryDetail).font(.system(size: 13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(model.pendingText).textSelection(.enabled).font(.system(size: 16)).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.frame(minHeight: 120, maxHeight: 260).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line)).accessibilityLabel("Pending dictation")
            Text("Going back or closing Within’s window keeps these words available. A new dictation won’t replace them.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            HStack {
                Button("Return to \(model.targetName) and Insert", action: model.returnToOriginal)
                    .disabled(!model.canReturn || model.workerBusy)
                Spacer()
                Button("Copy", action: model.copyPending).primaryAction().focused($copyFocused)
                    .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.workerBusy || model.returning)
                Button("Discard…", role: .destructive) { confirmingDiscard = true }.disabled(model.workerBusy || model.returning)
            }
            Text("Copy uses your clipboard. Other apps, clipboard managers, and Universal Clipboard may read or sync these words.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }.padding(28).frame(minWidth: 565, minHeight: 420).background(Palette.canvas).foregroundStyle(Palette.text).tint(Palette.accent)
            .onAppear { copyFocused = true }
            .confirmationDialog("Discard these words?", isPresented: $confirmingDiscard) {
                Button("Discard words", role: .destructive, action: model.discard)
                Button("Keep words", role: .cancel) {}
            } message: { Text("This removes the pending dictation. It cannot be undone.") }
    }
}

struct PillView: View {
    static let width: CGFloat = 370
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.phase == .recording ? "mic.fill" : "waveform.path").foregroundStyle(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.phase == .recording ? (model.audioFlowing ? "Listening · \(Int(model.elapsed))s" : "Starting microphone…") : model.phase == .preparing ? "Preparing…" : "Finishing your words…")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if model.phase == .recording {
                    ProgressView(value: Double(model.level)).tint(Palette.accent).frame(width: 128).accessibilityLabel("Microphone level")
                } else { Text("Microphone off · on this Mac").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.phase == .recording {
                Button(action: model.stop) { Image(systemName: "stop.fill").frame(width: 22, height: 22) }
                    .help("Stop and transcribe").accessibilityLabel("Stop and transcribe")
            }
            Button(action: model.cancel) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                .help("Cancel dictation").accessibilityLabel("Cancel dictation")
        }.buttonStyle(.bordered).padding(16).frame(width: Self.width, height: 82)
            .background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line))
            .foregroundStyle(Palette.text)
    }
}

struct DiagnosticsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var saveMessage = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review diagnostics").font(.system(size: 24, weight: .semibold))
            Text("Nothing is sent automatically. This is the complete report that will be saved.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .frame(height: 330).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            if !saveMessage.isEmpty { Text(saveMessage).font(.system(size: 12)) }
            HStack {
                Button("Save report…") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "Within-diagnostics.json"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do { try text.write(to: url, atomically: true, encoding: .utf8); saveMessage = "Saved to the location you chose." }
                    catch { saveMessage = "The report couldn’t be saved. Choose another location and try again." }
                }.primaryAction()
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 530).background(Palette.canvas).foregroundStyle(Palette.text)
    }
}
