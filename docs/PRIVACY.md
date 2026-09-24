# Privacy and boundaries

**Nothing crosses a boundary without your choice.**

Within transcribes on this Mac. The engineering preview has no account, telemetry, crash-report uploader, cloud transcription, wake word, or automatic update check.

## Recording and retention

Microphone permission is requested from the Allow button. Permission and model preparation do not start recording. A shortcut, menu action, or Start practice action starts capture, with a visible recording state. Stop, Cancel, session limits, errors, and lifecycle interruptions stop capture. Live system-indicator and interruption behavior remains a [validation requirement](VALIDATION.md).

The app does not write audio or transcripts to disk. Audio passes through a bounded ring and rolling inference windows. Consumed ring storage is overwritten. Frameworks and macOS can retain copies; this is not a guarantee of memory erasure or protection against a compromised operating system.

Pending words remain in memory for insertion or recovery. Practice text remains in its visible field until Clear or app exit. Lock/sleep cancels active capture; already-recovered words remain pending and their window is hidden. There is no transcript-history database. Model state may remain loaded until memory pressure, lock/sleep, removal, or quit.

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
- Preferences for `com.madeordinary.Within`: setup and interaction choices, including microphone selection; no dictation content.

Core ML may also create OS-managed compiled-model caches. Microphone permission is required for recording. Accessibility is optional for practice/Copy and required for insertion. Start at login is an explicit Settings choice. The preview is a single process with Hardened Runtime and an audio-input entitlement; App Sandbox compatibility and trusted public signing remain release gates.

## Diagnostics and removal

App-controlled production logging does not serialize audio or transcripts, and the speech dependency's central logging sink is disabled. Separate developer fixture commands can write requested reports from supplied fixture input. Use synthetic fixtures and review any output before sharing it. macOS may create diagnostic or crash reports outside the app's complete control; the app does not upload them.

To remove the model, use Settings → Remove model. To uninstall, quit and delete Within, optionally remove its application-support folder and preference domain, disable Start at login, and revoke Microphone and Accessibility permissions in System Settings.
