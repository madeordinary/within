import Foundation
import WithinCore

/// Opt-in meeting reminders for Zoom. While they are on and the Meetings space is visible, it reads which apps are
/// using a microphone every 2 seconds and offers notes once per call: two readings in a row to offer, three to
/// withdraw. It reads bundle IDs and running flags only, never audio, and starts nothing; the reminder's own buttons
/// do. Never used to end or pause a meeting.
@MainActor final class MeetingWatcher: ObservableObject {
    static let interval: Duration = .seconds(2)
    /// The reminder showing now.
    @Published private(set) var shown: MeetingReminderState.Reminder?
    /// No call is offered while this holds: a capture, a dictation's review or a shortcut change. A paused meeting doesn't.
    var captureActive: () -> Bool = { false }
    var pausedMeeting: () -> Bool = { false }
    /// After `shown` changes.
    var onChange: (() -> Void)?
    private var detector = MeetingDetector(apps: [.zoom], confirmations: 2, withdrawConfirmations: 3)
    private var state = MeetingReminderState()
    /// The only way to the process list. Nil never reads it, as in previews and native checks.
    private let read: (@MainActor () -> [AudioClientSnapshot])?
    private var polling: Task<Void, Never>?
    /// From a lock, sleep or user switch until the first reading after it ends: a call that comes up meanwhile counts as
    /// already running, so nothing is offered behind the lock screen or backfilled after unlock.
    private(set) var heldByBoundary = false
    private var releasing = false

    init(read: (@MainActor () -> [AudioClientSnapshot])?) { self.read = read }

    var isPolling: Bool { polling != nil }
    var isOn: Bool { detector.enabled }

    /// Reminders on or off. Off hides any reminder at once and stops reading; a dismissed call stays dismissed.
    func update(on: Bool) {
        detector.enabled = on
        guard on else {
            polling?.cancel(); polling = nil
            handle(.remindersOff)
            return
        }
        guard polling == nil, let read else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self else { return }
                self.observe(read(), now: Date())
            }
        }
    }

    /// One reading. Native checks call it with synthetic snapshots.
    func observe(_ clients: [AudioClientSnapshot], now: Date) {
        let held = heldByBoundary
        if releasing { heldByBoundary = false; releasing = false }
        for event in detector.observe(clients, now: now, captureActive: held || captureActive()) {
            switch event {
            case .offer(let app): handle(.offer(app, pausedMeeting: pausedMeeting()), now: now)
            case .withdraw(let app): handle(.withdraw(app), now: now)
            }
        }
    }

    /// Applies the detector's effects here; starting and finishing are left to the caller.
    @discardableResult func handle(_ event: MeetingReminderState.Event, now: Date = Date()) -> [MeetingReminderState.Effect] {
        let effects = state.handle(event, now: now)
        for effect in effects {
            switch effect {
            case .dismissCall(let app): detector.dismiss(app)
            case .snooze(let until): detector.snooze(until: until)
            case .finishPausedMeeting, .startMeeting: break
            }
        }
        if shown != state.shown { shown = state.shown; onChange?() }
        return effects
    }

    /// A capture that starts while a reminder shows hides it, and that call isn't offered again.
    func captureStarted() { if shown != nil { handle(.captureStarted) } }
    /// Lock, sleep or a user switch: hidden and dismissed, and no call is offered until a reading after it ends, so a call
    /// already coming up, or one that comes up meanwhile, isn't offered after unlock.
    func lockOrSleep() {
        heldByBoundary = true; releasing = false
        if shown != nil { handle(.lockOrSleep) }
    }
    /// Unlock, wake or the session active again: offers resume after the next reading, which still counts as held.
    func boundaryEnded() { if heldByBoundary { releasing = true } }
}
