import AppKit
import SwiftUI
import WithinCore

enum Palette {
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.105, green: 0.12, blue: 0.11, alpha: 1)
            : NSColor(calibratedRed: 0.975, green: 0.97, blue: 0.955, alpha: 1)
    })
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.60, green: 0.82, blue: 0.72, alpha: 1)
            : NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.28, alpha: 1)
    })
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform.path").font(.system(size: 24)).foregroundStyle(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("within").font(.system(size: 26, weight: .medium, design: .serif))
                Text("by Made Ordinary").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State var section = "Dictation"
    @State private var showingDiagnostics = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 30) {
                Brand().padding(.top, 12)
                VStack(spacing: 6) {
                    navigation("Dictation", icon: "waveform")
                    navigation("Settings", icon: "slider.horizontal.3")
                    navigation("About", icon: "info.circle")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Label("On your Mac", systemImage: "lock.shield")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                    Text("No account. No history.\nA little more room to think.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    Text("ENGINEERING PREVIEW").font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary).padding(.top, 6)
                }
            }.padding(22).frame(width: 185).background(.primary.opacity(0.025))
            Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if section == "Dictation" { dictation }
                    else if section == "Settings" { settings }
                    else { about }
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 670)
        .background(Palette.canvas).tint(Palette.accent)
        .onAppear { model.refreshPermissions() }
        .sheet(isPresented: $showingDiagnostics) { DiagnosticsView(text: model.diagnostics()) }
    }
    private func navigation(_ name: String, icon: String) -> some View {
        Button { section = name } label: {
            Label(name, systemImage: icon).font(.system(size: 13, weight: section == name ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(section == name ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(section == name ? [.isSelected] : [])
    }
    private var dictation: some View {
        Group {
            VStack(alignment: .leading, spacing: 9) {
                Text("A little space for\nyour own words.").font(.system(size: 35, design: .serif)).fixedSize(horizontal: false, vertical: true)
                Text("Speak naturally. Within turns your voice into text, right where you’re writing.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
            }
            statusCard
            if !model.modelInstalled || !model.microphoneAllowed { setup }
            else {
                HStack(alignment: .top, spacing: 12) {
                    Text(model.shortcutLabel).font(.system(size: 15, weight: .medium, design: .monospaced))
                        .padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.mode == .hold ? "Hold to speak. Release to finish." : "Press to speak. Press again to finish.")
                            .font(.system(size: 13, weight: .medium))
                        Text("Choose a text field first. Your microphone is only on while you dictate.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if !model.accessibilityAllowed {
                    permissionRow(title: "Put words where you’re writing", detail: "Allow Accessibility for direct insertion. You can still practice and copy text without it.", allowed: false, action: model.requestAccessibility)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("TRY A FEW WORDS").font(.system(size: 10, weight: .semibold)).tracking(1)
                        Spacer()
                        if !model.practiceText.isEmpty { Button("Clear") { model.practiceText = "" }.buttonStyle(.link).font(.system(size: 11)) }
                    }
                    TextEditor(text: $model.practiceText).font(.system(size: 15)).scrollContentBackground(.hidden)
                        .padding(10).frame(height: 105).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            if model.practiceText.isEmpty { Text("What’s on your mind?").font(.system(size: 14, design: .serif)).foregroundStyle(.tertiary).padding(16).allowsHitTesting(false).accessibilityHidden(true) }
                        }.accessibilityLabel("Practice text, kept only until you quit")
                    HStack {
                        if model.isActive {
                            Button("Stop and transcribe", action: model.stop).buttonStyle(PrimaryActionStyle())
                            Button("Cancel", action: model.cancel)
                        } else {
                            Button { model.start(practice: true) } label: { Label("Start practice", systemImage: "mic") }
                                .buttonStyle(PrimaryActionStyle()).disabled(!model.canStart)
                        }
                        Spacer()
                        Text("English · up to 5 minutes").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            privacyFooter
        }
    }
    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.phase == .recording ? "mic.fill" : "waveform.path").font(.system(size: 19)).foregroundStyle(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.message).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(model.phase == .recording ? "Microphone on · \(Int(model.elapsed))s" : "Microphone off")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.phase == .recovery { Button("Review words") { model.showRecovery?() }.controlSize(.small) }
            else if model.workerBusy && !model.isActive { Button("Cancel", action: model.cancel).controlSize(.small) }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Make yourself at home.").font(.system(size: 21, design: .serif))
            modelRow
            Divider()
            permissionRow(title: "Choose when the microphone is on", detail: "Allow microphone access, then start a practice recording when you’re ready.", allowed: model.microphoneAllowed, action: model.requestMicrophone)
            permissionRow(title: "Write into other apps", detail: "Accessibility lets Within insert into the text field you chose. Optional for practice and Copy.", allowed: model.accessibilityAllowed, action: model.requestAccessibility)
            Button("Check permissions", action: model.refreshPermissions).buttonStyle(.link).font(.system(size: 11))
        }
    }
    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Parakeet, on this Mac", systemImage: "internaldrive").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.modelInstalled { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent).accessibilityLabel("Installed") }
            }
            Text(model.modelMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            if model.modelBusy {
                if model.modelDownloading {
                    ProgressView(value: model.downloadProgress).accessibilityLabel("Model download progress")
                    Button("Cancel download", action: model.cancelDownload).controlSize(.small)
                } else { ProgressView().controlSize(.small).accessibilityLabel("Preparing local model") }
            } else if !model.modelInstalled {
                Text("Download 632 MB from Hugging Face. This shares your IP address with the model host. Once installed, transcription runs offline.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2)
                Button("Download local model", action: model.downloadModel).buttonStyle(PrimaryActionStyle())
            } else {
                Button("Remove model from this Mac…") { showingRemove = true }.controlSize(.small).disabled(model.workerBusy || model.phase != .ready)
            }
        }.confirmationDialog("Remove the local speech model? You’ll need to download it again to dictate.", isPresented: $showingRemove) {
            Button("Remove model", role: .destructive, action: model.removeModel)
        }
    }
    @State private var showingRemove = false
    private func permissionRow(title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle").foregroundStyle(allowed ? Palette.accent : .secondary).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !allowed { Button("Allow…", action: action).controlSize(.small) }
                else { Text("Allowed").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            }
        }
    }
    private var settings: some View {
        Group {
            Text("Make it yours.").font(.system(size: 32, design: .serif))
            VStack(alignment: .leading, spacing: 13) {
                Text("Activation").font(.headline)
                Picker("Recording gesture", selection: $model.mode) {
                    Text("Hold to talk").tag(ActivationMode.hold)
                    Text("Press to start / stop").tag(ActivationMode.toggle)
                }.pickerStyle(.segmented).disabled(model.workerBusy)
                Text("Toggle mode works without holding a key. You can also use Start Dictation and Stop from the menu bar.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("Shortcut", selection: $model.alternateShortcut) {
                    Text("Control + Shift + Space").tag(false)
                    Text("Control + Shift + D").tag(true)
                }.disabled(model.workerBusy)
                if !model.shortcutAvailable { Text("This shortcut is unavailable. Choose the other shortcut or use the menu bar.").font(.system(size: 12)).foregroundStyle(.red) }
                Text("Escape cancels. Recording stops at five minutes.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Microphone").font(.headline)
                Picker("Input", selection: $model.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(model.devices) { Text($0.name).tag($0.id) }
                    if !model.microphoneUID.isEmpty && !model.devices.contains(where: { $0.id == model.microphoneUID }) { Text("Selected microphone unavailable").tag(model.microphoneUID) }
                }.disabled(model.workerBusy)
                Button("Refresh devices and permissions", action: model.refreshPermissions).controlSize(.small)
                permissionRow(title: "Microphone access", detail: "Only used when you explicitly start dictation.", allowed: model.microphoneAllowed, action: model.requestMicrophone)
                permissionRow(title: "Accessibility access", detail: "Used to insert into the original text field and observe focus changes.", allowed: model.accessibilityAllowed, action: model.requestAccessibility)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Everyday use").font(.headline)
                Toggle("Start Within at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLaunchAtLogin))
                if !model.loginMessage.isEmpty { Text(model.loginMessage).font(.system(size: 11)).foregroundStyle(.secondary) }
                Toggle("Play start and stop sounds", isOn: $model.soundsEnabled)
            }
            Divider()
            modelRow
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Privacy").font(.headline)
                Text("Audio and text stay in memory. There is no dictation history, account, analytics, cloud transcription, or automatic update check. Copy is always your choice.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                Toggle("Compatibility paste · experimental", isOn: $model.compatibilityPaste).disabled(model.workerBusy)
                Text("Off by default. When a safe original field reports that direct insertion is unavailable, this uses your clipboard and a paste shortcut. Other apps and Universal Clipboard may observe the text. Within tries to restore your clipboard, then asks you to check the result. Unknown or protected fields still open recovery.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var about: some View {
        Group {
            Brand()
            Text("Nothing crosses a boundary\nwithout your choice.").font(.system(size: 30, design: .serif)).fixedSize(horizontal: false, vertical: true)
            Text("A free, open-source place for your voice. This first release is focused on Dictation: turning spoken English into text, locally on your Mac.")
                .font(.system(size: 14)).lineSpacing(4)
            Text("Engineering preview · 0.1.0").font(.system(size: 12, weight: .semibold))
            Text("This build is for local evaluation. macOS 14/15 compatibility, real-app insertion, VoiceOver, baseline hardware performance, and release signing still need hands-on validation.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            Divider()
            Text("Made with open tools").font(.headline)
            Text("Within app code: MIT. FluidAudio: Apache 2.0. NVIDIA Parakeet TDT 0.6B v3 model: CC BY 4.0; Core ML conversion by Fluid Inference. Model weights are a separate optional download.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            Link("FluidAudio source & license", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
            Link("Parakeet model & attribution", destination: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")!)
            Button("Review diagnostics…") { showingDiagnostics = true }
            Text("Diagnostics contain only versions, permission categories, model status, and error codes. You can review the report before saving it.").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Opening these links uses your browser and connects to the listed websites.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var privacyFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Nothing crosses a boundary without your choice.").font(.system(size: 11, weight: .medium))
                Text("Local transcription. No recordings or dictation history saved.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    @FocusState private var copyFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Your words are here.", systemImage: "text.bubble").font(.system(size: 25, design: .serif)).foregroundStyle(Palette.accent)
            Text(model.recoveryDetail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView { Text(model.pendingText).textSelection(.enabled).font(.system(size: 17, design: .serif)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).padding(18) }
                .frame(minHeight: 120, maxHeight: 260).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Pending dictation")
            Text("Kept here until you choose an action or quit. A new dictation won’t replace these words.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                if model.canReturn { Button("Return to \(model.targetName) and Insert", action: model.returnToOriginal).buttonStyle(PrimaryActionStyle()).disabled(model.workerBusy) }
                Spacer()
                Button("Copy", action: model.copyPending).focused($copyFocused).keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.workerBusy || model.returning)
                Button("Discard", action: model.discard).disabled(model.workerBusy || model.returning)
            }
            Text("Copy places your words on the clipboard. Other apps, clipboard managers, and Universal Clipboard may read or sync them.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(28).frame(width: 565).background(Palette.canvas).tint(Palette.accent)
            .onAppear { copyFocused = true }
    }
}

struct PillView: View {
    static let width: CGFloat = 340
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.phase == .recording ? "mic.fill" : "waveform.path").foregroundStyle(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.phase == .recording ? (model.audioFlowing ? "Listening · \(Int(model.elapsed))s" : "Starting microphone…") : model.phase == .preparing ? "Preparing…" : "Finishing your words…")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                if model.phase == .recording {
                    ProgressView(value: Double(model.level)).tint(Palette.accent).frame(width: 128).accessibilityLabel("Microphone level")
                } else { Text("Microphone off · on this Mac").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            if model.phase == .recording { Button(action: model.stop) { Image(systemName: "stop.fill").frame(width: 28, height: 28) }.help("Stop and transcribe").accessibilityLabel("Stop and transcribe") }
            Button(action: model.cancel) { Image(systemName: "xmark").frame(width: 28, height: 28) }.help("Cancel dictation").accessibilityLabel("Cancel dictation")
        }.buttonStyle(.plain).padding(16).frame(width: Self.width)
            .background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.15)))
    }
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.canvas).padding(.horizontal, 14).padding(.vertical, 9)
            .background(Palette.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DiagnosticsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var saveMessage = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review diagnostics").font(.system(size: 24, design: .serif))
            Text("Nothing is sent automatically. This is the complete report that will be saved.").font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .frame(height: 330).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if !saveMessage.isEmpty { Text(saveMessage).font(.system(size: 12)) }
            HStack {
                Button("Save report…") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "Within-diagnostics.json"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do { try text.write(to: url, atomically: true, encoding: .utf8); saveMessage = "Saved to the location you chose." }
                    catch { saveMessage = "The report couldn’t be saved. Choose another location and try again." }
                }.buttonStyle(PrimaryActionStyle())
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 530).background(Palette.canvas)
    }
}
