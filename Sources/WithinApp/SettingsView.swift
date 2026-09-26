import SwiftUI
import WithinCore

struct ActivationControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Recording gesture", selection: $model.mode) {
                Text("Hold to talk").tag(ActivationMode.hold)
                Text("Press to start / stop").tag(ActivationMode.toggle)
            }.pickerStyle(.segmented).disabled(model.workerBusy || model.phase != .ready)
            Text(model.mode == .hold ? "Hold the shortcut while speaking. Release to finish." : "Press once to start and again to finish. No need to hold the keys.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Picker("Shortcut", selection: $model.alternateShortcut) {
                Text("Control + Shift + Space").tag(false)
                Text("Control + Shift + D").tag(true)
            }.disabled(model.workerBusy || model.phase != .ready)
            if !model.shortcutAvailable {
                Label("Shortcut unavailable. Choose the other option or use the menu bar.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Palette.warning)
            }
            Text("Escape cancels. Recording stops at five minutes.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State var selection = "General"
    @State private var pasteDisclosure = false
    @State private var showingDiagnostics = false
    var body: some View {
        TabView(selection: $selection) {
            page {
                heading("Your everyday rhythm", detail: "Choose how you start and finish dictation.")
                ActivationControls(model: model).withinSurface()
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Start Within at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLaunchAtLogin))
                    if !model.loginMessage.isEmpty { Text(model.loginMessage).font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                    Toggle("Play start and stop sounds", isOn: $model.soundsEnabled)
                }.withinSurface()
                Text("Closing Home keeps Within available in the Dock and menu bar. Quit Within exits the app completely.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag("General")
            page {
                heading("Your microphone", detail: "Choose an input. Within never silently switches it during dictation.")
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Input", selection: $model.microphoneUID) {
                        Text("System default").tag("")
                        ForEach(model.devices) { Text($0.name).tag($0.id) }
                        if !model.microphoneUID.isEmpty && !model.selectedInputAvailable { Text("Selected microphone unavailable").tag(model.microphoneUID) }
                    }.disabled(model.workerBusy || model.phase != .ready)
                    if !model.selectedInputAvailable {
                        Label("Reconnect your microphone or deliberately choose another input.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Palette.warning)
                    }
                    Button("Refresh devices & permissions", action: model.refreshPermissions)
                }.withinSurface()
                VStack(alignment: .leading, spacing: 18) {
                    PermissionRow(title: "Microphone", detail: "Used only after you start dictation.", allowed: model.microphoneAllowed, action: model.requestMicrophone)
                    Divider()
                    PermissionRow(title: "Accessibility", detail: "Inserts into your original field and checks focus. Optional for practice and Copy.", allowed: model.accessibilityAllowed, action: model.requestAccessibility)
                }.withinSurface()
            }.tabItem { Label("Audio", systemImage: "mic") }.tag("Audio")
            page {
                heading("Your words stay with you", detail: "Nothing crosses a boundary without your choice.")
                VStack(alignment: .leading, spacing: 15) {
                    Label("On-device transcription", systemImage: "desktopcomputer")
                    Label("No recordings or dictation history saved", systemImage: "clock.badge.xmark")
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
            }.tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("Privacy")
            page {
                heading("One local speech model", detail: "Prepare it once. Dictate without a network connection.")
                ModelPanel(model: model).withinSurface()
            }.tabItem { Label("Model", systemImage: "internaldrive") }.tag("Model")
            page {
                Brand()
                Text("A little more room to think.").font(.system(size: 22, weight: .semibold))
                Text("Within, by Made Ordinary\nEngineering preview · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                Text("A free, open-source Mac app for local English dictation. This build is for local evaluation; release signing, supported-system and broader app compatibility checks remain pending.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Divider()
                Text("Within: MIT · FluidAudio: Apache 2.0\nParakeet TDT v3: CC BY 4.0\nCore ML conversion by Fluid Inference")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Link("Source & app license ↗", destination: URL(string: "https://github.com/madeordinary/within")!)
                Link("FluidAudio source & license ↗", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
                Text("Links open in your browser. Within does not check for updates automatically.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Button("Review diagnostics…") { showingDiagnostics = true }
                Text("Review content-free status and error information before choosing to save a report. Nothing is sent automatically.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.tabItem { Label("About", systemImage: "info.circle") }.tag("About")
        }.padding(16).frame(minWidth: 600, minHeight: 560).background(Palette.canvas).foregroundStyle(Palette.text).tint(Palette.accent)
            .onAppear { model.refreshPermissions() }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsView(text: model.diagnostics()) }
            .confirmationDialog("Enable compatibility paste?", isPresented: $pasteDisclosure) {
                Button("Enable compatibility paste") { model.compatibilityPaste = true }
                Button("Keep it off", role: .cancel) {}
            } message: {
                Text("Your words will temporarily enter the clipboard. Other apps, clipboard managers, and Universal Clipboard may read or sync them. Clipboard restoration is best effort; you must review the insertion result.")
            }
    }
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 22, content: content).font(.system(size: 13)).padding(22).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 23, weight: .semibold)).tracking(-0.4)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }
}

struct HelpView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("A little help with Within.").font(.system(size: 25, weight: .semibold))
                help("Start with your cursor", icon: "cursorarrow", text: "Choose an editable field in another app, then use \(model.shortcutLabel). \(model.mode == .hold ? "Hold while speaking and release to finish." : "Press once to start and again to finish.") Escape cancels without transcribing.")
                help("Try it here first", icon: "waveform", text: "Practice stays in its own temporary field. Opening practice does not record; choose Start practice or use the shortcut while that window is active.")
                Button("Open Practice") { model.showPractice?() }.disabled(model.workerBusy)
                help("When words need review", icon: "text.bubble", text: "If the destination changes or insertion is uncertain, Within keeps your words for review. Return rechecks the original field. Copy uses the clipboard only when you choose it. Closing recovery keeps pending words in memory; Discard removes them after confirmation.")
                help("Check the selected microphone", icon: "mic", text: "If an input disappears, reconnect it or choose another in Settings → Audio. Within does not switch devices or restart capture silently.")
                help("Close is different from Quit", icon: "macwindow", text: "Closing Home leaves Within in the Dock and menu bar with shortcuts available. Open it again from either place. Command-comma opens Settings. Quit Within exits completely and asks before discarding active or pending dictation.")
                help("Made to stay local", icon: "lock.shield", text: "The speech model is a separate, explicit download. Dictation itself runs on your Mac. No recordings or dictation history are saved. This engineering preview has no automatic updater.")
            }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 540, minHeight: 480).background(Palette.canvas).foregroundStyle(Palette.text).tint(Palette.accent)
    }
    private func help(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(3)
        }
    }
}
