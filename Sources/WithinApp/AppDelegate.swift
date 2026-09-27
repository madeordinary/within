import AppKit
import SwiftUI
import WithinCore
import Darwin
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private var model: AppModel!
    private var mainWindow: NSWindow?
    private let navigation = AppNavigation()
    private var deferredRecovery = false
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
            model.practiceAreaIsActive = { [weak self] in
                guard let self else { return false }
                return Self.practiceIsActive(navigation: navigation, windowIsKey: mainWindow?.isKeyWindow == true,
                    appIsActive: NSApp.isActive, hasDialog: navigationBlocked)
            }
            model.showRecovery = { [weak self] in self?.showRecoveryWindow() }
            model.dismissRecovery = { [weak self] in self?.dismissRecovery() }
            model.stateChanged = { [weak self] in self?.refreshStatus() }
            makeMenu()
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.model.phase != .ready else { return event }
                guard NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return event }
                if self.model.phase == .recovery {
                    guard self.navigation.page == .recovery,
                          Self.canHideRecovery(for: event.window, recovery: self.mainWindow) else { return event }
                    self.mainWindow?.orderOut(nil)
                }
                else { self.model.cancel(cause: .escape) }
                return nil
            }
            refreshStatus()
            let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
            if !model.setupComplete { showSetupWindow() }
            else if !loginLaunch { showMainWindow() }
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
        let destination = NSApp.modalWindow ?? Self.presentationWindow(requested: window, windows: NSApp.orderedWindows)
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
        navigate(to: .home)
    }
    private func ensureMainWindow() {
        if mainWindow == nil {
            let window = makeWindow("Within", size: NSSize(width: 660, height: 720), minimum: NSSize(width: 620, height: 640), autosave: "Within.Main.v3",
                view: AppWindowView(model: model, navigation: navigation, togglePractice: { [weak self] expanded in
                    self?.navigate(to: .home, practice: expanded)
                }))
            let toolbar = NSToolbar(identifier: "Within.HomeToolbar"); toolbar.delegate = self
            toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
            window.toolbar = toolbar; window.toolbarStyle = .unified
            mainWindow = window
        }
    }
    private func showSettingsWindow(section: String? = nil) {
        if navigate(to: .settings), let section { model.settingsSection = section }
    }
    private func showHelpWindow() { navigate(to: .help) }
    private func showSetupWindow() { navigate(to: .setup) }
    private func showPracticeWindow() { navigate(to: .home, practice: true) }
    @objc private func goBack() { navigate(to: navigation.backDestination, back: true) }

    private var navigationBlocked: Bool { NSApp.modalWindow != nil || mainWindow?.attachedSheet != nil }
    static func practiceIsActive(navigation: AppNavigation, windowIsKey: Bool, appIsActive: Bool, hasDialog: Bool) -> Bool {
        navigation.showsPractice && windowIsKey && appIsActive && !hasDialog
    }

    @discardableResult
    private func navigate(to page: AppPage, practice: Bool? = nil, back: Bool = false) -> Bool {
        guard model != nil else { return false }
        ensureMainWindow()
        let changed = navigation.navigate(to: page, practice: practice, back: back, model: model,
            blocked: navigationBlocked, confirmPracticeExit: confirmPracticeExit)
        if !changed, page == .recovery, model.phase == .recovery { deferredRecovery = true }
        updateWindowChrome()
        present(mainWindow)
        return changed
    }
    private func updateWindowChrome() {
        switch navigation.page {
        case .home: mainWindow?.title = "Within"
        case .settings: mainWindow?.title = "Settings · Within"
        case .help: mainWindow?.title = "Help · Within"
        case .setup: mainWindow?.title = "Set Up Within"
        case .recovery: mainWindow?.title = "Your words · Within"
        }
        mainWindow?.toolbar?.validateVisibleItems()
    }
    func windowDidEndSheet(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.presentDeferredRecovery() }
    }
    private func presentDeferredRecovery() {
        guard deferredRecovery, !navigationBlocked, !model.editingShortcut else { return }
        deferredRecovery = false
        if model.phase == .recovery { showRecoveryWindow() }
    }
    private func dismissRecovery() {
        deferredRecovery = false
        if model.phase == .recovery {
            // Lock/sleep hides pending words without dropping the session.
            mainWindow?.orderOut(nil)
            navigation.recoveryDismissed()
        } else if navigation.page == .recovery {
            navigation.recoveryDismissed()
        }
        updateWindowChrome()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        guard !navigationBlocked, !model.editingShortcut else { present(mainWindow); return false }
        return navigation.allowPracticeExit(model: model, confirm: confirmPracticeExit)
    }
    private func confirmPracticeExit() -> Bool {
        let alert = NSAlert(); alert.messageText = "Cancel this practice recording?"
        alert.informativeText = "Leaving practice cancels the current recording or transcription. Earlier practice text stays available until you clear it or quit."
        alert.addButton(withTitle: "Keep practicing"); alert.addButton(withTitle: "Cancel and leave")
        return runConfirmation(alert) == .alertSecondButtonReturn
    }
    static func canHideRecovery(for eventWindow: NSWindow?, recovery: NSWindow?) -> Bool {
        guard let recovery, eventWindow === recovery, recovery.attachedSheet == nil else { return false }
        return true
    }
    private func runConfirmation(_ alert: NSAlert) -> NSApplication.ModalResponse {
        model.suspendEscapeShortcut()
        defer {
            model.resumeEscapeShortcut()
            DispatchQueue.main.async { [weak self] in self?.presentDeferredRecovery() }
        }
        return alert.runModal()
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier.rawValue != "Within.Back" || navigation.page != .home
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("Within.Back"), .flexibleSpace, .init("Within.Help"), .init("Within.Settings")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier.rawValue == "Within.Back" {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Back"; item.toolTip = "Back"
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            item.target = self; item.action = #selector(goBack); item.isBordered = true
            return item
        }
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
        navigate(to: .recovery)
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
