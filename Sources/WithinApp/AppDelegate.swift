import AppKit
import SwiftUI
import WithinCore
import Darwin
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var model: AppModel!
    private var mainWindow: NSWindow?
    private let navigation = AppNavigation()
    private var deferredRecovery = false
    private var pill: NSPanel?
    private var reminderPanel: ReminderPanel?
    private var startSheet: NSWindow?
    private var capsule: RecordingPanel?
    private var capsuleShown = false
    /// The status menu's meeting and reminder items; they exist only while the Meetings space is visible.
    private var meetingStatusItems: MeetingStatusItems?
    private var statusItem: NSStatusItem?
    private var actionItem: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var reviewItem: NSMenuItem?
    private var originalItem: NSMenuItem?
    private var quitItem: NSMenuItem?
    /// File → New Meeting…, which takes ⌘N only while the Meetings space shows, as Notes' own button does there.
    private var newMeetingItem: NSMenuItem?
    private var localKeyMonitor: Any?
    private var lockDescriptor: Int32 = -1
    private var finishingMeetingToQuit = false

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
            model.showHistorySettings = { [weak self] in self?.showSettingsWindow(section: "History") }
            model.showDictionarySettings = { [weak self] in self?.showSettingsWindow(section: "Dictionary") }
            model.showAboutSettings = { [weak self] in self?.showSettingsWindow(section: "About") }
            model.showHelp = { [weak self] in self?.showHelpWindow() }
            model.showSetup = { [weak self] in self?.showSetupWindow() }
            model.showPractice = { [weak self] in self?.showPracticeWindow() }
            model.practiceAreaIsActive = { [weak self] in
                guard let self else { return false }
                return Self.practiceIsActive(navigation: navigation, windowIsKey: mainWindow?.isKeyWindow == true,
                    appIsActive: NSApp.isActive, hasDialog: navigationBlocked)
            }
            model.showRecovery = { [weak self] in self?.showRecoveryWindow() }
            model.showMeetings = { [weak self] in self?.navigate(to: .meetings) }
            model.showWindow = { [weak self] in
                guard let self else { return }
                ensureMainWindow(); present(mainWindow)
            }
            model.dismissRecovery = { [weak self] in self?.dismissRecovery() }
            model.stateChanged = { [weak self] in self?.refreshStatus() }
            makeMenu()
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Escape never cancels a note recording or a meeting; their own controls end them.
                guard event.keyCode == 53, let self, self.model.phase != .ready, !self.model.isRecordingNote, self.model.activeCapture != .meeting else { return event }
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
    /// The meeting capsule shows only while another app is in front. Within in front also means no lock is in the way, in
    /// case the unlock wasn't heard.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard model != nil else { return }
        model.meetingWatcher.boundaryEnded()
        refreshMeetingCapsule()
    }
    func applicationDidResignActive(_ notification: Notification) { if model != nil { refreshMeetingCapsule() } }
    /// A display added, removed or rearranged, or the menu bar or Dock changed: the capsule and reminder go back top-right.
    func applicationDidChangeScreenParameters(_ notification: Notification) { if model != nil { placeMeetingPanels() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // An open meeting, or a finished one with an edit or a failed save still to write: quit once it is saved.
        if model.meetingNeedsSaveToQuit {
            // Logout, restart or shutdown never waits on an alert, which would sit while capture runs; neither does a
            // quit already saving, or a discard, which deletes rather than saves.
            if model.activeCapture == .meeting, !model.quittingMeeting, model.meetings.phase != .discarding, !Self.quitIsPowerOff {
                let alert = NSAlert(); alert.messageText = "Finish meeting notes and quit?"
                alert.informativeText = "Within stops listening, saves the transcript and your notes, then quits."
                alert.addButton(withTitle: "Finish and Quit"); alert.addButton(withTitle: "Cancel")
                guard runConfirmation(alert) == .alertFirstButtonReturn else { return .terminateCancel }
            }
            // Capture stops before this returns. A second terminate while AppKit waits quits at once without asking
            // (scratch AppKit probe, not Within), so both Quit items are off until the reply.
            let quitting = model.finishMeetingForQuit()
            finishingMeetingToQuit = true; refreshStatus()
            Task { @MainActor [weak self] in
                // Quits only once the meeting is saved; a drain that stalls is cut off by the controller's watchdog.
                let saved = await quitting.value
                self?.finishingMeetingToQuit = false; self?.refreshStatus()
                if saved { model.shutdown() }
                NSApp.reply(toApplicationShouldTerminate: saved)
                guard !saved else { return }
                let failed = NSAlert()
                if model.meetings.deletionPending {
                    failed.messageText = "The discarded meeting couldn’t be deleted from this Mac, so Within didn’t quit."
                    failed.informativeText = "Check the meetings folder in Finder and try again."
                } else {
                    failed.messageText = "Meeting notes couldn’t be saved, so Within didn’t quit."
                    failed.informativeText = "Check free space and try again."
                }
                failed.runModal()
            }
            return .terminateLater
        }
        if model.isRecordingNote {
            let alert = NSAlert(); alert.messageText = "Quit while recording a note?"
            alert.informativeText = "Your note is saved about every ten seconds. Words from the last few seconds may be lost. Choose Stop in the note first to keep everything."
            alert.addButton(withTitle: "Keep Within open"); alert.addButton(withTitle: "Quit anyway")
            if runConfirmation(alert) != .alertSecondButtonReturn { return .terminateCancel }
        } else if model.phase != .ready {
            let alert = NSAlert(); alert.messageText = "Quit and discard this dictation?"
            alert.informativeText = "Within doesn’t save recordings or pending words. Anything waiting here will be discarded."
            alert.addButton(withTitle: "Keep Within open"); alert.addButton(withTitle: "Quit and discard")
            if runConfirmation(alert) != .alertSecondButtonReturn { return .terminateCancel }
        }
        model.shutdown(); return .terminateNow
    }
    /// Logout, restart or shutdown, from the quit event's reason. UNVERIFIED on a real logout; the power-off
    /// notification, when it comes first, has already started the meeting's quit.
    private static var quitIsPowerOff: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        guard let reason = (event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)))?.enumCodeValue
        else { return false }
        return [kAEShutDown, kAERestart, kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog].map { OSType($0) }.contains(reason)
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }
    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Within")
        statusItem?.menu = makeStatusMenu(for: model)
        makeApplicationMenu()
    }
    /// The menu bar item's menu. Its meeting and reminder items exist only while the Meetings space is visible, so with
    /// the developer default off it is dictation's menu alone. Native checks build it without a status item.
    func makeStatusMenu(for model: AppModel) -> NSMenu {
        self.model = model
        let menu = NSMenu(); menu.autoenablesItems = false
        let title = NSMenuItem(title: "Within, by Made Ordinary", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        if model.showsMeetingsSpace {
            let items = MeetingStatusItems(line: { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }, item: { self.item($0, $1) })
            items.all.forEach(menu.addItem)
            meetingStatusItems = items
            // The meeting's time is read as the menu opens; nothing ticks while it is closed.
            menu.delegate = self
        }
        actionItem = item("Start Dictation", #selector(toggleDictation)); menu.addItem(actionItem!)
        cancelItem = item("Cancel Dictation", #selector(cancelDictation)); menu.addItem(cancelItem!)
        reviewItem = item("Review Pending Words…", #selector(reviewWords)); menu.addItem(reviewItem!)
        originalItem = item("Show Original Transcription…", #selector(showOriginal)); menu.addItem(originalItem!)
        menu.addItem(.separator()); menu.addItem(item("Open Within…", #selector(openWithin)))
        quitItem = item("Quit Within", #selector(quit))
        menu.addItem(.separator()); menu.addItem(quitItem!)
        menu.insertItem(item("Settings…", #selector(openSettings)), at: menu.numberOfItems - 2)
        menu.insertItem(item("Within Help", #selector(openHelp)), at: menu.numberOfItems - 2)
        refreshStatusMenu()
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { refreshStatusMenu() }
    private func makeApplicationMenu() {
        let menu = NSMenu()
        let root = NSMenuItem(title: "Within", action: nil, keyEquivalent: "")
        let application = NSMenu(title: "Within"); root.submenu = application
        application.addItem(item("About Within", #selector(openAbout)))
        application.addItem(item("Check for Updates…", #selector(checkForUpdates)))
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
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); file.submenu = makeFileMenu(showingMeetings: model.showsMeetingsSpace)
        menu.addItem(file)
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

    /// The File menu. Its Meeting group exists only while the Meetings space is visible.
    func makeFileMenu(showingMeetings: Bool) -> NSMenu {
        let file = NSMenu(title: "File")
        file.addItem(item("Open Within", #selector(openWithin), key: "0"))
        file.addItem(item("Practice Dictation…", #selector(openPractice)))
        file.addItem(item("Set Up Within…", #selector(openSetup)))
        if showingMeetings {
            file.addItem(.separator())
            let newItem = item("New Meeting…", #selector(newMeeting)); newMeetingItem = newItem; file.addItem(newItem)
            file.addItem(item("Pause Meeting", #selector(pauseOrResumeMeeting), key: "p", modifiers: [.command, .shift]))
            file.addItem(item("Finish Meeting", #selector(finishMeeting), key: "f", modifiers: [.command, .shift]))
            file.addItem(item("Discard Meeting…", #selector(discardMeeting)))
            file.addItem(item("All Meetings", #selector(allMeetings), key: "["))
        }
        file.addItem(.separator())
        file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        return file
    }

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self
        if modifiers != .command { item.keyEquivalentModifierMask = modifiers }
        return item
    }
    @objc private func toggleDictation() { if model.isActive { model.stop() } else { model.startFromCurrentWindow() } }
    @objc private func cancelDictation() { model.cancel() }
    @objc private func reviewWords() { showRecoveryWindow() }
    /// Opens the Dictation row, where the clipboard is disclosed before Copy; it never copies by itself.
    @objc private func showOriginal() { showMainWindow(); model.lastChangeFocusRequested = true }
    @objc private func openWithin() { showMainWindow() }
    @objc private func openSettings() { showSettingsWindow() }
    @objc private func openAbout() { showSettingsWindow(section: "About") }
    @objc private func checkForUpdates() { showSettingsWindow(section: "About"); model.checkForUpdates() }
    @objc private func openHelp() { showHelpWindow() }
    @objc private func openSetup() { showSetupWindow() }
    @objc private func openPractice() { showPracticeWindow() }
    /// A second terminate while Finish and Quit saves would end the app at once, so it does nothing then.
    @objc private func quit() { if !finishingMeetingToQuit { NSApp.terminate(nil) } }
    /// Setup for a new meeting; nothing starts until its Start meeting.
    @objc private func newMeeting() { if navigate(to: .meetings) { model.newMeeting() } }
    /// Resume needing the acknowledgment shows the meeting's checkbox instead, since only it can give one.
    @objc private func pauseOrResumeMeeting() {
        guard model.meetings.phase == .paused else { model.meetings.pause(); return }
        if model.meetings.needsAcknowledgment { if navigate(to: .meetings) { model.meetingsFocusRequest = .acknowledgment } }
        else { model.resumeMeeting(acknowledged: false) }
    }
    @objc private func finishMeeting() {
        navigate(to: .meetings)
        Task { await model.finishMeeting() }
    }
    @objc private func discardMeeting() {
        let alert = NSAlert(); alert.messageText = "Discard this meeting?"
        alert.informativeText = "Capture stops and its transcript and notes are deleted from this Mac."
        alert.addButton(withTitle: "Keep meeting"); alert.addButton(withTitle: "Discard meeting")
        alert.buttons.last?.hasDestructiveAction = true
        guard runConfirmation(alert) == .alertSecondButtonReturn, model.meetings.isOpen else { return }
        Task { await model.discardMeeting() }
    }
    @objc private func allMeetings() { if navigate(to: .meetings) { model.showAllMeetings() } }
    // The status menu's meeting items work from another app: none brings Within forward except Show, Discard's
    // confirmation, Start Zoom Notes… and a Resume that needs the meeting's acknowledgment.
    @objc fileprivate func statusPauseOrResume() { if model.meetings.phase == .paused { model.resumeOpenMeeting() } else { model.pauseOpenMeeting() } }
    @objc fileprivate func statusFinishMeeting() { model.finishOpenMeeting() }
    @objc fileprivate func statusDiscardMeeting() { NSApp.activate(ignoringOtherApps: true); discardMeeting() }
    @objc fileprivate func statusShowMeeting() { model.showOpenMeeting() }
    @objc fileprivate func statusStartReminderNotes() { model.openMeetingStartSheet() }
    @objc fileprivate func statusSnoozeReminders() { model.reminderSnooze() }
    @objc fileprivate func statusDismissReminder() { model.reminderDismiss() }

    enum MeetingMenuAction { case newMeeting, pauseOrResume, finish, discard, allMeetings }
    struct MeetingMenuState: Equatable {
        let title: String
        let enabled: Bool
        /// Why an item that would start or open a meeting is unavailable, as its tooltip.
        var reason: String?
    }
    private static let meetingActions: [Selector: MeetingMenuAction] = [#selector(AppDelegate.newMeeting): .newMeeting,
        #selector(AppDelegate.pauseOrResumeMeeting): .pauseOrResume, #selector(AppDelegate.finishMeeting): .finish,
        #selector(AppDelegate.discardMeeting): .discard, #selector(AppDelegate.allMeetings): .allMeetings]
    static let meetingOpenReason = "Finish or discard the current meeting first."
    /// The Meeting group's titles and whether each can act now. What starts capture gives the same reasons, in the
    /// same order, as a refused start: what holds capture first, then whether Within is ready.
    static func meetingMenuState(_ action: MeetingMenuAction, model: AppModel, page: AppPage) -> MeetingMenuState {
        let meetings = model.meetings
        switch action {
        case .newMeeting:
            let reason = meetings.isOpen ? meetingOpenReason : model.meetingHeldMessage ?? model.meetingStartBlocker
            return MeetingMenuState(title: "New Meeting…", enabled: reason == nil, reason: reason)
        case .pauseOrResume:
            guard meetings.phase == .paused else {
                return MeetingMenuState(title: "Pause Meeting", enabled: meetings.phase == .preparing || meetings.phase == .recording)
            }
            let reason = model.meetingStartBlocker
            return MeetingMenuState(title: meetings.needsAcknowledgment ? "Resume Meeting…" : "Resume Meeting", enabled: reason == nil, reason: reason)
        case .finish:
            return MeetingMenuState(title: "Finish Meeting", enabled: [.preparing, .recording, .pausing, .paused].contains(meetings.phase))
        case .discard:
            return MeetingMenuState(title: "Discard Meeting…", enabled: meetings.isOpen && meetings.phase != .discarding)
        case .allMeetings:
            return MeetingMenuState(title: "All Meetings", enabled: page == .meetings && !meetings.isOpen && !meetings.deletionPending && model.meetingsRoute != .library)
        }
    }
    /// The app menu enables its items itself; its Quit says what is happening while the meeting saves.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let selector = menuItem.action, let action = Self.meetingActions[selector], let model {
            let state = Self.meetingMenuState(action, model: model, page: navigation.page)
            menuItem.title = state.title; menuItem.toolTip = state.reason
            return state.enabled
        }
        guard menuItem.action == #selector(quit) else { return true }
        menuItem.title = finishingMeetingToQuit ? Self.finishingTitle : "Quit Within"
        return !finishingMeetingToQuit
    }
    private static let finishingTitle = "Finishing Meeting Notes…"

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
            let window = makeWindow("Within", size: NSSize(width: 900, height: 700), minimum: NSSize(width: 720, height: 560), autosave: "Within.Main.v4",
                view: AppWindowView(model: model, navigation: navigation, togglePractice: { [weak self] expanded in
                    self?.navigate(to: .home, practice: expanded)
                }, navigate: { [weak self] page in
                    self?.navigate(to: page)
                }, openSettings: { [weak self] section in
                    self?.showSettingsWindow(section: section)
                }))
            // The sidebar runs under a transparent title bar; the window title stays for accessibility and Mission Control.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            mainWindow = window
        }
    }
    private func showSettingsWindow(section: String? = nil) {
        if navigate(to: .settings), let section { model.settingsSection = section }
    }
    private func showHelpWindow() { navigate(to: .help) }
    private func showSetupWindow() { navigate(to: .setup) }
    private func showPracticeWindow() { navigate(to: .home, practice: true) }

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
        mainWindow?.title = Self.windowTitle(navigation.page)
        newMeetingItem?.keyEquivalent = navigation.page == .meetings ? "n" : ""
    }
    /// A meeting's own title never reaches the window title, which Mission Control and screen sharing show.
    static func windowTitle(_ page: AppPage) -> String {
        switch page {
        case .home: return "Within"
        case .notes: return "Notes · Within"
        case .meetings: return "Meetings · Within"
        case .settings: return "Settings · Within"
        case .help: return "Help · Within"
        case .setup: return "Set Up Within"
        case .recovery: return "Your words · Within"
        }
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
    private func showRecoveryWindow() {
        guard model.phase == .recovery else { return }
        navigate(to: .recovery)
    }
    private func refreshStatus() {
        let look = Self.statusAppearance(model)
        statusItem?.button?.image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: look.description)
        statusItem?.button?.toolTip = look.toolTip
        refreshStatusMenu()
        if Self.showsPill(model) {
            if pill == nil {
                let panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: PillView.width, height: PillView.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.hidesOnDeactivate = false
                panel.contentView = NSHostingView(rootView: PillView(model: model)); pill = panel
            }
            if let frame = NSScreen.main?.visibleFrame { pill?.setFrameOrigin(NSPoint(x: frame.midX - PillView.width / 2, y: frame.minY + 28)) }
            pill?.orderFrontRegardless()
        } else { pill?.orderOut(nil) }
        refreshMeetingCapsule()
        refreshReminderPanel()
        refreshMeetingStartSheet()
    }
    /// The pill belongs to dictation only; a note or a meeting shows its recording elsewhere.
    static func showsPill(_ model: AppModel) -> Bool { model.activeCapture == .dictation }
    struct StatusAppearance: Equatable { let symbol: String, description: String, toolTip: String }
    /// The status item's symbol, the sentence VoiceOver reads for it and its tooltip. A meeting says its own state, so a
    /// paused meeting never looks like dictation waiting.
    static func statusAppearance(_ model: AppModel) -> StatusAppearance {
        guard model.activeCapture == .meeting else {
            let recording = model.phase == .recording
            return StatusAppearance(symbol: recording ? "mic.fill" : "waveform", description: recording ? "Within. Microphone on." : "Within. Microphone off.",
                                    toolTip: recording ? "Within · recording" : "Within · microphone off")
        }
        let meetings = model.meetings, app = meetings.meeting?.appName ?? MeetingApp.zoom.name
        let on = model.phase == .recording
        switch meetings.phase {
        case .recording where on && [.quiet, .lost].contains(meetings.sourceStates[.others]):
            return StatusAppearance(symbol: "mic.fill", description: "Within. Meeting notes on, not hearing \(app).", toolTip: "Within · not hearing \(app)")
        case .recording where on: return StatusAppearance(symbol: "mic.fill", description: "Within. Meeting notes on.", toolTip: "Within · meeting notes on")
        case .paused: return StatusAppearance(symbol: "mic.slash", description: "Within. Meeting notes paused. Microphone off.", toolTip: "Within · meeting notes paused")
        case .preparing: return StatusAppearance(symbol: on ? "mic.fill" : "mic.slash", description: "Within. Meeting notes starting.", toolTip: "Within · meeting notes starting")
        default:
            // Pausing, finishing or discarding: the words Home uses.
            let state = meetings.homeStatus
            return StatusAppearance(symbol: on ? "mic.fill" : "mic.slash", description: "Within. \(state).", toolTip: "Within · \(state.prefix(1).lowercased() + state.dropFirst())")
        }
    }
    /// The status menu's items for the state now. With the developer default off, only dictation's.
    private func refreshStatusMenu() {
        let active = model.phase == .preparing || model.phase == .recording || model.phase == .transcribing
        actionItem?.title = model.isRecordingNote ? "Stop Note Recording" : model.isActive ? "Stop and Transcribe" : "Start Dictation"
        actionItem?.isEnabled = model.isActive || model.canStartDictation
        cancelItem?.isEnabled = active
        // Dictation's items would stop the meeting's session; a meeting has its own controls.
        let meeting = model.activeCapture == .meeting
        actionItem?.isHidden = meeting; cancelItem?.isHidden = meeting
        reviewItem?.isHidden = model.phase != .recovery
        originalItem?.isHidden = model.lastDictationChange == nil
        quitItem?.title = finishingMeetingToQuit ? Self.finishingTitle : "Quit Within"
        quitItem?.isEnabled = !finishingMeetingToQuit
        guard let items = meetingStatusItems else { return }
        let meetings = model.meetings, lines = model.meetingMenuLines
        let open = lines != nil, recovered = !meetings.isOpen && !model.meetingsToReview.isEmpty
        // The time and what the meeting is doing, or the one-time line after Within closed unexpectedly during one.
        items.title.isHidden = !open && !recovered
        items.title.title = lines?.title ?? "Meeting notes were interrupted"
        items.title.setAccessibilityLabel(lines?.spoken)
        items.detail.isHidden = !open; items.detail.title = lines?.detail ?? ""
        for (menuItem, action) in [(items.pauseOrResume, MeetingMenuAction.pauseOrResume), (items.finish, .finish), (items.discard, .discard)] {
            let state = Self.meetingMenuState(action, model: model, page: navigation.page)
            menuItem.isHidden = !open; menuItem.title = state.title; menuItem.isEnabled = state.enabled; menuItem.toolTip = state.reason
        }
        items.show.isHidden = !open && !recovered; items.show.title = open ? "Show Meeting" : "Show Meetings"
        // The reminder's keyboard path: Zoom keeps focus, so these are reachable with Control-F8 or VoiceOver.
        let reminder = model.meetingReminder
        for menuItem in [items.reminderStart, items.reminderSnooze, items.reminderDismiss] { menuItem.isHidden = reminder == nil }
        items.reminderStart.title = "Start \(reminder?.app.name ?? MeetingApp.zoom.name) Notes…"
        let dictation = [actionItem, cancelItem, reviewItem, originalItem].contains { $0?.isHidden == false }
        items.groupSeparator.isHidden = !((open || recovered) && reminder != nil)
        items.dictationSeparator.isHidden = !((open || recovered || reminder != nil) && dictation)
    }
    /// The reminder floats top-right while one is offered, ordered front but never made key, so the call keeps focus. It is
    /// placed again once SwiftUI has laid out a change, such as the first-time explanation, so it grows downward.
    private func refreshReminderPanel() {
        guard model.meetingReminder != nil else { reminderPanel?.orderOut(nil); return }
        let panel = reminderPanel ?? ReminderPanel(content: ReminderHostingView(rootView: ReminderView(model: model, watcher: model.meetingWatcher, meetings: model.meetings)))
        reminderPanel = panel
        placeMeetingPanels()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            guard let self, model.meetingReminder != nil else { return }
            placeMeetingPanels()
        }
    }
    /// The capsule while a meeting is open and another app is in front, ordered front but never key. Its controls are
    /// also in the status menu.
    private func refreshMeetingCapsule() {
        capsuleShown = model.meetingCapsuleShown(appIsActive: NSApp.isActive)
        if capsuleShown, capsule == nil {
            capsule = RecordingPanel.meetingCapsule(content: NSHostingView(rootView: MeetingCapsuleView(model: model, meetings: model.meetings) { [weak self] in
                DispatchQueue.main.async { self?.placeMeetingPanels() }
            }))
        }
        placeMeetingPanels()
        if capsuleShown { capsule?.orderFrontRegardless() } else { capsule?.orderOut(nil) }
    }
    /// Top-right under the menu bar: the capsule first, and a reminder shown with it below it.
    private func placeMeetingPanels() {
        var top: CGFloat?
        if capsuleShown, let capsule { capsule.placeTopRight(on: NSScreen.main); top = capsule.frame.minY - 8 }
        if model.meetingReminder != nil { reminderPanel?.place(on: NSScreen.main, below: top) }
    }
    /// The reminder's menu path: a sheet on Within's window while the model asks for one. It closes with its reminder,
    /// and Cancel or Escape starts nothing. Another sheet already there means it isn't shown, with a beep and a sentence.
    private func refreshMeetingStartSheet() {
        guard model.meetingStartSheet else {
            if let startSheet { self.startSheet = nil; startSheet.sheetParent?.endSheet(startSheet) }
            return
        }
        guard startSheet == nil else { return }
        guard let mainWindow, mainWindow.attachedSheet == nil, NSApp.modalWindow == nil else {
            NSSound.beep(); model.meetingStartSheetUnavailable(); return
        }
        let controller = NSHostingController(rootView: MeetingStartSheet(model: model, watcher: model.meetingWatcher, meetings: model.meetings))
        controller.sizingOptions = [.preferredContentSize]
        let sheet = NSWindow(contentViewController: controller)
        startSheet = sheet
        mainWindow.beginSheet(sheet) { [weak self] _ in
            guard let self, startSheet === sheet else { return }
            startSheet = nil
            model.closeMeetingStartSheet()
        }
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

/// The status menu's meeting group, its reminder group and their separators, in menu order.
struct MeetingStatusItems {
    let title, detail, pauseOrResume, finish, discard, show, groupSeparator, reminderStart, reminderSnooze, reminderDismiss, dictationSeparator: NSMenuItem
    var all: [NSMenuItem] { [title, detail, pauseOrResume, finish, discard, show, groupSeparator, reminderStart, reminderSnooze, reminderDismiss, dictationSeparator] }

    @MainActor init(line: (String) -> NSMenuItem, item: (String, Selector) -> NSMenuItem) {
        title = line("Meeting"); detail = line("")
        title.isEnabled = false; detail.isEnabled = false
        pauseOrResume = item("Pause Meeting", #selector(AppDelegate.statusPauseOrResume))
        finish = item("Finish Meeting", #selector(AppDelegate.statusFinishMeeting))
        discard = item("Discard Meeting…", #selector(AppDelegate.statusDiscardMeeting))
        show = item("Show Meeting", #selector(AppDelegate.statusShowMeeting))
        reminderStart = item("Start Zoom Notes…", #selector(AppDelegate.statusStartReminderNotes))
        reminderSnooze = item("Snooze Reminders for 1 Hour", #selector(AppDelegate.statusSnoozeReminders))
        reminderDismiss = item("Dismiss Reminder", #selector(AppDelegate.statusDismissReminder))
        groupSeparator = .separator(); dictationSeparator = .separator()
        all.forEach { $0.isHidden = true }
    }
}
