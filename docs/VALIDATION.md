# Validation and release gates

Within is an engineering preview. Implementation and automated checks do not establish live microphone behavior, app compatibility, accessibility, accuracy, or release readiness.

## Reproducible automated checks

```sh
./scripts/test.sh
./scripts/build.sh
python3 -m unittest discover -s Tests/Tooling -p 'test_*.py'
python3 scripts/publication_policy.py --all-history
```

The app test script runs deterministic core tests and the C audio-ring stress check under ThreadSanitizer. The build script makes and verifies a locally signed app bundle. Publication tests check repository/package boundaries. None of these commands is evidence of live cross-app insertion or a notarized release.

## Required hands-on validation

All rows remain pending until relevant observed results are reviewed. Use empty documents and synthetic speech/text. Share only the minimal environment, reproduction, result, and limitation needed to assess a claim.

| Area | Required evidence | Status |
| --- | --- | --- |
| Permissions and shortcuts | Grant, deny, revoke; hold/toggle/release; missed key-up; secure input; supported OS and keyboard behavior. | Pending |
| Capture and lifecycle | Actual microphone indicator; Stop/Cancel; five-minute limit; device changes; lock/sleep; user switching; quit. | Pending |
| Insertion and recovery | Original-target identity, focus changes, selection/undo, closed controls, uncertain writes, and keyboard recovery in native apps, browsers, and complex editors. | Pending |
| Optional compatibility paste | Explicit choice, modifier release, clipboard managers/sharing, newer-copy preservation, slow readers, and restoration failure. | Pending |
| Model and runtime | Interrupted download, low disk, corruption refusal, memory pressure, long sessions, cold/warm readiness, and baseline M1 8 GB performance. | Pending |
| Speech quality | Representative English speakers, accents, noise, soft speech, and word boundaries; measurements with stated methodology. | Pending |
| Accessibility | VoiceOver, keyboard-only setup/recovery, toggle mode, contrast, reduced motion, and display scaling. | Pending |
| Distribution and privacy | Supported macOS versions, independent network observation, diagnostic review, sandbox feasibility, Developer ID/notarization, clean installation, and removal. | Pending |

Do not advertise an app as compatible or a release gate as passed from synthetic tests alone. A public validation claim must identify its scope and limitations without including raw private input or diagnostics.
