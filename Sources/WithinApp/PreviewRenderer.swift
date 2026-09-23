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
    for state in ["setup", "ready", "recovery", "recording"] {
        let model = AppModel(manifest: manifest, base: directory.appendingPathComponent("unused"), preview: true)
        model.configurePreview(state)
        if state == "recovery" {
            try render("within-recovery", view: RecoveryView(model: model), size: NSSize(width: 621, height: 430))
        } else if state == "recording" {
            try render("within-recording", view: PillView(model: model), size: NSSize(width: 348, height: 82))
        } else {
            try render("within-\(state)", view: MainView(model: model), size: NSSize(width: 800, height: 740))
            try render("within-\(state)-dark", view: MainView(model: model), size: NSSize(width: 800, height: 740), dark: true)
            if state == "ready" { try render("within-settings", view: MainView(model: model, section: "Settings"), size: NSSize(width: 800, height: 950)) }
        }
    }
}
enum PreviewFailure: Error { case render }
