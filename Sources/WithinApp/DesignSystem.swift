import AppKit
import SwiftUI

/// Application content colors. Window chrome, focus and control behavior stay native.
enum Palette {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    static let canvas = adaptive(0xFAF7F0, 0x1D231F)
    static let surface = adaptive(0xFFFFFF, 0x292F2B)
    static let accent = adaptive(0x00624C, 0x94CDB7)
    static let onAccent = adaptive(0xFAF7F0, 0x12372A)
    static let text = adaptive(0x1C2B25, 0xFAF7F0)
    static let secondary = adaptive(0x496857, 0xB7C5B9)
    static let tint = adaptive(0xE0E8D6, 0x293F32)
    static let line = adaptive(0xCFD3C9, 0x4C594D)
    static let warning = adaptive(0x805212, 0xF2CF88)
}

extension View {
    @ViewBuilder func primaryAction() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(Palette.accent).foregroundStyle(Palette.onAccent)
        } else {
            self.buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.onAccent)
        }
    }
    func withinSurface() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
    }
}

struct Brand: View {
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path").font(.system(size: compact ? 21 : 27, weight: .medium))
                .foregroundStyle(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("within").font(.system(size: compact ? 22 : 29, weight: .semibold)).tracking(-0.8)
                Text("by Made Ordinary").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct PrivacyFooter: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").accessibilityHidden(true)
            Text("On your Mac. No recordings or dictation history saved.")
        }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 17).padding(.horizontal, 28)
            .background(Palette.tint.opacity(0.35))
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
