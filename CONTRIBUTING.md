# Contributing

Within is an engineering preview of Dictation and Notes. Meetings is a hidden developer preview, off unless the `showMeetingsSpace` default is set. Keep changes focused and preserve explicit choices around microphone access, system-audio capture, model downloads, insertion, clipboard use, and retention.

For code changes, explain the user-visible problem and resulting behavior. Include relevant automated checks and distinguish simulated checks from observed behavior on a real target app. Read [architecture](docs/ARCHITECTURE.md), [privacy](docs/PRIVACY.md), and [validation](docs/VALIDATION.md).

```sh
./scripts/test.sh
./scripts/build.sh
python3 -m unittest discover -s Tests/Tooling -p 'test_*.py'
```

System-audio capture has its own rules. A meeting taps only the chosen app's audio processes, unmuted so the user keeps hearing the call, and only after an explicit start. A tapped process leaving, a new process of the same app, or an output-device change pauses the meeting; the tap is never widened. Fixture commands tap only their own `afplay` process, muted. Navigation and reminders never start capture by themselves. A change to what is tapped, how it is muted, what the reminder watcher reads, or what a meeting file holds needs a matching [privacy](docs/PRIVACY.md) update and an observed check from the [validation matrix](docs/VALIDATION.md).

Meeting changes can be exercised with synthetic audio, without a microphone or a call. After `./scripts/build.sh`:

```sh
build/Within.app/Contents/MacOS/Within --meeting-session-fixture model-directory fixture-audio seconds output-directory [tap] [run|crash|recover|savefail|integrity]
```

It drives the real `MeetingController` and writes synthetic meeting files and a report only under the output folder. The report holds counts, timings and pass/fail checks, never transcript text. `tap` works with `run` and `savefail` only: it taps the fixture's own `afplay` process and uses the System Audio Recording permission. Live tap commands are different. `--meeting-tap-probe` taps a real call unmuted and writes that call's transcript to its report. Only the project owner runs it, in a call where everyone has agreed to be transcribed.

After staging the intended files, review `git diff --cached` and run:

```sh
python3 scripts/publication_policy.py --all-history
```

The [publication policy](docs/PUBLICATION.md) applies to files, commit messages, issues, pull requests, and release attachments. New public paths need an explicit allowlist change. Avoid bulk staging from a checkout containing working notes. A passing automated check does not replace reading the proposed content.

Use synthetic text and minimal reproduction steps. Do not attach private dictation, real meeting transcripts or notes, credentials, raw diagnostics, personal paths, or unreviewed screenshots. Never attach a `--meeting-tap-probe` report. Keep source and dependency license notices intact. Report security or privacy vulnerabilities through [private vulnerability reporting](https://github.com/madeordinary/within/security/advisories/new).
