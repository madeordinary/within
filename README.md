# Within, by Made Ordinary

<p align="center">
  <img src="docs/brand/within-logo.png" alt="Within" width="180">
</p>

Native macOS dictation with on-device transcription and explicit control over recording, insertion, and copying.

**Engineering preview.** This repository contains source for contributors. It is not a signed, notarized public release. Cross-app compatibility, accessibility, and supported-system validation are still pending; see [validation](docs/VALIDATION.md).

“Nothing crosses a boundary without your choice.”

- Recording starts only through an explicit shortcut or app action, including Record in a note.
- A separately downloaded Parakeet model transcribes locally.
- Direct insertion uses Accessibility and rechecks the original destination.
- Uncertain insertion keeps words available for review, explicit Copy, or Discard.
- No account, telemetry, or cloud transcription. Dictation history is off until you choose it, and then stays on this Mac for as long as you pick.
- Notes: type or talk into a page; words appear as you speak and are saved only on this Mac. Audio is never saved.
- Optional: mute your Mac's sound while you dictate (for example over YouTube or music); calls are never muted.

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

The scripts fetch a pinned FluidAudio source revision, apply the checked-in patch, and build locally. Dependency preparation requires network access. Builds are signed ad hoc unless the maintainer's self-signed "Within Signing" certificate is in the keychain; neither is an Apple-trusted distribution identity. Model weights are downloaded separately after choosing **Download local model** in the app.

Granting Microphone permission does not start recording. Practice and explicit Copy work without Accessibility permission; direct insertion requires it. Home and setup include a microphone selector. The default shortcut is Control–Shift–Space; choose **Change…** on Home, in setup or Settings to record another combination or a single left/right modifier, including Right Control. Modifier-only shortcuts require Accessibility for use in other apps. Shortcut editing never starts dictation. Compatibility paste is experimental and off by default.

## Using the app

Within uses one main window and appears in the Dock, Command-Tab switcher, and menu bar. First launch walks through setup in that window. On Home, expand **Try dictation** for a temporary practice field and sample phrase. Recording starts only when you choose **Start practice** or use the shortcut while the area is open and Within is active. For another app, focus its text field before using the shortcut.

Open Settings with **Command-comma** or the gear button, and Help from the toolbar or Help menu. Both use the same window; **Back** returns to the previous page. Closing the window leaves shortcuts and the menu bar available; click Within in the Dock to reopen it. Leaving an active practice session asks before canceling. Practice text survives navigation until you clear it or quit. Recovery words also survive Back or closing; choose **Review words** to return. **Quit Within** exits completely and asks before discarding active or pending dictation.

After building, you can copy `build/Within.app` into Applications for a stable launch location. Local ad-hoc rebuilds may require macOS to approve permissions again. Native Liquid Glass controls are used on macOS 26 and later, with standard controls on earlier systems; content supports light and dark appearance.

## Updates

Test builds are published as GitHub pre-releases tagged `v<version>-build<number>`. Choose **Check for Updates…** in the Within menu, or turn on the weekly check in setup or Settings → About. It is off unless you choose it. A check asks GitHub for this repository's release list and sends no dictation, notes or usage data. To update, quit Within, download the new DMG and replace the app; settings, history and notes stay. Test builds from 14 on are signed with the same self-signed Made Ordinary certificate, so updates keep the permissions you've allowed; updating from build 13 or earlier asks for Accessibility once more. Until builds are signed with a Developer ID, macOS may ask you to confirm a new copy with Open Anyway.

Maintainers build a candidate with `./scripts/release.sh`. It runs the tests and checks, then writes the DMG, checksums and draft notes under `build/release/`. It never uploads; publishing is a separate `gh release create` step.

## Contribute

Read [contributing](CONTRIBUTING.md), [architecture](docs/ARCHITECTURE.md), and the [publication policy](docs/PUBLICATION.md). Reports should use synthetic text and include only the details needed to reproduce the issue.

The application source is MIT licensed. Model weights and dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
