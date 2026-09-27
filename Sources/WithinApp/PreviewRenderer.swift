import AppKit
import SwiftUI
import WithinCore

@MainActor
func renderPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest = try loadManifest()
    func render<V: View>(_ name: String, view: V, size: NSSize, dark: Bool = false) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PreviewFailure.render }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewFailure.render }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
    let shellSize = NSSize(width: 900, height: 700)
    func shell(_ model: AppModel, _ page: AppPage, practice: Bool = false) -> AppWindowView {
        let navigation = AppNavigation()
        if page != .home { _ = navigation.navigate(to: page, model: model, blocked: false, confirmPracticeExit: { false }) }
        if practice { _ = navigation.navigate(to: .home, practice: true, model: model, blocked: false, confirmPracticeExit: { false }) }
        return AppWindowView(model: model, navigation: navigation, togglePractice: { _ in })
    }
    for state in ["setup", "ready", "model-error", "missing-input", "permission", "recovery", "recording", "practice", "practice-empty", "practice-empty-toggle", "history", "history-empty", "history-off", "notes", "note-recording", "notes-empty"] {
        let model = AppModel(manifest: manifest, base: directory.appendingPathComponent("unused"), preview: true)
        model.configurePreview(state)
        if state == "practice-empty" || state == "history" {
            model.mode = .hold
            _ = model.chooseShortcut(DictationShortcut(keyCode: 59, modifiers: 0, keyLabel: "Left Control"))
        }
        for dark in [false, true] {
            let name = "within-\(state)\(dark ? "-dark" : "")"
            switch state {
            case "recovery": try render(name, view: shell(model, .recovery), size: shellSize, dark: dark)
            case "recording": try render(name, view: PillView(model: model), size: NSSize(width: PillView.width, height: PillView.height), dark: dark)
            case "practice", "practice-empty", "practice-empty-toggle": try render(name, view: shell(model, .home, practice: true), size: NSSize(width: 900, height: 900), dark: dark)
            case "notes", "note-recording", "notes-empty": try render(name, view: shell(model, .notes), size: shellSize, dark: dark)
            default: try render(name, view: shell(model, .home), size: shellSize, dark: dark)
            }
            if state == "history" {
                model.settingsSection = "History"
                try render("within-settings-history\(dark ? "-dark" : "")", view: shell(model, .settings), size: shellSize, dark: dark)
            }
            if state == "ready" {
                for section in ["General", "Audio", "Privacy", "Model", "About"] {
                    model.settingsSection = section
                    try render("within-settings-\(section.lowercased())\(dark ? "-dark" : "")", view: shell(model, .settings), size: shellSize, dark: dark)
                }
                try render("within-help\(dark ? "-dark" : "")", view: shell(model, .help), size: shellSize, dark: dark)
                try render("within-welcome\(dark ? "-dark" : "")", view: SetupView(model: model, step: .constant(0)), size: NSSize(width: 540, height: 650), dark: dark)
                for step in 1...4 {
                    try render("within-setup-step-\(step + 1)\(dark ? "-dark" : "")", view: SetupView(model: model, step: .constant(step)), size: NSSize(width: 540, height: 650), dark: dark)
                }
                let shortcutPreview = AppModel(manifest: manifest, base: directory.appendingPathComponent("unused"), preview: true)
                shortcutPreview.configurePreview("ready"); shortcutPreview.chooseShortcut(.rightControl)
                try render("within-shortcut-right-control\(dark ? "-dark" : "")", view: SetupView(model: shortcutPreview, step: .constant(3)), size: NSSize(width: 540, height: 650), dark: dark)
                try render("within-shortcut-recorder\(dark ? "-dark" : "")", view: ShortcutRecorderView(model: shortcutPreview), size: NSSize(width: 486, height: 430), dark: dark)
            }
            if state == "setup" || state == "missing-input" {
                try render("within-setup-microphone-\(state)\(dark ? "-dark" : "")", view: SetupView(model: model, step: .constant(1)), size: NSSize(width: 540, height: 600), dark: dark)
            }
        }
    }
}
enum PreviewFailure: Error { case render }
