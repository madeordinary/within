# Privacy and boundaries

**Nothing crosses a boundary without your choice.**

Within transcribes on this Mac. The engineering preview has no account, telemetry, crash-report uploader, cloud transcription, wake word, or automatic update check.

## Recording and retention

Microphone permission is requested from the Allow button. Permission and model preparation do not start recording. A shortcut, menu action, or Start practice action starts capture, with a visible recording state. Stop, Cancel, session limits, errors, and lifecycle interruptions stop capture. Live system-indicator and interruption behavior remains a [validation requirement](VALIDATION.md).

The app does not write audio to disk. Transcripts are written only to the optional dictation history described below. Audio passes through a bounded ring and rolling inference windows. Consumed ring storage is overwritten. Frameworks and macOS can retain copies; this is not a guarantee of memory erasure or protection against a compromised operating system.

After recording, the app may retain the stopped audio-engine object for the same selected microphone. It stops the audio hardware and removes the tap. Buffered audio can finish transcription before it is released; the stopped engine retains no recording buffer and does not keep the microphone running between sessions.

Pending words remain in memory for insertion or recovery. Practice text remains in its visible field until Clear or app exit. Lock/sleep cancels active capture; already-recovered words remain pending and their window is hidden. Model state may remain loaded until memory pressure, lock/sleep, removal, or quit.

## Optional dictation history

History is off until you choose it in setup, in the Dictation space, or in Settings → History. Retention can be 24 hours, 7 days, 30 days, or until you delete it; Off stops saving. Shortening retention or turning history off asks before deleting older entries. Upgrading never starts saving without that choice.

Only final text and its time are saved, after a confirmed insertion, a confirmed return-and-insert from recovery, or an explicit Copy from recovery. Practice, canceled, and discarded words are never saved. No audio, destination app, window title, or field content is stored. Entries are pruned on launch, when saving, and hourly.

History is one file, `~/Library/Application Support/Within/History/dictation-history.json`, readable only by your macOS account (folder 0700, file 0600) and replaced atomically. The folder is excluded from Time Machine backups. Nothing is synced or uploaded. Copying an entry uses the clipboard with the same caveats as recovery Copy. Deleting an entry or clearing history rewrites or removes the file; on APFS and SSD storage that is not a secure erase. If FileVault is on, it protects the file while the Mac is shut down; it does not hide the file from apps running under your account. History content and counts never appear in diagnostics.

## Voice notes

Notes are pages you type into or talk into. Record starts the microphone for that note only; Stop, lock, sleep, an audio stall or a permission change ends the recording and keeps every word heard so far, with a visible marker where it paused. Recording again adds a new paragraph. Only one recording runs at a time: dictation is refused while a note records, and Escape never cancels a note recording.

While recording, text appears as the local model processes it. Confirmed words are also written to the note file about every ten seconds so a crash keeps them. Audio is never written to disk. One recording is limited to three hours.

Each note is one file in `~/Library/Application Support/Within/Notes/`, readable only by your macOS account (folder 0700, files 0600) and replaced atomically. Unlike dictation history, notes are deliberate documents and **are included in Time Machine backups**. Nothing is synced or uploaded. Deleting a note removes its file; on APFS and SSD storage that is not a secure erase, and existing backups keep earlier copies until they expire.

## Meetings groundwork (not a feature yet)

The app contains building blocks for a future Meetings space. **No meeting capture or meeting detection runs in the app today**, and there is no Meetings screen. The building blocks are:
- per-app audio capture through a Core Audio process tap (macOS 14.2 or later);
- two local speech sessions;
- rules for noticing that a meeting app started using the microphone.

These paths are reachable only through developer commands:
- `--audio-processes` prints the bundle IDs of apps with audio sessions and whether each is using input or output. It prints to the terminal only and reads no window titles, audio or call content.
- `--app-audio-tap-fixture` and `--two-stream-meeting-fixture` play synthetic fixture audio through `afplay` and tap only that process. The tap is muted, so nothing is heard. Those fixtures transcribe locally, save nothing, and write only the report you name.

Because the app binary contains the tap, `Info.plist` declares a system-audio capture usage description. macOS asks for System Audio Recording permission only when a tap actually runs, which today means one of those developer commands. Any future Meetings feature will document its own consent, detection, capture and storage behavior here before it ships.

## Insertion and clipboard

Direct insertion requires Accessibility permission and sets selected text on the original control. The app retains target identities without reading destination text, selected text, document contents, or window titles. It refuses secure or unknown targets and rechecks focus and permissions before writing. It never synthesizes Return or Send. Uncertain writes are not automatically retried.

**Copy is explicit.** Other apps, clipboard managers, and Universal Clipboard may observe or sync copied words. Direct insertion does not use the clipboard.

Compatibility paste is experimental and off by default. It is chosen before capture only for a safe control without direct insertion capability. It uses a bounded clipboard snapshot and attempts restoration after 700 ms if no newer writer changed the clipboard. Clipboard markers and restoration cannot prevent observation or guarantee that every target reads the text in time. Synthesized paste always leaves the result available for review.

## Network and storage

The app's implemented network path is **Download local model**. It contacts `huggingface.co` and allows HTTPS redirects within the `huggingface.co` and `hf.co` domain boundaries. The host receives an IP address, public model-file paths, and the app's user agent. No dictation content, app contents, account credentials, or persistent user ID are added. Downloads disable cookies, credential storage, and URL caching; files are size/hash checked before installation. About links open the browser only when clicked.

App-managed storage consists of:

- Public model files in `~/Library/Application Support/Within/Models/`.
- Temporary staging in `~/Library/Application Support/Within/Model Downloads/`.
- An empty single-instance lock in the same application-support folder.
- Optional dictation history in `~/Library/Application Support/Within/History/`, only after you choose to keep it.
- Notes you create, in `~/Library/Application Support/Within/Notes/`.
- Preferences for `com.madeordinary.Within`: setup and interaction choices, including microphone selection and history retention; no dictation content.

Core ML may also create OS-managed compiled-model caches. Microphone permission is required for recording. Accessibility is optional for practice/Copy and required for insertion and global modifier-only shortcuts. Start at login is an explicit Settings choice. The preview is a single process with Hardened Runtime and an audio-input entitlement; App Sandbox compatibility and trusted public signing remain release gates.

Custom shortcuts store only the chosen key and modifiers in preferences. The shortcut recorder operates within its own window while dictation shortcuts are paused. Choosing a single modifier enables local/global modifier, key-down, mouse-down and scroll event observation to distinguish the chosen side and reject ordinary combinations. Outside the explicit recorder, this path does not read characters, log keystrokes, or keep event history. Hardware checks run during a modifier press and during hold-to-talk release detection. Modifier shortcuts do not claim exclusive ownership; another app can use the same key.

## Diagnostics and removal

App-controlled production logging does not serialize audio or transcripts, and the speech dependency's central logging sink is disabled. Separate developer fixture commands can write requested reports from supplied fixture input. Use synthetic fixtures and review any output before sharing it. macOS may create diagnostic or crash reports outside the app's complete control; the app does not upload them.

The diagnostic preview includes the latest session's startup durations, trigger category, and whether it used Practice. These measurements stay in memory unless you explicitly save the report; they contain no audio, text, wall-clock timestamps, or destination/device identities.

To remove the model, use Settings → Remove model. To delete saved dictations, use Settings → History → Clear history. To delete a note, use its trash button. To uninstall, quit and delete Within, optionally remove its application-support folder and preference domain, disable Start at login, and revoke Microphone and Accessibility permissions in System Settings.
