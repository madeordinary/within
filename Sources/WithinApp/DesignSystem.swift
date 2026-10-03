import AppKit
import SwiftUI
import WithinCore

/// Application content colors. Window chrome, focus and control behavior stay native.
/// Surfaces and text are neutral; green is the one signature color, kept for the brand,
/// selection and the primary action, as in the other Made Ordinary apps.
enum Palette {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    static let canvas = adaptive(0xF5F4F0, 0x161616)
    static let surface = adaptive(0xFFFFFF, 0x1F1F1F)
    static let accent = adaptive(0x00624C, 0x94CDB7)
    static let onAccent = adaptive(0xFFFFFF, 0x12372A)
    static let text = adaptive(0x1D1D1F, 0xF5F5F2)
    static let secondary = adaptive(0x6E6E73, 0xA1A1A6)
    static let tint = adaptive(0xE4EDE8, 0x23302A)
    static let line = adaptive(0xDDDBD6, 0x3A3A3C)
    static let warning = adaptive(0x805212, 0xF2CF88)
    static let key = adaptive(0xFFFFFF, 0x2C2C2E)
    static let danger = adaptive(0xA3322B, 0xF2A69E)
}

enum Typography {
    /// New York, Apple's system serif, for page headlines only. Body text stays SF.
    static func display(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .regular, design: .serif) }
}

/// Capsule buttons: accent-filled for the one primary action, quiet tint for the rest.
struct CapsuleButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View { CapsuleLabel(configuration: configuration, prominent: prominent) }
    private struct CapsuleLabel: View {
        let configuration: Configuration
        let prominent: Bool
        private var destructive: Bool { configuration.role == .destructive }
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .foregroundStyle(prominent ? Palette.onAccent : destructive ? Palette.danger : Palette.text)
                .background(prominent ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Palette.tint.opacity(0.8)), in: Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.38)
                .contentShape(Capsule())
        }
    }
}

extension View {
    func primaryAction() -> some View { buttonStyle(CapsuleButtonStyle(prominent: true)) }
    func quietAction() -> some View { buttonStyle(CapsuleButtonStyle(prominent: false)) }
    func withinSurface(padding: CGFloat = 20) -> some View { modifier(SurfaceStyle(padding: padding)) }
}

private struct InsetPanelKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside the main window's content panel, where groups sit on the lighter panel.
    var insetPanel: Bool {
        get { self[InsetPanelKey.self] }
        set { self[InsetPanelKey.self] = newValue }
    }
}

/// Raised white cards on the paper canvas; quiet tinted groups inside the content panel.
private struct SurfaceStyle: ViewModifier {
    let padding: CGFloat
    @Environment(\.insetPanel) private var insetPanel
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: insetPanel ? 14 : 18, style: .continuous)
        content.frame(maxWidth: .infinity, alignment: .leading).padding(padding)
            .background(insetPanel ? Palette.canvas.opacity(0.75) : Palette.surface, in: shape)
            .shadow(color: .black.opacity(insetPanel ? 0 : 0.05), radius: 10, y: 3)
    }
}

/// Physical-looking keys for the chosen shortcut; the accessible name stays the full binding.
struct Keycaps: View {
    let shortcut: DictationShortcut
    var large = false
    private var keys: [(glyph: String, name: String?)] {
        if shortcut.isModifierOnly {
            let side = shortcut.keyLabel.split(separator: " ").first.map(String.init) ?? ""
            let glyph = [59: "⌃", 62: "⌃", 58: "⌥", 61: "⌥", 54: "⌘", 55: "⌘", 56: "⇧", 60: "⇧"][Int(shortcut.keyCode)] ?? ""
            return [(glyph, "\(side.lowercased()) \(shortcut.keyLabel.split(separator: " ").last.map { $0.lowercased() } ?? "")")]
        }
        let mods = [(DictationShortcut.control, "⌃"), (DictationShortcut.option, "⌥"), (DictationShortcut.shift, "⇧"), (DictationShortcut.command, "⌘")]
            .filter { shortcut.modifiers & $0.0 != 0 }.map { ($0.1, String?.none) }
        return mods + [(shortcut.keyLabel, nil)]
    }
    var body: some View {
        HStack(spacing: large ? 10 : 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in Keycap(glyph: key.glyph, name: key.name, large: large) }
        }.accessibilityElement(children: .ignore).accessibilityLabel(shortcut.accessibilityName)
    }
}

private struct Keycap: View {
    let glyph: String
    let name: String?
    let large: Bool
    var body: some View {
        let height: CGFloat = large ? 56 : 32
        let shape = RoundedRectangle(cornerRadius: large ? 11 : 7, style: .continuous)
        Group {
            if let name {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Spacer(minLength: 0); Text(glyph).font(.system(size: large ? 15 : 10, weight: .medium)) }
                    Spacer(minLength: 0)
                    Text(name).font(.system(size: large ? 12 : 9, weight: .medium)).lineLimit(1).fixedSize()
                }.padding(.horizontal, large ? 11 : 7).padding(.vertical, large ? 8 : 4)
                    .frame(minWidth: large ? 116 : 72, minHeight: height, maxHeight: height)
            } else {
                Text(glyph).font(.system(size: large ? 22 : 13, weight: .medium)).lineLimit(1).fixedSize()
                    .padding(.horizontal, glyph.count > 1 ? (large ? 16 : 9) : 0)
                    .frame(minWidth: height, minHeight: height, maxHeight: height)
            }
        }.fixedSize(horizontal: true, vertical: false).foregroundStyle(Palette.text)
            .background {
                ZStack {
                    shape.fill(Palette.line).offset(y: large ? 3 : 2)
                    shape.fill(Palette.key)
                    shape.stroke(Palette.line.opacity(0.8), lineWidth: 1)
                }
            }.padding(.bottom, large ? 3 : 2)
    }
}

struct Brand: View {
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path").font(.system(size: compact ? 16 : 27, weight: .medium))
                .foregroundStyle(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("within").font(.system(size: compact ? 17 : 29, weight: .semibold)).tracking(-0.6)
                Text("by Made Ordinary").font(.system(size: compact ? 9 : 10)).foregroundStyle(Palette.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct PrivacyFooter: View {
    var text = "On your Mac. No recordings or dictation history saved."
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").accessibilityHidden(true)
            Text(text)
        }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let allowed: Bool
    let action: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "lock.circle")
                .foregroundStyle(allowed ? Palette.accent : Palette.secondary).font(.system(size: 18)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if allowed { Label("Allowed", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            else { Button("Allow…", action: action).accessibilityLabel("Allow \(title)") }
        }.padding(.vertical, 4)
    }
}

struct ModelPanel: View {
    @ObservedObject var model: AppModel
    @State private var showingRemove = false
    var allowRemoval = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Speech on your Mac", systemImage: "internaldrive").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.modelInstalled { Label("Installed", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            }
            Text(model.modelMessage).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            if model.modelBusy {
                if model.modelDownloading {
                    ProgressView(value: model.downloadProgress).accessibilityLabel("Model download progress")
                    Button("Cancel download", action: model.cancelDownload)
                } else { ProgressView().controlSize(.small).accessibilityLabel("Preparing local model") }
            } else if !model.modelInstalled {
                Text("Download 632 MB from Hugging Face. The host receives your IP address. After installation, transcription runs offline.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Download local model", action: model.downloadModel).primaryAction().disabled(model.workerBusy || model.phase != .ready)
            } else if allowRemoval {
                Button("Remove model…", role: .destructive) { showingRemove = true }
                    .disabled(model.workerBusy || model.phase != .ready)
            }
            DisclosureGroup("Model details & licenses") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Parakeet TDT 0.6B v3 · English\n632 MB · CC BY 4.0\nCore ML conversion by Fluid Inference")
                    Text("Stored in ~/Library/Application Support/Within/Models")
                    Link("Model source & attribution ↗", destination: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")!)
                    Text("Opening the link connects to Hugging Face in your browser.")
                }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.top, 8)
            }.font(.system(size: 12))
        }.confirmationDialog("Remove the local speech model?", isPresented: $showingRemove) {
            Button("Remove model", role: .destructive, action: model.removeModel)
            Button("Keep model", role: .cancel) {}
        } message: { Text("You’ll need to download it again to dictate. Your preferences stay on this Mac.") }
    }
}
