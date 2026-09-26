import AppKit
import SwiftUI
import WithinCore
import Darwin
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    private var model: AppModel!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var practiceWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var recoveryWindow: NSWindow?
    private var pill: NSPanel?
    private var statusItem: NSStatusItem?
    private var actionItem: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var reviewItem: NSMenuItem?
    private var localKeyMonitor: Any?
    private var lockDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do {
            let base = try applicationDirectory()
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lockDescriptor = open(base.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.madeordinary.Within").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?.activate()
                NSApp.terminate(nil); return
            }
            model = AppModel(manifest: try loadManifest(), base: base)
            model.showMain = { [weak self] in self?.showMainWindow() }
            model.showSettings = { [weak self] in self?.showSettingsWindow() }
            model.showAudioSettings = { [weak self] in self?.showSettingsWindow(section: "Audio") }
            model.showModelSettings = { [weak self] in self?.showSettingsWindow(section: "Model") }
            model.showHelp = { [weak self] in self?.showHelpWindow() }
            model.showSetup = { [weak self] in self?.showSetupWindow() }
            model.showPractice = { [weak self] in self?.showPracticeWindow() }
            model.practiceWindowIsActive = { [weak self] in NSApp.isActive && self?.practiceWindow?.isKeyWindow == true }
            model.showRecovery = { [weak self] in self?.showRecoveryWindow() }
            model.dismissRecovery = { [weak self] in self?.recoveryWindow?.orderOut(nil) }
            model.stateChanged = { [weak self] in self?.refreshStatus() }
            makeMenu()
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.model.phase != .ready else { return event }
                guard NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return event }
                if self.model.phase == .recovery {
                    guard Self.canHideRecovery(for: event.window, recovery: self.recoveryWindow) else { return event }
                    self.recoveryWindow?.orderOut(nil)
                }
                else { self.model.cancel(cause: .escape) }
                return nil
            }
            refreshStatus()
            let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
            if !loginLaunch || !model.setupComplete { showMainWindow() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Within couldn’t start."; alert.informativeText = "The app resources or local support folder are unavailable. Rebuild or reinstall the app and try again."; alert.runModal()
            NSApp.terminate(nil)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.phase != .ready {
            let alert = NSAlert(); alert.messageText = "Quit and discard this dictation?"
            alert.informativeText = "Within doesn’t save recordings or pending words. Anything waiting here will be discarded."
            alert.addButton(withTitle: "Keep Within open"); alert.addButton(withTitle: "Quit and discard")
            if runConfirmation(alert) != .alertSecondButtonReturn { return .terminateCancel }
        }
        model.shutdown(); return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }
    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Within")
        let menu = NSMenu(); menu.autoenablesItems = false
        let title = NSMenuItem(title: "Within, by Made Ordinary", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        actionItem = item("Start Dictation", #selector(toggleDictation)); menu.addItem(actionItem!)
        cancelItem = item("Cancel Dictation", #selector(cancelDictation)); menu.addItem(cancelItem!)
        reviewItem = item("Review Pending Words…", #selector(reviewWords)); menu.addItem(reviewItem!)
        menu.addItem(.separator()); menu.addItem(item("Open Within…", #selector(openWithin)))
        menu.addItem(.separator()); menu.addItem(item("Quit Within", #selector(quit)))
        statusItem?.menu = menu
        menu.insertItem(item("Settings…", #selector(openSettings)), at: menu.numberOfItems - 2)
        menu.insertItem(item("Within Help", #selector(openHelp)), at: menu.numberOfItems - 2)
        makeApplicationMenu()
    }
    private func makeApplicationMenu() {
        let menu = NSMenu()
        let root = NSMenuItem(title: "Within", action: nil, keyEquivalent: "")
        let application = NSMenu(title: "Within"); root.submenu = application
        application.addItem(item("About Within", #selector(openAbout)))
        application.addItem(.separator())
        application.addItem(item("Settings…", #selector(openSettings), key: ","))
        application.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services"); application.addItem(services); NSApp.servicesMenu = services.submenu
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: "Hide Within", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]; application.addItem(hideOthers)
        application.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        application.addItem(.separator()); application.addItem(item("Quit Within", #selector(quit), key: "q")); menu.addItem(root)
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(item("Open Within", #selector(openWithin), key: "0"))
        file.submenu?.addItem(item("Practice Dictation…", #selector(openPractice)))
        file.submenu?.addItem(item("Set Up Within…", #selector(openSetup)))
        file.submenu?.addItem(.separator())
        file.submenu?.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")); menu.addItem(file)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); edit.submenu = NSMenu(title: "Edit")
        for (name, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(NSMenuItem(title: name, action: selector, keyEquivalent: key))
        }
        menu.addItem(edit)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); let windows = NSMenu(title: "Window"); windowItem.submenu = windows
        windows.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windows.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windows.addItem(.separator()); windows.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        menu.addItem(windowItem); NSApp.windowsMenu = windows
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: ""); help.submenu = NSMenu(title: "Help")
        help.submenu?.addItem(item("Within Help", #selector(openHelp), key: "?")); menu.addItem(help); NSApp.helpMenu = help.submenu
        NSApp.mainMenu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    @objc private func toggleDictation() { if model.isActive { model.stop() } else { model.startFromCurrentWindow() } }
    @objc private func cancelDictation() { model.cancel() }
    @objc private func reviewWords() { showRecoveryWindow() }
    @objc private func openWithin() { showMainWindow() }
    @objc private func openSettings() { showSettingsWindow() }
    @objc private func openAbout() { showSettingsWindow(section: "About") }
    @objc private func openHelp() { showHelpWindow() }
    @objc private func openSetup() { showSetupWindow() }
    @objc private func openPractice() { showPracticeWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func makeWindow<V: View>(_ title: String, size: NSSize, minimum: NSSize, autosave: String, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.minSize = minimum
        window.contentView = NSHostingView(rootView: view); window.delegate = self
        window.center(); window.setFrameAutosaveName(autosave)
        return window
    }
    private func present(_ window: NSWindow?) {
        model.refreshPermissions()
        let destination = Self.presentationWindow(requested: window, windows: NSApp.orderedWindows)
        let parent = destination?.sheetParent ?? destination
        if parent?.isMiniaturized == true { parent?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        parent?.orderFront(nil)
        destination?.makeKeyAndOrderFront(nil)
    }
    /// Reopening the app must not put Home in front of an unfinished sheet.
    /// In particular, shortcut editing intentionally pauses every dictation path.
    static func presentationWindow(requested: NSWindow?, windows: [NSWindow]) -> NSWindow? {
        guard let owner = windows.first(where: { $0.attachedSheet != nil }) else { return requested }
        var destination = owner
        while let sheet = destination.attachedSheet { destination = sheet }
        return destination
    }
    private func showMainWindow() {
        guard model != nil else { return }
        if mainWindow == nil {
            let window = makeWindow("Within", size: NSSize(width: 560, height: 570), minimum: NSSize(width: 530, height: 540), autosave: "Within.Home.v2", view: MainView(model: model))
            let toolbar = NSToolbar(identifier: "Within.HomeToolbar"); toolbar.delegate = self
            toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
            window.toolbar = toolbar; window.toolbarStyle = .unified
            mainWindow = window
        }
        present(mainWindow)
    }
    private func showSettingsWindow(section: String? = nil) {
        if let section { model.settingsSection = section }
        if settingsWindow == nil {
            settingsWindow = makeWindow("Within Settings", size: NSSize(width: 640, height: 630), minimum: NSSize(width: 620, height: 590), autosave: "Within.Settings.v2", view: SettingsView(model: model))
        }
        present(settingsWindow)
    }
    private func showHelpWindow() {
        if helpWindow == nil {
            helpWindow = makeWindow("Within Help", size: NSSize(width: 600, height: 590), minimum: NSSize(width: 560, height: 520), autosave: "Within.Help.v2", view: HelpView(model: model))
        }
        present(helpWindow)
    }
    private func showSetupWindow() {
        if setupWindow == nil {
            setupWindow = makeWindow("Set Up Within", size: NSSize(width: 540, height: 650), minimum: NSSize(width: 540, height: 600), autosave: "Within.Setup.v3", view: SetupView(model: model, done: { [weak self] in self?.setupWindow?.close() }))
        }
        present(setupWindow)
    }
    private func showPracticeWindow() {
        if practiceWindow == nil {
            practiceWindow = makeWindow("Practice · Within", size: NSSize(width: 600, height: 510), minimum: NSSize(width: 560, height: 500), autosave: "Within.Practice.v2", view: PracticeView(model: model, done: { [weak self] in self?.practiceWindow?.performClose(nil) }))
        }
        present(practiceWindow)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === practiceWindow, model.hasActivePracticeSession else { return true }
        let closingSessionID = model.session.id
        let alert = NSAlert(); alert.messageText = "Cancel this practice recording?"
        alert.informativeText = "Closing now cancels the current recording or transcription. Earlier practice text stays available until you clear it or quit."
        alert.addButton(withTitle: "Keep practicing"); alert.addButton(withTitle: "Cancel and close")
        guard runConfirmation(alert) == .alertSecondButtonReturn else { return false }
        // The worker can finish while a native confirmation is open.
        if model.shouldCancelPracticeOnClose(sessionID: closingSessionID) { model.cancel() }
        return true
    }
    static func canHideRecovery(for eventWindow: NSWindow?, recovery: NSWindow?) -> Bool {
        guard let recovery, eventWindow === recovery, recovery.attachedSheet == nil else { return false }
        return true
    }
    private func runConfirmation(_ alert: NSAlert) -> NSApplication.ModalResponse {
        model.suspendEscapeShortcut()
        defer { model.resumeEscapeShortcut() }
        return alert.runModal()
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("Within.Help"), .init("Within.Settings")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier.rawValue == "Within.Help" || identifier.rawValue == "Within.Settings" else { return nil }
        let help = identifier.rawValue == "Within.Help"
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = help ? "Help" : "Settings"; item.toolTip = help ? "Within Help" : "Settings (⌘,)"
        item.image = NSImage(systemSymbolName: help ? "questionmark.circle" : "gearshape", accessibilityDescription: item.label)
        item.target = self; item.action = help ? #selector(openHelp) : #selector(openSettings); item.isBordered = true
        return item
    }
    private func showRecoveryWindow() {
        guard model.phase == .recovery else { return }
        if recoveryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.minSize = NSSize(width: 605, height: 475); window.title = "Your words · Within"; window.isReleasedWhenClosed = false; window.level = .floating
            window.contentView = NSHostingView(rootView: RecoveryView(model: model)); window.center(); window.delegate = self
            recoveryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); recoveryWindow?.makeKeyAndOrderFront(nil)
    }
    private func refreshStatus() {
        let active = model.phase == .preparing || model.phase == .recording || model.phase == .transcribing
        statusItem?.button?.image = NSImage(systemSymbolName: model.phase == .recording ? "mic.fill" : "waveform", accessibilityDescription: model.phase == .recording ? "Within. Microphone on." : "Within. Microphone off.")
        statusItem?.button?.toolTip = model.phase == .recording ? "Within · recording" : "Within · microphone off"
        actionItem?.title = model.isActive ? "Stop and Transcribe" : "Start Dictation"
        actionItem?.isEnabled = model.isActive || model.canStart
        cancelItem?.isEnabled = active
        reviewItem?.isHidden = model.phase != .recovery
        if active {
            if pill == nil {
                let panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: PillView.width, height: 82), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.hidesOnDeactivate = false
                panel.contentView = NSHostingView(rootView: PillView(model: model)); pill = panel
            }
            if let frame = NSScreen.main?.visibleFrame { pill?.setFrameOrigin(NSPoint(x: frame.midX - PillView.width / 2, y: frame.minY + 28)) }
            pill?.orderFrontRegardless()
        } else { pill?.orderOut(nil) }
    }
}

func loadManifest() throws -> ModelManifest {
    guard let url = Bundle.module.url(forResource: "model-manifest", withExtension: "json") else { throw IntegrityError.missing }
    let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url)); try manifest.validate(); return manifest
}
func applicationDirectory() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Within", isDirectory: true)
}

final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
