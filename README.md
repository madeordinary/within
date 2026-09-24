# Within, by Made Ordinary

<p align="center">
  <img src="docs/brand/within-logo.png" alt="Within" width="180">
</p>

Native macOS dictation with on-device transcription and explicit control over recording, insertion, and copying.

**Engineering preview.** This repository contains source for contributors. It is not a signed, notarized public release. Cross-app compatibility, accessibility, and supported-system validation are still pending; see [validation](docs/VALIDATION.md).

“Nothing crosses a boundary without your choice.”

- Recording starts only through an explicit shortcut or app action.
- A separately downloaded Parakeet model transcribes locally.
- Direct insertion uses Accessibility and rechecks the original destination.
- Uncertain insertion keeps words available for review, explicit Copy, or Discard.
- No account, telemetry, cloud transcription, or transcript history.

See [privacy and boundaries](docs/PRIVACY.md) before trying the preview.

## Build and test

Use an Apple Silicon Mac and Xcode with Swift 6.2. The deployment target is macOS 14; this is not a claim that every supported OS/hardware combination has been validated.

```sh
git clone https://github.com/madeordinary/within.git
cd within
./scripts/test.sh
./scripts/build.sh
open build/Within.app
```

The scripts fetch a pinned FluidAudio source revision, apply the checked-in patch, and build locally. Dependency preparation requires network access. The default app signature is ad hoc; it does not establish a trusted distribution identity. Model weights are downloaded separately after choosing **Download local model** in the app.

Granting Microphone permission does not start recording. Practice and explicit Copy work without Accessibility permission; direct insertion requires it. The default shortcut is Control–Shift–Space, with Control–Shift–D available in Settings. Compatibility paste is experimental and off by default.

## Contribute

Read [contributing](CONTRIBUTING.md), [architecture](docs/ARCHITECTURE.md), and the [publication policy](docs/PUBLICATION.md). Reports should use synthetic text and include only the details needed to reproduce the issue.

The application source is MIT licensed. Model weights and dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
