# Validation and release gates

Within is an engineering preview. Implementation and automated checks do not establish live microphone behavior, app compatibility, accessibility, accuracy, or release readiness.

## Reproducible automated checks

```sh
./scripts/test.sh
./scripts/build.sh
python3 -m unittest discover -s Tests/Tooling -p 'test_*.py'
python3 scripts/publication_policy.py --all-history
```

The app test script runs deterministic core tests, including notes, history and meeting-detection rules, and the C audio-ring stress check under ThreadSanitizer. Developer fixture commands (`--long-session-soak`, `--live-text-benchmark`, `--app-audio-tap-fixture`, `--two-stream-meeting-fixture`, `--apple-speech-benchmark`) measure long sessions, live-text latency, per-app capture and an Apple on-device speech comparison with synthetic audio only. `--meeting-tap-probe` is a live check during a real call and is not an automated test. The build script makes and verifies a locally signed app bundle. Publication tests check repository/package boundaries. None of these commands is evidence of live cross-app insertion or a notarized release.

## Required hands-on validation

All rows remain pending until relevant observed results are reviewed. Use empty documents and synthetic speech/text. Share only the minimal environment, reproduction, result, and limitation needed to assess a claim.

| Area | Required evidence | Status |
| --- | --- | --- |
| Permissions and shortcuts | Grant, deny, revoke; custom chord recording; left/right modifier identity; hold/toggle/release; accidental modifier+key rejection; missed key-up; conflicts with other dictation apps; secure input; supported OS and keyboard layouts. | Pending |
| Native app surfaces | Dock/Command-Tab, close/reopen, menus, Settings, setup gating, practice routing, recovery retention, and light/dark layouts on supported systems. | Pending |
| Capture and lifecycle | Actual microphone indicator; Stop/Cancel; five-minute limit; device changes; lock/sleep; user switching; quit. | Pending |
| Dictation history | Off until chosen; saving only after confirmed insertion or explicit Copy; retention pruning and confirmations; file permissions and backup exclusion on a real Mac; clear and delete. | Pending |
| Voice notes | Live microphone recording with the system indicator; live text; Stop and every automatic pause (lock, sleep, stall, permission change, backlog, three-hour limit) keeping words with visible markers; ten-second checkpoints surviving a forced quit; dictation refused while recording; multi-hour live sessions and 8 GB baseline memory. | Pending |
| Mute while dictating | YouTube in Chrome and Firefox, Spotify and podcast apps go silent and return; no mute during Zoom, Teams, FaceTime or browser calls; built-in, Bluetooth and HDMI outputs (some cannot be muted); output change during dictation; user unmuting mid-dictation; cancel, lock and quit restore; relaunch after a forced quit. | Pending |
| Updates | Manual and weekly checks against published releases, including none published, newer, same and older builds; request contents and domain observed on the network; replacing the app keeps settings, history and notes; permissions after an unsigned update; files from earlier builds still open. | Pending |
| Meetings (groundwork only) | Unmuted per-app capture during real Zoom and Teams calls, including helper processes; microphone echo with speakers versus headphones; permission prompts on a fresh install; detection on real calls, dismiss and snooze; two concurrent speech sessions over multi-hour meetings and on an 8 GB Mac; participant-consent review. | Pending |
| Insertion and recovery | Original-target identity, focus changes, selection/undo, closed controls, uncertain writes, and keyboard recovery in native apps, browsers, and complex editors. | Pending |
| Optional compatibility paste | Explicit choice, modifier release, clipboard managers/sharing, newer-copy preservation, slow readers, and restoration failure. | Pending |
| Model and runtime | Interrupted download, low disk, corruption refusal, memory pressure, long sessions, cold/warm readiness, and baseline M1 8 GB performance. | Pending |
| Speech quality | Representative English speakers, accents, noise, soft speech, and word boundaries; measurements with stated methodology. | Pending |
| Accessibility | VoiceOver, keyboard-only setup/recovery, toggle mode, contrast, reduced motion, and display scaling. | Pending |
| Distribution and privacy | Supported macOS versions, independent network observation, diagnostic review, sandbox feasibility, Developer ID/notarization, clean installation, and removal. | Pending |

Do not advertise an app as compatible or a release gate as passed from synthetic tests alone. A public validation claim must identify its scope and limitations without including raw private input or diagnostics.
