# Privacy and boundaries

**Nothing crosses a boundary without your choice.**

Within transcribes on this Mac. The engineering preview has no account, telemetry, crash-report uploader, cloud transcription, or wake word. It checks for updates only when you ask, or weekly after you turn that on (see [Network and storage](#network-and-storage)).

## Recording and retention

Microphone permission is requested from the Allow button. Permission and model preparation do not start recording. A shortcut, menu action, Start practice, or a note's Record button starts capture, with a visible recording state. With the hidden Meetings developer setting on, Start meeting, Continue this meeting and Resume start meeting capture (see [Meetings](#meetings-developer-preview-hidden)). Stop, Cancel, session limits, errors, and lifecycle interruptions stop capture. Live system-indicator and interruption behavior remains a [validation requirement](VALIDATION.md).

The app does not write audio to disk. Transcripts are written only to the optional dictation history, to notes you record, to saved meetings, and to a meeting's Markdown export where you choose to save it, each described below. Audio passes through a bounded ring and rolling inference windows. Consumed ring storage is overwritten. Frameworks and macOS can retain copies; this is not a guarantee of memory erasure or protection against a compromised operating system.

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

## Meetings (developer preview, hidden)

Meeting notes are a developer preview behind a hidden setting, not a released feature. With the setting off, which is the default, Within shows no Meetings space, no Settings → Meetings section and no meeting menu items, and nothing can start meeting notes. With it on, the Meetings space can start them as described below. There are no meeting reminders in this build, and nothing watches for a call to start or end.

**The developer setting.** `showMeetingsSpace` is off unless set with `defaults write com.madeordinary.Within showMeetingsSpace -bool true`. Within reads it once at launch. When it is on, Within shows the Meetings space in its sidebar, a Meetings section in Settings and a Meeting group in the File menu. That grants no permission, creates no folder and starts nothing. Turning it off again doesn't delete saved meetings, stop their automatic deletion or change whether they are in backups.

**Starting meeting notes.** Opening the Meetings space, its library, a saved meeting or its setup never turns on the microphone or captures any app's sound. Capture starts only when you choose **Start meeting** in setup, **Continue this meeting** on a saved meeting, or **Resume** on a paused one (File → Resume Meeting does the same as Resume; File → New Meeting… only opens setup). Setup uses your microphone and, on macOS 14.2 or later if you turn it on, Zoom's sound; Zoom is the only app setup offers. Continue offers Zoom's sound only for a meeting that already included it; a microphone-only meeting continues with the microphone only. Whether to include Zoom's sound is off each time Within launches and is remembered only until it quits. Start and Continue stay unavailable until you check the box confirming that everyone in the meeting knows it's being transcribed, and Resume asks again in the cases listed below. A lock, sleep or user switch clears a box checked before it.

**Saved meetings.** A meeting is saved from the moment it starts in `~/Library/Application Support/Within/Meetings.noindex/`, one file per meeting holding its title, which meeting app it used, when it started and was last changed, its transcript with each turn's source and time, your notes, and where and why capture paused. The folder and its files are readable only by your macOS account (folder 0700, files 0600) and each file is replaced atomically. The `.noindex` name is meant to keep Spotlight out; that isn't verified yet. Audio is never written to disk, and nothing is synced or uploaded.

**The library.** The Meetings space reads the meeting files when you open it and searches them in memory; nothing is indexed or sent. Settings → Meetings also reads them to count how many a shorter retention would delete.

**Time Machine.** Settings → Meetings → **Include meetings in Time Machine backups** is off unless you turn it on, and is stored as `meetingBackups`. While it is off, the folder is excluded from Time Machine before its first file is written. Turning it on clears that exclusion from the folder and its meeting files at once; turning it off excludes the folder again, but doesn't remove copies already backed up. Within applies the stored choice to the folder at every launch, whatever the developer setting says, which also repairs a folder an interrupted first save left unmarked. If the choice can't be applied, Settings says so, with Try again, and no longer says whether meetings are in Time Machine. The choice is macOS's backup-exclusion mark, which Time Machine follows; other backup apps may not.

**Export and Copy notice.** **Export…** writes the meeting's transcript and your notes as a Markdown file, only where you choose in a save panel. That file is outside Within: wherever you save it, Spotlight may index its contents and backups or sync may copy it, and deleting the meeting doesn't delete it. **Copy notice** puts one sentence, "I'm taking private transcribed notes of this call on my Mac.", on the clipboard, only when you click it; other apps, clipboard managers and Universal Clipboard may read or sync it. Within never posts anything in a call, and has no button that copies a transcript.

**Deleting.** With the developer setting on, a finished meeting is deleted from its screen or the library, after you confirm. A meeting in progress can be discarded after you confirm: capture stops at once and its file is deleted, along with any save still pending. Deleting removes the file; on APFS and SSD storage that is not a secure erase, and existing backups may keep earlier copies.

**Retention and upkeep.** Settings → Meetings keeps meetings until you delete them, which is the default, or deletes each one 30, 90 or 365 days after it was last transcribed. The choice is stored as `meetingRetention` only when you make it, and a shorter setting that would delete saved meetings asks first, with how many. Editing a meeting's title or notes doesn't extend it, and an open meeting is never deleted. At every launch, whatever the developer setting says, and only if the meetings folder already exists, Within:
1. applies the `meetingBackups` choice to the folder, as described above;
2. removes temporary files left by an interrupted save;
3. turns any meeting a crash left open into a finished one, keeping its words and marking where capture stopped, or deletes it if it holds no words, notes or title; capture never restarts;
4. deletes meetings older than the `meetingRetention` choice.

While Within runs, it repeats step 4 every hour and whenever you change retention. Upkeep never creates the folder, never starts capture and never writes a preference.

**Settings → Privacy**, while the developer setting is off, shows how many meetings are saved, whether they are in Time Machine backups (or that the backup choice couldn't be applied, with Try again), and **Show in Finder** and **Delete all…**, whenever that folder holds any, and says so if the folder exists but can't be listed. The count is refreshed each time that section appears. Delete all asks first, then removes every meeting file it can, including ones Within couldn't read; if any can't be removed, it says so and shows how many are left. The folder stays. While the developer setting is on, Settings → Privacy says where meeting notes are kept instead.

**What meeting capture does once started.**
- A meeting starts only after you confirm that everyone in it knows it's being transcribed. This is asked for every meeting, including when you continue a saved one, and again before resuming after a lock, sleep or user switch, after the meeting app's sound went away or the output device changed, or after a pause longer than 15 minutes.
- It uses your microphone ("You") and, on macOS 14.2 or later when Zoom's sound is included, a Core Audio process tap of only Zoom's audio processes ("Others"). The tap is **unmuted**, so you keep hearing the call. It hears everything those processes play, including ringtones, notification sounds and the sound of a shared video. Labels name sources, not speakers. On macOS 14.0 and 14.1 a meeting is microphone only.
- To choose what to tap, Within reads the app identifier of each audio process on this Mac, and which output devices are the defaults, when each stretch of capture starts. During capture it reads the app identifier of each audio process that appears and pauses the meeting only if that process belongs to the meeting app; other apps' new processes are ignored. It also pauses when a tapped process goes away or the output device changes or stops. It never widens the tap. Meeting capture never takes audio from other apps, and in this build it doesn't check whether any app is using a microphone.
- Audio is transcribed on this Mac and never saved. Text is saved once it settles, when it stops changing for about 13 seconds of further audio or 15 seconds of quiet, and within about 5 seconds of settling. The still-changing tail is shown but never saved, so a crash can lose roughly the last 20–30 seconds of speech.
- One stretch of capture lasts up to three hours. Past that, capture continues in a new stretch with a notice; a few seconds around the change may be missing.
- Dictation and note recording are refused while a meeting is open, including a paused one, and a meeting can't start while either runs.
- Locking the Mac, sleep and switching users pause the meeting, mark a gap and unload the speech models; nothing resumes on its own. A disconnected, changed or stalled microphone, a microphone permission change, the meeting app's sound going away or changing as described above, Zoom's sound stalling (other apps' sound isn't checked for stalls), speech processing falling behind and a speech error also pause it.
- Quitting during a meeting asks first, then stops listening at once and saves the transcript and your notes before quitting. If the last seconds take more than 10 seconds to transcribe, Within keeps the text already settled. If saving fails, Within doesn't quit. While it saves, Within's Quit menu items are unavailable; quitting again from the Dock or another app in that time quits at once and keeps the text already settled.
- Logging out, restarting or shutting down stops capture at once without asking, then saves the same way; if saving fails, Within doesn't quit, which cancels the logout. Once a logout has stopped a meeting, it stays finished even if the logout is then canceled.

**System Audio Recording.** Including Zoom's sound uses macOS's System Audio Recording permission. The permission isn't limited to one app: it lets an app record sound from any app on this Mac. Within uses it only to tap Zoom's audio processes while meeting notes that include Zoom's sound are on, and in the developer commands below, which tap their own fixture process or the app you name. Within can't read whether the permission is allowed. macOS lists it in System Settings under Privacy & Security, where you can turn it off; Settings → Meetings has a button that opens Privacy & Security, as does the line the meeting screen shows when it isn't hearing Zoom. Whether and when macOS asks for this permission hasn't been verified for this build. Because the app binary contains the tap, `Info.plist` declares a system-audio capture usage description.

**Diagnostics** add only closed facts about the last meeting in this run of Within: why its last stretch ended, whether it used the microphone alone or with an app's sound, each source's state, why a start failed, whether this macOS supports an app's sound, whether reminders are on (always off in this build), and whether the last save failed. They never include titles, words, notes, app names, counts, durations, times or device identities.

**Developer commands** reach the meeting building blocks directly:
- `--audio-processes` prints the bundle IDs of apps with audio sessions and whether each is using input or output. It prints to the terminal only and reads no window titles, audio or call content.
- `--meeting-tap-probe` is a live check for a call you are in. It lists the named meeting app's audio processes, then taps that app's audio **unmuted** for the seconds you give. You keep hearing the call. It transcribes locally and writes the transcript only to the report you name; audio is never saved. Run it only in a call where everyone knows.
- `--apple-speech-benchmark` transcribes synthetic fixture audio with Apple's on-device speech framework (macOS 26+) for comparison. It never downloads speech assets unless you pass `allow-asset-download`.
- `--app-audio-tap-fixture` and `--two-stream-meeting-fixture` play synthetic fixture audio through `afplay` and tap only that process. The tap is muted, so nothing is heard. Those fixtures transcribe locally, save nothing, and write only the report you name.
- `--meeting-session-fixture` runs the meeting steps on synthetic fixture audio only, without the microphone. It writes synthetic meeting files and an owner-only report, with counts and timings but no transcript text, only under the output folder you name. Its `integrity` step reads the model folder and changes only a copy of it under that output folder. Its optional `tap` variant plays the fixture through `afplay` and taps only that process, muted while the tap exists: each stretch starts the player during two seconds of silence and stops it before removing the tap. Like the other tap commands, it uses the System Audio Recording permission.

## Mute while dictating (optional)

**Settings → Audio → Mute this Mac's sound while dictating** is off unless you turn it on. When it is on and a dictation recording starts, Within:
1. asks Core Audio which apps are playing sound or using a microphone (bundle IDs and running flags only, with no audio and no window or media titles);
2. mutes your default output device only if another app is playing and no other app, such as a call, is using a microphone;
3. unmutes that same device when recording stops, is canceled or fails, and on lock, sleep or quit, unless you already unmuted it.

Other apps keep playing silently, and Within's own start and stop sounds are muted too. Within never mutes during its own meeting capture, because dictation is refused while a meeting is open. Within saves only which device it muted and when. If Within quits unexpectedly, it unmutes that device at the next launch within 10 minutes; this is best effort. Within does not pause or control other apps' playback.

## Insertion and clipboard

Direct insertion requires Accessibility permission and sets selected text on the original control. The app retains target identities without reading destination text, selected text, document contents, or window titles. It refuses secure or unknown targets and rechecks focus and permissions before writing. It never synthesizes Return or Send. Uncertain writes are not automatically retried.

**Copy is explicit.** Other apps, clipboard managers, and Universal Clipboard may observe or sync copied words. Direct insertion does not use the clipboard.

Compatibility paste is experimental and off by default. It is chosen before capture only for a safe control without direct insertion capability. It uses a bounded clipboard snapshot and attempts restoration after 700 ms if no newer writer changed the clipboard. Clipboard markers and restoration cannot prevent observation or guarantee that every target reads the text in time. Synthesized paste always leaves the result available for review.

## Network and storage

The app has two network paths: **Download local model** and **update checks**. The model download contacts `huggingface.co` and allows HTTPS redirects within the `huggingface.co` and `hf.co` domain boundaries. The host receives an IP address, public model-file paths, and the app's user agent. No dictation content, app contents, account credentials, or persistent user ID are added. Downloads disable cookies, credential storage, and URL caching; files are size/hash checked before installation. About links open the browser only when clicked.

**Update checks** happen when you choose Check for Updates, or once a week if you turn that on in setup or Settings → About. Automatic checks are off unless you choose them. A check is one HTTPS GET to `https://api.github.com/repos/madeordinary/within/releases`:
- Redirects outside that path are refused.
- It uses an ephemeral session with no cookies, cache or stored credentials.
- GitHub receives your IP address and the system's default user agent. No dictation, notes, meetings, history, settings, identifiers or usage data are sent.
- Within stores only whether weekly checks are on and when it last checked.
- Found updates are shown in Settings → About with a Download button that has your browser download the release's DMG from github.com (or opens the release page if it has no single DMG). Nothing is downloaded or installed automatically; you replace the app yourself, and your settings, history, notes and saved meetings stay.

App-managed storage consists of:

- Public model files in `~/Library/Application Support/Within/Models/`.
- Temporary staging in `~/Library/Application Support/Within/Model Downloads/`.
- An empty single-instance lock in the same application-support folder.
- Optional dictation history in `~/Library/Application Support/Within/History/`, only after you choose to keep it.
- Notes you create, in `~/Library/Application Support/Within/Notes/`.
- Saved meetings in `~/Library/Application Support/Within/Meetings.noindex/`, created only when Within saves a meeting, which needs the hidden Meetings setting on.
- Preferences for `com.madeordinary.Within`: setup and interaction choices, including microphone selection, history retention, the weekly update-check choice and the last check time, the hidden `showMeetingsSpace` developer setting, and the meeting retention and Time Machine choices (`meetingRetention`, `meetingBackups`); no dictation content.

Core ML may also create OS-managed compiled-model caches. Microphone permission is required for recording. System Audio Recording is used only by an app-audio tap: meeting notes that include Zoom's sound, and the developer tap commands (see [Meetings](#meetings-developer-preview-hidden)). Accessibility is optional for practice/Copy and required for insertion and global modifier-only shortcuts. Start at login is an explicit Settings choice. The preview is a single process with Hardened Runtime and an audio-input entitlement; App Sandbox compatibility and trusted public signing remain release gates.

Custom shortcuts store only the chosen key and modifiers in preferences. The shortcut recorder operates within its own window while dictation shortcuts are paused. Choosing a single modifier enables local/global modifier, key-down, mouse-down and scroll event observation to distinguish the chosen side and reject ordinary combinations. Outside the explicit recorder, this path does not read characters, log keystrokes, or keep event history. Hardware checks run during a modifier press and during hold-to-talk release detection. Modifier shortcuts do not claim exclusive ownership; another app can use the same key.

## Diagnostics and removal

App-controlled production logging does not serialize audio or transcripts, and the speech dependency's central logging sink is disabled. Separate developer fixture commands can write requested reports from supplied fixture input. Use synthetic fixtures and review any output before sharing it. macOS may create diagnostic or crash reports outside the app's complete control; the app does not upload them.

The diagnostic preview includes the latest session's startup durations, trigger category, and whether it used Practice. These measurements stay in memory unless you explicitly save the report; they contain no audio, text, wall-clock timestamps, or destination/device identities. Diagnostic schema 5 adds the closed meeting fields described under Meetings, and an error code may name a meeting that failed to start, a meeting capture or transcription error, or a meeting that couldn't be saved.

To remove the model, use Settings → Remove model. To delete saved dictations, use Settings → History → Clear history. To delete a note, use its trash button. To delete a saved meeting, use its trash button or the library's Delete… while the Meetings developer setting is on, or Settings → Privacy → Delete all… while it is off; you can also remove a single meeting's file from the `Meetings.noindex` folder. To uninstall, quit and delete Within, optionally remove its application-support folder and preference domain, disable Start at login, and revoke Microphone, Accessibility and, if it was ever allowed, System Audio Recording permissions in System Settings → Privacy & Security.
