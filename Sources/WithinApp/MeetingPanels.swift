import AppKit
import SwiftUI
import WithinCore

/// What the reminder and the menu-path sheet say. Every sentence is a proposal pending the owner's copy and legal review.
struct MeetingReminderContent: Equatable {
    /// Why notes can't start now; the reminder then offers Open Within instead of Start notes.
    let blocker: String?
    /// An earlier meeting is paused; Start notes finishes it first.
    let paused: Bool
    /// Zoom's sound was never included in this run: it is explained before it can be, and the default is the microphone alone.
    let firstTime: Bool
    let includesZoomSound: Bool

    static let title = "Zoom call detected"
    static let acknowledgment = "Nothing is recording. Start notes only if everyone in the call knows they’re being transcribed."
    static let pausedLine = "Your earlier meeting notes are paused. Start notes finishes them first."
    static let storage = "Saved on this Mac as you go; audio is never kept. Muting in Zoom doesn’t pause Within."
    static let notReady = "Within can’t start notes yet."
    /// Said when Start notes opens the first-time explanation, since the button just used is gone.
    static let explaining = "Choose whether to include Zoom’s sound, or start with your microphone only."
    static let snooze = "Snooze reminders 1 hour"
    static let accessibilityName = "Within meeting reminder"

    var sources: String {
        firstTime ? "Will transcribe: your microphone, and Zoom’s sound only if you include it"
            : includesZoomSound ? "Will transcribe: your microphone + Zoom’s sound" : "Will transcribe: your microphone only"
    }
    /// A disclosure control, not a fourth action: it changes this start only.
    var sourcesLink: String? { firstTime ? nil : includesZoomSound ? "Microphone only this time" : "Include Zoom’s sound" }
}

/// The reminder's window: it floats over every space without activating Within and is never made key when shown, so
/// typing in the call is never taken over; a click into it makes it key, through `ReminderHostingView`. Top-right under
/// the menu bar, away from Zoom's controls. Like the capsule, it isn't hidden from screen sharing. Nothing in it animates.
final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init(content: NSView) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: ReminderView.width, height: 160), styleMask: [.nonactivatingPanel, .borderless],
                  backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = true
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; hidesOnDeactivate = false
        // The corners are clear; everything inside them is opaque.
        isOpaque = false; backgroundColor = .clear; hasShadow = true; animationBehavior = .none
        isReleasedWhenClosed = false; title = MeetingReminderContent.accessibilityName
        contentView = content
    }

    /// Sized to its content and placed top-right under the menu bar, or under `top` when the meeting capsule is there.
    func place(on screen: NSScreen?, below top: CGFloat? = nil) { placeTopRight(on: screen, below: top) }
}

/// The reminder's content. A click into it makes the panel key without activating Within, and that same click still
/// acts, so after one click its buttons can be used by keyboard. Its links, which AppKit draws, act without making it key.
final class ReminderHostingView<Content: View>: NSHostingView<Content> {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSPanel {
    /// Sized to its content, right-aligned under the menu bar or under `top`.
    func placeTopRight(on screen: NSScreen?, below top: CGFloat? = nil) {
        contentView?.layoutSubtreeIfNeeded()
        guard let visible = screen?.visibleFrame, let size = contentView?.fittingSize else { return }
        let maxY = top ?? visible.maxY - 12
        setFrame(NSRect(x: visible.maxX - size.width - 16, y: maxY - size.height, width: size.width, height: size.height), display: true)
    }
}

/// The reminder: the acknowledgment, the sources with their one-start link, the storage and mute line, and D4's three
/// actions. Opaque, with a stronger edge and text under Increase Contrast. One labelled group for VoiceOver.
struct ReminderView: View {
    static let width: CGFloat = 440
    @ObservedObject var model: AppModel
    @ObservedObject var watcher: MeetingWatcher
    @ObservedObject var meetings: MeetingController
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let content = model.meetingReminderContent {
            let increased = contrast == .increased
            VStack(alignment: .leading, spacing: 10) {
                Label { Text(MeetingReminderContent.title).font(.system(size: 14, weight: .semibold)) } icon: {
                    Image(systemName: "person.2.wave.2").foregroundStyle(Palette.accent)
                }.accessibilityAddTraits(.isHeader)
                if content.paused {
                    VStack(alignment: .leading, spacing: 4) {
                        wrapped(MeetingReminderContent.pausedLine)
                        ReminderLink(title: "Show paused meeting", action: model.reminderShowPausedMeeting)
                    }
                }
                if let blocker = content.blocker {
                    wrapped("\(MeetingReminderContent.notReady) \(blocker)")
                    actions { Button("Open Within", action: model.reminderOpenWithin).primaryAction() }
                } else {
                    wrapped(MeetingReminderContent.acknowledgment)
                    MeetingReminderSources(model: model, content: content)
                    if model.reminderExplaining {
                        wrapped(MeetingWords.appSoundScope).foregroundStyle(increased ? Palette.text : Palette.secondary)
                        wrapped(MeetingWords.appSoundPermission).foregroundStyle(increased ? Palette.text : Palette.secondary)
                    }
                    wrapped(MeetingReminderContent.storage).foregroundStyle(increased ? Palette.text : Palette.secondary)
                    if model.reminderExplaining {
                        let include = Button("Include Zoom’s sound and start") { _ = model.reminderStart(includingZoomSound: true) }.primaryAction()
                        let microphone = Button("Microphone only") { _ = model.reminderStart(includingZoomSound: false) }.quietAction()
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { include; microphone }
                            VStack(alignment: .leading, spacing: 8) { include; microphone }
                        }
                        HStack(spacing: 8) { snoozeAndDismiss }
                    } else {
                        actions { Button("Start notes") { _ = model.reminderStartNotes() }.primaryAction() }
                    }
                }
            }
            .font(.system(size: 12)).foregroundStyle(Palette.text).tint(Palette.accent)
            .padding(16).frame(width: Self.width, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(increased ? Palette.text : Palette.line, lineWidth: increased ? 2 : 1))
            .accessibilityElement(children: .contain).accessibilityLabel(MeetingReminderContent.accessibilityName)
        }
    }

    private func wrapped(_ text: String) -> some View { Text(text).fixedSize(horizontal: false, vertical: true) }

    /// The start, then Snooze and Dismiss: one row when it fits, else the start above the other two.
    private func actions<Start: View>(@ViewBuilder _ start: () -> Start) -> some View {
        let start = start()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { start; snoozeAndDismiss }
            VStack(alignment: .leading, spacing: 8) { start; HStack(spacing: 8) { snoozeAndDismiss } }
        }
    }

    @ViewBuilder private var snoozeAndDismiss: some View {
        Button(MeetingReminderContent.snooze, action: model.reminderSnooze).quietAction()
        Button("Dismiss", action: model.reminderDismiss).quietAction()
    }
}

/// "Will transcribe: …" and its link, which changes this start only.
private struct MeetingReminderSources: View {
    @ObservedObject var model: AppModel
    let content: MeetingReminderContent
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(content.sources).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if let link = content.sourcesLink {
                ReminderLink(title: link, action: model.toggleReminderZoomSound).accessibilityHint("Changes the sources for this start only")
            }
        }
    }
}

/// A link that looks like one without relying on colour: accent and underlined.
private struct ReminderLink: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).underline() }.buttonStyle(.link).foregroundStyle(Palette.accent)
    }
}

/// The menu path's sheet: the reminder's full text over Within. Its default button starts; Cancel or Escape starts
/// nothing. Until Zoom's sound was included in this run, it is explained here and the default is the microphone alone.
struct MeetingStartSheet: View {
    static let width: CGFloat = 560
    @ObservedObject var model: AppModel
    @ObservedObject var watcher: MeetingWatcher
    @ObservedObject var meetings: MeetingController

    var body: some View {
        let content = model.meetingReminderContent
        let blocked = content?.blocker != nil || content == nil
        VStack(alignment: .leading, spacing: 14) {
            Text("Start notes for this Zoom call?").font(Typography.display(22)).accessibilityAddTraits(.isHeader)
            if let content {
                if content.paused { Label(MeetingReminderContent.pausedLine, systemImage: "pause.circle").fixedSize(horizontal: false, vertical: true) }
                if let blocker = content.blocker {
                    Label("\(MeetingReminderContent.notReady) \(blocker)", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(MeetingReminderContent.acknowledgment).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                MeetingReminderSources(model: model, content: content)
                if content.firstTime {
                    Group {
                        Text(MeetingWords.appSoundScope)
                        Text(MeetingWords.appSoundPermission)
                    }.foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Label(MeetingReminderContent.storage, systemImage: "lock.shield").foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel", action: model.closeMeetingStartSheet).quietAction().keyboardShortcut(.cancelAction)
                if content?.firstTime == true {
                    Button("Include Zoom’s sound and start") { _ = model.reminderStart(includingZoomSound: true) }.quietAction().disabled(blocked)
                }
                Button(content?.firstTime == true ? "Microphone only" : "Start notes") { _ = model.meetingStartSheetDefault() }
                    .primaryAction().keyboardShortcut(.defaultAction).disabled(blocked)
            }.padding(.top, 4)
        }.font(.system(size: 12)).foregroundStyle(Palette.text).tint(Palette.accent)
            .padding(24).frame(width: Self.width, alignment: .leading).background(Palette.canvas)
    }
}

/// What the meeting capsule says. Every sentence is a proposal pending the owner's copy and legal review.
struct MeetingCapsuleContent: Equatable {
    /// Why the capsule is taller than its one row.
    enum Expansion: Equatable {
        /// The first minute of each stretch: what is transcribed, and that Zoom's mute doesn't pause it.
        case firstMinute
        /// Paused for a reason the user didn't choose, such as a lock or a lost source; never a call's end.
        case paused(String)
        /// The dictation shortcut was just refused.
        case dictationRefused
    }
    enum Action: Equatable { case pause, resume }
    let title: String
    let spokenTitle: String
    let symbol: String
    /// Not hearing the meeting app.
    let warning: Bool
    let sources: String
    let expansion: Expansion?
    let action: Action?
    /// "Resume…" when the call may have changed, since Resume then shows the meeting's acknowledgment.
    let resumeTitle: String
    let resumeBlocker: String?
    /// Shown beside Resume while paused and expanded.
    let finishTitle: String?

    static let muteLine = MeetingWords.muteHint
    static let dictationOff = "Dictation is off until you finish the meeting."
    static let accessibilityName = "Within meeting notes"
    static let showAction = "Show meeting"

    /// The expansion's lines, then why Resume is unavailable, in words as well as its dimmed button.
    var lines: [String] {
        let lines: [String] = switch expansion {
        case .firstMinute: [sources, Self.muteLine]
        case .paused(let reason): [reason]
        case .dictationRefused: [Self.dictationOff]
        case nil: []
        }
        return lines + [resumeBlocker].compactMap { $0 }
    }
    /// What changes the capsule's height; its time changing doesn't.
    var layout: [String] { [lines.joined(separator: "\n"), finishTitle ?? "", action == nil ? "" : "action"] }
}

extension RecordingPanel {
    /// The meeting capsule's window: the pill's non-key panel, floating on every space without activating Within. It
    /// is deliberately left visible in screen sharing, so people who see a shared screen can see notes are on.
    static func meetingCapsule(content: NSView) -> RecordingPanel {
        let panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: MeetingCapsuleView.width, height: 48), styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false; panel.title = MeetingCapsuleContent.accessibilityName
        panel.contentView = content
        return panel
    }
}

/// The meeting capsule: its state and time, Pause or Resume, and Show, with a second part for the first minute, a pause
/// Within didn't choose, or a refused dictation. Opaque and never pill-like, with a stronger edge under Increase
/// Contrast. Nothing in it moves. Every control is also in the status menu, since the capsule never takes focus.
struct MeetingCapsuleView: View {
    static let width: CGFloat = 380
    @ObservedObject var model: AppModel
    @ObservedObject var meetings: MeetingController
    /// Called after the capsule's height may have changed.
    var layoutChanged: () -> Void = {}
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // Resume gains its ellipsis once a long pause needs the acknowledgment again.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if let content = model.meetingCapsuleContent { capsule(content) }
        }
        .onChange(of: model.meetingCapsuleContent?.layout) { layoutChanged() }
    }

    private func capsule(_ content: MeetingCapsuleContent) -> some View {
        let increased = contrast == .increased
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: content.symbol).foregroundStyle(content.warning ? Palette.warning : Palette.accent).accessibilityHidden(true)
                Text(content.title).font(.system(size: 12, weight: .semibold).monospacedDigit()).lineLimit(1).layoutPriority(1)
                    .accessibilityLabel(content.spokenTitle)
                Spacer(minLength: 8)
                if content.finishTitle == nil {
                    switch content.action {
                    case .pause:
                        Button("Pause", action: model.pauseOpenMeeting).quietAction().help(MeetingWords.muteHint).accessibilityHint(MeetingWords.muteHint)
                    case .resume: resume(content)
                    case nil: EmptyView()
                    }
                }
                Button("Show", action: model.showOpenMeeting).quietAction().help(MeetingCapsuleContent.showAction)
            }
            if !content.lines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(content.lines, id: \.self) { line in
                        Text(line).foregroundStyle(increased ? Palette.text : Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let finish = content.finishTitle {
                HStack(spacing: 8) {
                    resume(content)
                    Button(finish) { model.finishOpenMeeting() }.quietAction()
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(Palette.text).tint(Palette.accent)
        .padding(.horizontal, 14).padding(.vertical, 10).frame(width: Self.width, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(increased ? Palette.text : Palette.line, lineWidth: increased ? 2 : 1))
        .accessibilityElement(children: .contain).accessibilityLabel(MeetingCapsuleContent.accessibilityName)
        .accessibilityAction(named: MeetingCapsuleContent.showAction, model.showOpenMeeting)
    }

    /// Resume, or the meeting's acknowledgment in Within when the call may have changed; what holds capture disables it.
    private func resume(_ content: MeetingCapsuleContent) -> some View {
        Button(content.resumeTitle, action: model.resumeOpenMeeting).primaryAction().disabled(content.resumeBlocker != nil)
            .help(content.resumeBlocker ?? "").accessibilityHint(content.resumeBlocker ?? "")
    }
}
