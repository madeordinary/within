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
    for state in ["setup", "ready", "model-error", "missing-input", "permission", "recovery", "recording", "practice"] {
        let model = AppModel(manifest: manifest, base: directory.appendingPathComponent("unused"), preview: true)
        model.configurePreview(state)
        for dark in [false, true] {
            let name = "within-\(state)\(dark ? "-dark" : "")"
            switch state {
            case "recovery": try render(name, view: RecoveryView(model: model), size: NSSize(width: 620, height: 500), dark: dark)
            case "recording": try render(name, view: PillView(model: model), size: NSSize(width: PillView.width, height: 82), dark: dark)
            case "practice": try render(name, view: PracticeView(model: model), size: NSSize(width: 600, height: 510), dark: dark)
            default: try render(name, view: MainView(model: model), size: NSSize(width: 560, height: 580), dark: dark)
            }
            if state == "ready" {
                for section in ["General", "Audio", "Privacy", "Model", "About"] {
                    model.settingsSection = section
                    try render("within-settings-\(section.lowercased())\(dark ? "-dark" : "")", view: SettingsView(model: model), size: NSSize(width: 640, height: 630), dark: dark)
                }
                try render("within-help\(dark ? "-dark" : "")", view: HelpView(model: model), size: NSSize(width: 600, height: 590), dark: dark)
                try render("within-welcome\(dark ? "-dark" : "")", view: SetupView(model: model), size: NSSize(width: 600, height: 600), dark: dark)
                for step in 1...3 {
                    try render("within-setup-step-\(step + 1)\(dark ? "-dark" : "")", view: SetupView(model: model, step: step), size: NSSize(width: 600, height: 600), dark: dark)
                }
            }
        }
    }
}
enum PreviewFailure: Error { case render }
