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
    let dictionarySize = NSSize(width: 900, height: 1080)
    let editorSize = NSSize(width: 486, height: 520)
    func shell(_ model: AppModel, _ page: AppPage, practice: Bool = false) -> AppWindowView {
        let navigation = AppNavigation()
        if page != .home { _ = navigation.navigate(to: page, model: model, blocked: false, confirmPracticeExit: { false }) }
        if practice { _ = navigation.navigate(to: .home, practice: true, model: model, blocked: false, confirmPracticeExit: { false }) }
        return AppWindowView(model: model, navigation: navigation, togglePractice: { _ in })
    }
    for state in ["setup", "ready", "model-error", "missing-input", "permission", "recovery", "recording", "practice", "practice-empty", "practice-empty-toggle", "history", "history-empty", "history-off", "notes", "note-recording", "notes-empty", "update-available",
                  "recovery-dictionary", "inserted-dictionary", "practice-dictionary",
                  "dictionary", "dictionary-empty", "dictionary-unreadable", "dictionary-recording", "dictation-dictionary-unreadable",
                  "home-meeting-recording", "home-meeting-paused", "home-meeting-refused", "home-meeting-finishing", "notes-meeting",
                  "settings-privacy-saved-meetings", "settings-privacy-saved-meetings-days30", "settings-privacy-meetings-unlistable",
                  "settings-privacy-saved-meetings-backups", "settings-meetings", "settings-meetings-backups",
                  "meetings-empty", "meetings-library", "meeting-setup", "meeting-setup-computer-audio-intro", "meeting-mic-only",
                  "meeting-recording", "meeting-recording-720", "meeting-recording-900", "meeting-paused", "meeting-resume-acknowledge",
                  "meeting-call-ended", "meeting-recovered", "meeting-finished", "meeting-dictionary-fixes", "home-during-meeting",
                  "meetings-library-720", "meeting-finished-720", "meeting-setup-not-saved", "settings-meetings-backups-off",
                  "settings-privacy-saved-meetings-backups-off", "settings-privacy-saved-meetings-backup-failed"] {
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
            case "recovery-dictionary":
                try render(name, view: shell(model, .recovery), size: shellSize, dark: dark)
                model.switchPendingWords()
                try render("within-recovery-dictionary-original\(dark ? "-dark" : "")", view: shell(model, .recovery), size: shellSize, dark: dark)
                model.switchPendingWords()
            case "dictionary", "dictionary-empty", "dictionary-unreadable", "dictionary-recording":
                // Settings → Dictionary with the developer default on; "dictionary" is the section's own render.
                model.settingsSection = "Dictionary"
                try render(state == "dictionary" ? "within-settings-dictionary\(dark ? "-dark" : "")" : name, view: shell(model, .settings), size: dictionarySize, dark: dark)
            case "recording": try render(name, view: PillView(model: model), size: NSSize(width: PillView.width, height: PillView.height), dark: dark)
            case "practice", "practice-empty", "practice-empty-toggle", "practice-dictionary": try render(name, view: shell(model, .home, practice: true), size: NSSize(width: 900, height: 900), dark: dark)
            case "notes", "note-recording", "notes-empty", "notes-meeting": try render(name, view: shell(model, .notes), size: shellSize, dark: dark)
            case "settings-privacy-saved-meetings", "settings-privacy-saved-meetings-days30", "settings-privacy-meetings-unlistable", "settings-privacy-saved-meetings-backups",
                 "settings-privacy-saved-meetings-backups-off", "settings-privacy-saved-meetings-backup-failed":
                // The developer preview's saved meetings while the space is hidden: the only meeting line in Settings.
                model.settingsSection = "Privacy"
                try render(name, view: shell(model, .settings), size: shellSize, dark: dark)
            case "settings-meetings", "settings-meetings-backups", "settings-meetings-backups-off":
                model.settingsSection = "Meetings"
                try render(name, view: shell(model, .settings), size: NSSize(width: 900, height: 880), dark: dark)
                if state == "settings-meetings" {
                    // The copy the developer default adds to other pages.
                    for section in ["Audio", "Privacy"] {
                        model.settingsSection = section
                        try render("within-settings-\(section.lowercased())-with-meetings\(dark ? "-dark" : "")", view: shell(model, .settings), size: shellSize, dark: dark)
                    }
                    try render("within-help-with-meetings\(dark ? "-dark" : "")", view: shell(model, .help), size: NSSize(width: 900, height: 1000), dark: dark)
                }
            case "meeting-setup", "meeting-setup-computer-audio-intro", "meeting-mic-only", "meeting-setup-not-saved":
                try render(name, view: shell(model, .meetings), size: NSSize(width: 900, height: 1000), dark: dark)
            case "meeting-recording": try render(name, view: shell(model, .meetings), size: NSSize(width: 1100, height: 760), dark: dark)
            // The minimum window, where the transcript and notes become tabs; "meeting-recording-900" is the default window.
            case "meeting-recording-720", "meetings-library-720", "meeting-finished-720":
                try render(name, view: shell(model, .meetings), size: NSSize(width: 720, height: 560), dark: dark)
            case _ where state.hasPrefix("meeting"):
                try render(name, view: shell(model, .meetings), size: shellSize, dark: dark)
                if state == "meeting-dictionary-fixes" {
                    model.setShowingOriginalTranscription(true)
                    try render("within-meeting-dictionary-fixes-original\(dark ? "-dark" : "")", view: shell(model, .meetings), size: shellSize, dark: dark)
                    model.setShowingOriginalTranscription(false)
                }
            default: try render(name, view: shell(model, .home), size: shellSize, dark: dark)
            }
            if state == "update-available" {
                model.settingsSection = "About"
                try render("within-settings-about-update\(dark ? "-dark" : "")", view: shell(model, .settings), size: NSSize(width: 900, height: 900), dark: dark)
                let withDictionary = AppModel(manifest: manifest, base: directory.appendingPathComponent("unused"), preview: true)
                withDictionary.configurePreview(state); withDictionary.previewDictionary(.missing); withDictionary.settingsSection = "About"
                try render("within-settings-about-update-with-dictionary\(dark ? "-dark" : "")", view: shell(withDictionary, .settings), size: NSSize(width: 900, height: 900), dark: dark)
            }
            if state == "dictionary" {
                let suffix = dark ? "-dark" : ""
                let kubectl = model.dictionary.entries.first { $0.writeAs == "kubectl" }
                try render("within-dictionary-editor\(suffix)", view: DictionaryEntryEditor(model: model, entry: kubectl), size: editorSize, dark: dark)
                // Ten phrases, every one with a message, as after a failed Save.
                try render("within-dictionary-editor-issues\(suffix)", view: DictionaryEntryEditor(model: model, entry: nil, writeAs: "Jira",
                    phrases: ["gira", "shivon", "gira", "-jira", "ji/ra", "the jira ticket tracker for our team", "jira!", "jira_cloud", "cube cuddle", "jeera"],
                    showingIssues: true), size: editorSize, dark: dark)
                try render("within-dictionary-try\(suffix)", view: DictionaryTryField(model: model, text: "Ask shivon to file the gira ticket.").padding(24)
                    .frame(width: 640, height: 190, alignment: .top).background(Palette.surface),
                    size: NSSize(width: 640, height: 190), dark: dark)
            }
            if state == "dictionary-empty" {
                // The copy the developer default adds to other pages.
                for section in ["Privacy", "About"] {
                    model.settingsSection = section
                    try render("within-settings-\(section.lowercased())-with-dictionary\(dark ? "-dark" : "")", view: shell(model, .settings), size: shellSize, dark: dark)
                }
                try render("within-help-with-dictionary\(dark ? "-dark" : "")", view: shell(model, .help), size: NSSize(width: 900, height: 900), dark: dark)
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
