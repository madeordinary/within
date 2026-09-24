# Architecture

Within is a native macOS menu-bar executable built with SwiftUI and AppKit. Dictation is its only product module.

| Component | Responsibility |
| --- | --- |
| `WithinCore` | Session, target, shortcut, clipboard-generation, model-integrity, and download-boundary policy without GUI or device I/O. |
| `WithinAudioBuffer` | Preallocated C single-producer/single-consumer ring with bounded backlog, total samples, and explicit close/drain handling. |
| `AppModel` | Main-actor session transitions; session IDs reject late output and prevent overlapping capture or loss of pending words. |
| `LocalSpeech` | Actor-owned local Parakeet inference with serial sliding-window ingress. |
| `ModelStore` | Explicit download, constrained redirects, bounded staging, per-file size/hash validation, and atomic installation. |
| `AccessibilityTarget` | Non-content target identities, secure-control refusal, exact target revalidation, and selected-text insertion. |
| `ShortcutManager` / `AppDelegate` | Explicit shortcut modes, app windows, lifecycle, and single-instance ownership. |

Capture follows an explicit action, verified model preparation, an audio tap, the bounded ring, and a serial inference consumer. The ring bounds queued audio to 20 seconds and a session is capped at five minutes. Overflow stops capture; available text goes to review. Audio is not persisted by the app.

The original application, window, control, focus history, and secure-input state are checked before insertion. A failed write is uncertain and is not automatically retried. Recovery keeps words available for an explicit user action. Accessibility cannot make focus checking and writing atomic, so real target-app validation remains required.

Compatibility paste is an experimental, explicit setting. It is selected before capture only when a safe control lacks direct insertion capability. It snapshots bounded clipboard data and restores it only if no other writer changed the clipboard generation. Synthesized paste cannot confirm insertion; the result remains available for review.

## Dependencies and integrity

The checked-in FluidAudio patch disables central log sinks, adds serial bounded ingress, and surfaces individual window failures. Unused NeMo binary resolution is removed. Bootstrap pins the source revision and checks the patch; original license notices are retained.

The bundled manifest pins model revision, file sizes, and SHA-256 hashes. A staged download must match the manifest before installation. Model integrity is checked before sessions. A trusted app distribution signature is necessary to authenticate that manifest for public distribution.

Changes to these boundaries need appropriate core tests and, where OS behavior is involved, observed checks from the [validation matrix](VALIDATION.md).
