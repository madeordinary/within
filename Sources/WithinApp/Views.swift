import AppKit
import SwiftUI
import WithinCore

struct MainView: View {
    @ObservedObject var model: AppModel
    private var needsSetup: Bool { !model.modelInstalled || !model.microphoneAllowed }
    private var title: String {
        switch model.phase {
        case .preparing: return "Getting ready to listen"
        case .recording: return model.audioFlowing ? "Listening to you" : "Starting your microphone"
        case .transcribing: return "Finishing your words"
        case .recovery: return "Your words are waiting"
        case .ready:
            if needsSetup { return "Make yourself at home" }
            if !model.selectedInputAvailable { return "Your microphone is unavailable" }
            if model.modelBusy || model.workerBusy { return "Preparing local speech" }
            if !model.modelVerified { return "Your model needs attention" }
            return model.shortcutAvailable ? "Ready to dictate" : "Choose an available shortcut"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Brand().padding(.bottom, 6)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                        Text(needsSetup ? "A few choices, then a little more room to think." : "Choose a text field in another app. Your words will follow.")
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                    SessionStatusView(model: model)
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
                        VStack(spacing: 0) {
                            HStack(alignment: .center, spacing: 15) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.mode == .hold ? "Hold to talk" : "Press to start / stop").font(.system(size: 13, weight: .semibold))
                                    Text(model.mode == .hold ? "Release the keys to finish." : "Press again when you’re done.")
                                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                Text(model.shortcutLabel).font(.system(size: 15, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 12).padding(.vertical, 9).background(Palette.tint, in: RoundedRectangle(cornerRadius: 8))
                                    .accessibilityLabel("Shortcut: \(model.alternateShortcut ? "Control Shift D" : "Control Shift Space")")
                            }
                            Divider().padding(.vertical, 17)
                            HStack(spacing: 12) {
                                Image(systemName: "mic").foregroundStyle(Palette.secondary).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.selectedInputName).font(.system(size: 13, weight: .medium))
                                    Text(model.selectedInputAvailable ? "Selected microphone" : "Reconnect it or choose another in Settings.")
                                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                Button("Change…") { model.showAudioSettings?() }
                            }
                        }.withinSurface()
                        if !model.accessibilityAllowed {
                            PermissionRow(title: "Accessibility", detail: "Allow insertion into other apps. Practice and Copy are available without it.", allowed: false, action: model.requestAccessibility)
                        }
                        if !model.shortcutAvailable {
                            Label("This shortcut is in use. Choose another in Settings or use the menu bar.", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(Palette.warning)
                        }
                        HStack {
                            Button("Try dictation") { model.showPractice?() }.primaryAction().disabled(!model.canStart)
                            Spacer()
                            Text("English · up to 5 minutes").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                    }
                }.padding(30)
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
    @State var step = 0
    private let steps = ["Welcome", "Permissions", "Local model", "Ready"]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Set up Within").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(step + 1) of 4 · \(steps[step])").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if step == 0 {
                        Brand()
                        Text("Your voice. Your Mac.").font(.system(size: 27, weight: .semibold))
                        Text("Within turns speech into text in the field you choose. Transcription runs locally after one model download.")
                        Label("You choose when recording starts.", systemImage: "mic")
                        Label("No account or dictation history.", systemImage: "lock.shield")
                        Label("Copy and clipboard use stay your choice.", systemImage: "doc.on.clipboard")
                    } else if step == 1 {
                        Text("A separate choice for each permission.").font(.system(size: 23, weight: .semibold))
                        PermissionRow(title: "Microphone", detail: "Needed to transcribe your voice. Granting access does not start recording.", allowed: model.microphoneAllowed, action: model.requestMicrophone)
                        Divider()
                        PermissionRow(title: "Accessibility", detail: "Inserts into your chosen text field. Optional for practice and explicit Copy.", allowed: model.accessibilityAllowed, action: model.requestAccessibility)
                        Button("Check permissions", action: model.refreshPermissions)
                    } else if step == 2 {
                        Text("A small download. A local voice.").font(.system(size: 23, weight: .semibold))
                        ModelPanel(model: model, allowRemoval: !model.modelVerified).withinSurface()
                    } else {
                        Text("Make the shortcut yours.").font(.system(size: 23, weight: .semibold))
                        ActivationControls(model: model)
                        Text("Start with a practice recording, or choose a text field in another app and use your shortcut. Opening practice doesn’t record.")
                            .foregroundStyle(Palette.secondary)
                        if !model.selectedInputAvailable {
                            Label("Choose an available microphone in Settings before recording.", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warning)
                            Button("Open Settings…") { model.showAudioSettings?() }
                        }
                    }
                }.font(.system(size: 13)).padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 3 {
                    Button("Continue") { step += 1 }.primaryAction()
                        .disabled((step == 1 && !model.microphoneAllowed) || (step == 2 && (!model.modelVerified || model.modelBusy)))
                } else {
                    Button("Done") { model.completeSetup(); done() }
                    Button("Try dictation") { model.completeSetup(); done(); model.showPractice?() }.primaryAction().disabled(!model.canStart)
                }
            }.padding(24)
        }.frame(minWidth: 540, minHeight: 520).background(Palette.canvas).foregroundStyle(Palette.text).tint(Palette.accent)
    }
}

struct PracticeView: View {
    @ObservedObject var model: AppModel
    var done: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("A few words to try.").font(.system(size: 25, weight: .semibold)).tracking(-0.4)
            Text("Start here, or use \(model.shortcutLabel) while this window is active. Your practice stays here until you clear it or quit.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
            SessionStatusView(model: model)
            TextEditor(text: $model.practiceText).font(.system(size: 16)).scrollContentBackground(.hidden)
                .padding(12).frame(minHeight: 140).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
                .accessibilityLabel("Practice text, kept only until you quit")
            HStack {
                if model.isActive && model.isPracticeSession {
                    Button("Stop and transcribe", action: model.stop).primaryAction()
                    Button("Cancel", action: model.cancel)
                } else {
                    Button("Start practice") { model.start(practice: true) }.primaryAction().disabled(!model.canStart)
                }
                Spacer()
                Button("Clear") { model.practiceText = "" }.disabled(model.practiceText.isEmpty || model.workerBusy)
                Button("Done", action: done).disabled(model.hasActivePracticeSession)
            }
            Text("English · up to 5 minutes · no history saved").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }.padding(28).frame(minWidth: 540, minHeight: 460).background(Palette.canvas).foregroundStyle(Palette.text).tint(Palette.accent)
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
            Text("Closing this window keeps these words available. A new dictation won’t replace them.")
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
