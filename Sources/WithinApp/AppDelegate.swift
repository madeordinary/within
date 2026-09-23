import AppKit
import SwiftUI
import WithinCore
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var mainWindow: NSWindow?
    private var recoveryWindow: NSWindow?
    private var pill: NSPanel?
    private var statusItem: NSStatusItem?
    private var actionItem: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var reviewItem: NSMenuItem?
    private var localKeyMonitor: Any?
    private var lockDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
            model.showRecovery = { [weak self] in self?.showRecoveryWindow() }
            model.dismissRecovery = { [weak self] in self?.recoveryWindow?.orderOut(nil) }
            model.stateChanged = { [weak self] in self?.refreshStatus() }
            makeMenu()
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.model.phase != .ready else { return event }
                if self.model.phase == .recovery { self.recoveryWindow?.orderOut(nil) }
                else { self.model.cancel() }
                return nil
            }
            refreshStatus()
            if !UserDefaults.standard.bool(forKey: "setupComplete") { showMainWindow() }
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
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
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
        let appMenu = NSMenu()
        let root = NSMenuItem(); root.submenu = NSMenu()
        root.submenu?.addItem(item("Quit Within", #selector(quit), key: "q"))
        appMenu.addItem(root)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); edit.submenu = NSMenu(title: "Edit")
        for (name, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(NSMenuItem(title: name, action: selector, keyEquivalent: key))
        }
        appMenu.addItem(edit); NSApp.mainMenu = appMenu
    }
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    @objc private func toggleDictation() { if model.isActive { model.stop() } else { model.start(practice: false) } }
    @objc private func cancelDictation() { model.cancel() }
    @objc private func reviewWords() { showRecoveryWindow() }
    @objc private func openWithin() { showMainWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showMainWindow() {
        guard model != nil else { return }
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 710), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Within"; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(model: model))
            window.minSize = NSSize(width: 760, height: 690); window.center(); window.delegate = self
            mainWindow = window
        }
        model.refreshPermissions(); NSApp.activate(ignoringOtherApps: true); mainWindow?.makeKeyAndOrderFront(nil)
    }
    private func showRecoveryWindow() {
        guard model.phase == .recovery else { return }
        if recoveryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 565, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Your words · Within"; window.isReleasedWhenClosed = false; window.level = .floating
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
