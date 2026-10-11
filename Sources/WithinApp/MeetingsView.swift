import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WithinCore

/// The Meetings space, behind the developer default: the library, setup, and one meeting's screen. Opening it or
/// moving around in it never starts capture; only Start meeting, Continue and Resume do, each with its acknowledgment.
struct MeetingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meetings: MeetingController
    var body: some View {
        Group {
            if meetings.isOpen || meetings.deletionPending || (model.meetingsRoute == .meeting && meetings.meeting != nil) {
                MeetingScreen(model: model, meetings: meetings)
            } else if model.meetingsRoute == .setup {
                MeetingSetupView(model: model, meetings: meetings)
            } else {
                MeetingLibraryView(model: model, meetings: meetings)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(Palette.text).tint(Palette.accent)
            .onAppear(perform: model.loadMeetingLibrary)
    }
}

// MARK: Library

struct MeetingLibraryView: View {
    enum Focus: Hashable { case newMeeting, search, list }
    @ObservedObject var model: AppModel
    @ObservedObject var meetings: MeetingController
    @State private var query = ""
    /// The rows a search found; nil shows every meeting.
    @State private var found: Set<UUID>?
    @State private var selection: UUID?
    @State private var deleting: Meeting?
    @FocusState private var focus: Focus?
    @AccessibilityFocusState private var voiceOverFocus: Focus?
    private var rows: [Meeting] { found.map { found in model.meetingLibrary.filter { found.contains($0.id) } } ?? model.meetingLibrary }
    private var searchKey: [String] { [query, "\(model.meetingLibrary.count)", "\(model.dictionaryRevision)"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // One row when it fits; in a narrow window the search field gets a row of its own.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    heading
                    Spacer(minLength: 12)
                    if !model.meetingLibrary.isEmpty { searchField.frame(width: 200); actions }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        heading
                        Spacer(minLength: 12)
                        if !model.meetingLibrary.isEmpty { actions }
                    }
                    if !model.meetingLibrary.isEmpty { searchField }
                }
            }
            // The meeting shown before is held in memory only; otherwise why opening or deleting one was refused.
            if model.meetingHeldMessage != nil { MeetingHeldLine(model: model, meetings: meetings) }
            else if let refusal = meetings.refusal, meetings.meeting != nil {
                Label(refusal, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Palette.warning)
            }
            if model.meetingsUnlistable || model.meetingLibraryUnreadable > 0 {
                Label(model.meetingsUnlistable ? "Saved meetings couldn’t be listed on this Mac."
                      : model.meetingLibraryUnreadable == 1 ? "1 saved meeting couldn’t be read and was left untouched."
                      : "\(model.meetingLibraryUnreadable) saved meetings couldn’t be read and were left untouched.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Palette.warning)
            }
            if model.meetingLibrary.isEmpty {
                emptyState
            } else if rows.isEmpty {
                Text("No meetings match “\(query)”.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Spacer(minLength: 0)
            } else {
                list
            }
        }.padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 16)
            .task(id: searchKey) { await search() }
            .onAppear(perform: takeFocus)
            .onChange(of: model.meetingsFocusRequest) { takeFocus() }
            .confirmationDialog("Delete this meeting?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { meeting in
                Button("Delete meeting", role: .destructive) { Task { await model.deleteMeeting(meeting.id) } }
                Button("Keep meeting", role: .cancel) {}
            } message: { _ in Text(MeetingWords.deleteMessage) }
    }

    private var heading: some View {
        Text("Meetings").font(Typography.display(28)).fixedSize().accessibilityAddTraits(.isHeader)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary).accessibilityHidden(true)
            TextField("Search meetings", text: $query).textFieldStyle(.plain).accessibilityLabel("Search meetings")
                .focused($focus, equals: .search)
        }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.canvas.opacity(0.75), in: Capsule())
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Open") { if let selection { open(selection) } }.quietAction().disabled(selection == nil)
            newMeetingButton
        }.fixedSize()
    }

    private var newMeetingButton: some View {
        Button("New meeting", action: model.newMeeting).primaryAction().keyboardShortcut("n", modifiers: .command)
            .focused($focus, equals: .newMeeting).accessibilityFocused($voiceOverFocus, equals: .newMeeting)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(rows) { meeting in
                MeetingLibraryRow(meeting: meeting, badge: model.meetingBadge(meeting), selected: selection == meeting.id).tag(meeting.id)
            }
        }.listStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
            .accessibilityLabel("Meetings")
            .focused($focus, equals: .list).accessibilityFocused($voiceOverFocus, equals: .list)
            .contextMenu(forSelectionType: UUID.self, menu: { ids in
                if let id = ids.first {
                    Button("Open") { open(id) }
                    Button("Delete…", role: .destructive) { deleting = model.meetingLibrary.first { $0.id == id } }
                        .disabled(meetings.isOpen && meetings.meeting?.id == id)
                }
            }, primaryAction: { ids in if let id = ids.first { open(id) } })
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                open(selection); return .handled
            }
            .onDeleteCommand { deleting = model.meetingLibrary.first { $0.id == selection } }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Text("Meeting notes, on this Mac.").font(Typography.display(28)).accessibilityAddTraits(.isHeader)
            // No fixed height here: outside a scroll view it would set the window's minimum height.
            Text(MeetingWords.emptyLibrary(model.meetingBackupStatus)).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            newMeetingButton
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ id: UUID) { model.openMeeting(id) }

    /// Typing stays responsive: the search runs off the main actor once typing pauses, and a newer one cancels it.
    private func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { found = nil; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, let ids = await model.findMeetings(query), !Task.isCancelled else { return }
        found = Set(ids)
    }

    private func takeFocus() {
        guard let request = model.meetingsFocusRequest else { return }
        switch request {
        case .newMeeting: model.meetingsFocusRequest = nil; move(.newMeeting)
        case .row(let id) where model.meetingLibrary.contains(where: { $0.id == id }):
            model.meetingsFocusRequest = nil; query = ""; selection = id; move(.list)
        default: break
        }
    }
    private func move(_ target: Focus) { DispatchQueue.main.async { focus = target; voiceOverFocus = target } }
}

private struct MeetingLibraryRow: View {
    let meeting: Meeting
    let badge: String?
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(meeting.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let badge { MeetingBadge(text: badge) }
            }
            Text("\(meeting.created.formatted(date: .abbreviated, time: .shortened)) · \(MeetingExport.duration(meeting.length)) · \(MeetingWords.sources(meeting))")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
        }.padding(.vertical, 4)
            // Untitled rows stay distinguishable by date, length and sources.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([meeting.displayTitle, meeting.created.formatted(date: .long, time: .shortened), MeetingTime.spoken(meeting.length),
                                 MeetingWords.spokenSources(meeting), badge].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MeetingBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.text)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.tint, in: Capsule())
    }
}

// MARK: Setup

struct MeetingSetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meetings: MeetingController
    @State private var title = ""
    /// The acknowledgment epoch the box was checked in: a lock, sleep or user switch since then clears it.
    @State private var acknowledgedAt: Int?
    @State private var noticeCopied: Bool?
    private var acknowledged: Bool { acknowledgedAt == meetings.acknowledgmentEpoch }
    /// The meeting shown before, held in memory only, comes first: until its Try again succeeds no other one starts.
    private var blocker: String? {
        MeetingAcknowledgment.blocker(acknowledged: acknowledged, refusal: model.meetingHeldMessage ?? model.meetingStartBlocker)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { model.showAllMeetings() } label: { Label("All meetings", systemImage: "chevron.left") }
                    .buttonStyle(.link).font(.system(size: 12))
                VStack(alignment: .leading, spacing: 8) {
                    Text("New meeting").font(Typography.display(28)).accessibilityAddTraits(.isHeader)
                    Text("Nothing listens until you choose Start meeting.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                if let failure = model.meetingSetupFailure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Meeting name").font(.system(size: 13, weight: .semibold))
                    TextField(model.includeZoomSound && model.meetingAppSoundSupported ? "Zoom meeting" : "Meeting", text: $title)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Meeting name, optional")
                }.withinSurface(padding: 16)
                VStack(alignment: .leading, spacing: 14) {
                    Text("What Within transcribes").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Label("Your microphone, labelled You", systemImage: "mic").font(.system(size: 12))
                    MicrophoneControls(model: model)
                    Divider()
                    MeetingAppSoundChoice(model: model)
                }.withinSurface(padding: 16)
                VStack(alignment: .leading, spacing: 10) {
                    Label(MeetingWords.savedAsYouGo, systemImage: "lock.shield")
                    Label("Muting in Zoom doesn’t mute Within. Use Pause.", systemImage: "mic.slash")
                }.font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true).withinSurface(padding: 16)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(MeetingAcknowledgment.sentence, isOn: Binding(get: { acknowledged }, set: { acknowledgedAt = $0 ? meetings.acknowledgmentEpoch : nil }))
                        .toggleStyle(.checkbox).font(.system(size: 13, weight: .medium))
                    MeetingNoticeButton(model: model, copied: $noticeCopied)
                }.withinSurface(padding: 16)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button("Start meeting") {
                        if model.startMeeting(title: title, acknowledged: acknowledged) { title = ""; acknowledgedAt = nil }
                    }.primaryAction().keyboardShortcut(.defaultAction).disabled(blocker != nil)
                        .help(blocker ?? "").accessibilityHint(blocker ?? "")
                    if let blocker { Text(blocker).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
                    if model.meetingHeldMessage != nil { Button("Try again") { Task { await model.retryMeeting() } }.quietAction() }
                    Spacer(minLength: 8)
                    Button("Cancel", action: model.showAllMeetings).quietAction()
                }
            }.padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 24).frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear(perform: model.refreshPermissions)
    }
}

/// Zoom's sound, offered only on macOS 14.2 or later. Until it is on, nothing about other apps is read. The permission
/// is explained whenever it is on, in setup and in Continue alike.
private struct MeetingAppSoundChoice: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.meetingAppSoundSupported {
            VStack(alignment: .leading, spacing: 10) {
                // The switch carries its own name, as in Settings, since it widens what is captured.
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include Zoom’s sound (the other people)").font(.system(size: 13, weight: .medium))
                        Text("Labelled Others. Labels are sources, not people.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("Include Zoom’s sound (the other people)", isOn: $model.includeZoomSound).labelsHidden().toggleStyle(.switch)
                }
                if model.includeZoomSound {
                    Group {
                        Text(MeetingWords.appSoundScope)
                        Text(MeetingWords.appSoundPermission)
                        Label("Headphones keep the other side out of your microphone.", systemImage: "headphones")
                    }.font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Label(MeetingWords.appSoundUnsupported, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The shown meeting is held in memory only: why, with Try again, wherever it keeps another meeting from opening or starting.
private struct MeetingHeldLine: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meetings: MeetingController
    var body: some View {
        if let held = model.meetingHeldMessage {
            HStack(spacing: 10) {
                Label(held, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Try again") { Task { await model.retryMeeting() } }.quietAction()
            }
        }
    }
}

/// Copy notice: the sentence is shown before it is copied, and the clipboard is named next to the button.
struct MeetingNoticeButton: View {
    @ObservedObject var model: AppModel
    @Binding var copied: Bool?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("Copy notice") { copied = model.copyMeetingNotice() }.quietAction()
                Text("“\(AppModel.meetingNotice)”").font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let copied {
                Text(copied ? MeetingWords.noticeCopied : "Copy failed.").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Palette.secondary : Palette.warning)
            }
            Text(MeetingWords.clipboard).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Meeting screen

struct MeetingScreen: View {
    enum Column: Hashable { case transcript, notes }
    enum Focus: Hashable { case notes, export, acknowledgment }
    /// At this content width the transcript and the notes sit side by side; below it they are tabs.
    static let twoColumnWidth: CGFloat = 680
    @ObservedObject var model: AppModel
    @ObservedObject var meetings: MeetingController
    @State private var column = Column.transcript
    @State private var confirmingDiscard = false
    @State private var confirmingDelete = false
    @State private var continuing = false
    /// The acknowledgment epoch the box was checked in: a lock, sleep or user switch since then clears it.
    @State private var acknowledgedAt: Int?
    @State private var noticeCopied: Bool?
    @State private var exported: String?
    @FocusState private var focus: Focus?
    @AccessibilityFocusState private var titleFocused: Bool
    @AccessibilityFocusState private var firstTurnFocused: Bool
    private var acknowledged: Bool { acknowledgedAt == meetings.acknowledgmentEpoch }
    private var acknowledgment: Binding<Bool> { Binding(get: { acknowledged }, set: { acknowledgedAt = $0 ? meetings.acknowledgmentEpoch : nil }) }

    var body: some View {
        if let meeting = meetings.meeting {
            GeometryReader { geometry in
                let wide = geometry.size.width >= Self.twoColumnWidth
                VStack(alignment: .leading, spacing: 0) {
                    header(meeting, wide: wide)
                    messages(meeting).padding(.horizontal, 28)
                    if wide {
                        HStack(spacing: 0) {
                            transcript(meeting).frame(maxWidth: .infinity)
                            Divider().padding(.vertical, 12)
                            notes(meeting).frame(width: max(240, geometry.size.width * 0.36))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Show", selection: $column) {
                                Text("Transcript").tag(Column.transcript)
                                Text("My notes").tag(Column.notes)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.horizontal, 28).padding(.top, 10)
                            if column == .transcript { transcript(meeting) } else { notes(meeting) }
                        }
                    }
                }
            }
            .onAppear(perform: takeFocus)
            .onChange(of: model.meetingsFocusRequest) { takeFocus() }
            .onChange(of: meeting.id) { continuing = false; acknowledgedAt = nil; exported = nil; noticeCopied = nil }
            .onChange(of: meetings.phase) { _, phase in if phase != .paused && phase != .finished { acknowledgedAt = nil; continuing = false } }
            .confirmationDialog("Discard this meeting?", isPresented: $confirmingDiscard) {
                Button("Discard meeting", role: .destructive) { Task { await model.discardMeeting() } }
                Button("Keep meeting", role: .cancel) {}
            } message: { Text("Capture stops and its transcript and notes are deleted from this Mac.") }
            .confirmationDialog("Delete this meeting?", isPresented: $confirmingDelete) {
                Button("Delete meeting", role: .destructive) { Task { await model.deleteMeeting(meeting.id) } }
                Button("Keep meeting", role: .cancel) {}
            } message: { Text(MeetingWords.deleteMessage) }
        }
    }

    private var open: Bool { meetings.isOpen }
    private var fixes: Int { model.meetingFixedTurns }

    // MARK: Header

    /// Wide: the title, time and controls share a row. Narrow: the controls get a row of their own, so the title isn't
    /// squeezed and no button wraps.
    private func header(_ meeting: Meeting, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !open && !meetings.deletionPending {
                Button { model.showAllMeetings() } label: { Label("All meetings", systemImage: "chevron.left") }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            HStack(alignment: .center, spacing: 10) {
                // Editable, so it stays a text field for VoiceOver rather than a heading.
                TextField(meeting.displayTitle, text: Binding(get: { meetings.meeting?.title ?? "" }, set: meetings.setTitle))
                    .textFieldStyle(.plain).font(Typography.display(22)).lineLimit(1).truncationMode(.tail).frame(minWidth: 120)
                    .accessibilityLabel("Meeting title").accessibilityFocused($titleFocused)
                Spacer(minLength: 8)
                MeetingElapsed(meetings: meetings)
                if wide { HStack(spacing: 10) { controls(meeting) }.fixedSize() }
                overflow(meeting)
            }
            if !wide { HStack(spacing: 10) { controls(meeting) }.fixedSize() }
            if open {
                HStack(spacing: 8) {
                    ForEach(chipSources(meeting), id: \.self) { MeetingSourceChip(source: $0, state: meetings.sourceStates[$0] ?? .off, model: model, appName: meeting.appName) }
                }
            } else {
                Text("\(meeting.created.formatted(date: .abbreviated, time: .shortened)) · \(MeetingWords.sources(meeting))")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)
    }

    private func chipSources(_ meeting: Meeting) -> [MeetingSource] {
        let sources = meetings.sourceStates.keys.sorted { $0 == .you && $1 == .others }
        return sources.isEmpty ? meeting.stretches.last?.sources ?? [.you] : sources
    }

    @ViewBuilder private func controls(_ meeting: Meeting) -> some View {
        switch meetings.phase {
        case .preparing, .recording:
            // Permanent, whatever the sources: Zoom's mute never reaches the microphone Within listens to.
            Button("Pause", action: meetings.pause).quietAction().help(MeetingWords.muteHint).accessibilityHint(MeetingWords.muteHint)
            Button("Finish") { finish() }.primaryAction()
        case .paused:
            // What holds capture or readiness disables Resume with its reason, as File → Resume Meeting does.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let blocker = model.meetingStartBlocker
                Button(meetings.needsAcknowledgment ? "Resume…" : "Resume") { resume() }.primaryAction()
                    .disabled(blocker != nil).help(blocker ?? "").accessibilityHint(blocker ?? "")
            }
            Button("Finish") { finish() }.quietAction()
        case .pausing:
            ProgressView().controlSize(.small).accessibilityLabel("Pausing")
            Button("Finish") { finish() }.quietAction()
        case .finishing, .discarding:
            ProgressView().controlSize(.small).accessibilityLabel(meetings.phase == .finishing ? "Finishing" : "Discarding")
        case .idle, .finished:
            if !meetings.deletionPending {
                Button("Export…") { export(meeting) }.primaryAction().focused($focus, equals: .export)
                Button("Continue this meeting") { continueTapped() }.quietAction()
                Button { confirmingDelete = true } label: { Image(systemName: "trash").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).foregroundStyle(Palette.secondary).help("Delete meeting").accessibilityLabel("Delete meeting")
            }
        }
    }

    @ViewBuilder private func overflow(_ meeting: Meeting) -> some View {
        if open || fixes > 0 {
            Menu {
                if open {
                    Button("Copy notice") { noticeCopied = model.copyMeetingNotice() }
                    Button("Export…") { export(meeting) }
                }
                if fixes > 0 { Toggle("Show original transcription", isOn: originalTranscription) }
                if open {
                    Divider()
                    Button("Discard meeting…", role: .destructive) { confirmingDiscard = true }.disabled(meetings.phase == .discarding)
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More meeting actions").accessibilityLabel("More meeting actions")
        }
    }

    private var originalTranscription: Binding<Bool> {
        Binding(get: { model.showingOriginalTranscription }, set: model.setShowingOriginalTranscription)
    }

    // MARK: Messages

    @ViewBuilder private func messages(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stop = meeting.stop, meeting.recovered, !open, !model.closedRecoveryNotices.contains(meeting.id) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(MeetingWords.recovered(at: stop.at), systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Continue this meeting") { continueTapped() }.quietAction()
                        Button("Close") { model.closeRecoveryNotice(meeting.id) }.quietAction().accessibilityLabel("Close this notice")
                    }
                }.withinSurface(padding: 14)
            }
            if model.meetingHeldMessage != nil { MeetingHeldLine(model: model, meetings: meetings) }
            // Includes a Delete that failed: the meeting is still here, and Delete is its retry.
            if let refusal = meetings.refusal, refusal != model.meetingHeldMessage {
                Label(refusal, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = meetings.startFailure, meetings.phase == .paused || meetings.phase == .finished {
                // A new meeting whose first start failed has no stretch left; a continued one keeps its earlier ones.
                let verb = meetings.phase == .paused ? "Couldn’t resume" : meeting.stretches.isEmpty ? "Couldn’t start" : "Couldn’t continue"
                Label("\(verb): \(MeetingWords.startFailure(failure, appName: meeting.appName))", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = meetings.notice {
                HStack(spacing: 10) {
                    Label(notice, systemImage: "info.circle").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("OK", action: meetings.dismissNotice).quietAction().accessibilityLabel("Dismiss notice")
                }
            }
            if meetings.phase == .paused { paused(meeting) }
            if continuing && meetings.phase == .finished { continuePanel(meeting) }
            if meetings.sourceStates[.others] == .quiet {
                HStack(spacing: 10) {
                    Text(MeetingWords.notHearing(meeting.appName)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open System Settings…", action: model.openPrivacySettings).quietAction()
                }
            }
            if meetings.phase == .recording, meetings.elapsed - (meeting.stretches.last?.start ?? 0) < 60 {
                Label(MeetingWords.muteHint, systemImage: "mic.slash").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            if let noticeCopied {
                Text(noticeCopied ? "\(MeetingWords.noticeCopied) \(MeetingWords.clipboard)" : "Copy failed.")
                    .font(.system(size: 11)).foregroundStyle(noticeCopied ? Palette.secondary : Palette.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let exported { Text(exported).font(.system(size: 11)).foregroundStyle(Palette.secondary) }
            if fixes > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "character.book.closed").foregroundStyle(Palette.secondary).accessibilityHidden(true)
                    Text(model.showingOriginalTranscription ? "Showing the original transcription." : "Personal dictionary fixes shown")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer(minLength: 8)
                    Toggle("Show original transcription", isOn: originalTranscription).toggleStyle(.checkbox).font(.system(size: 12))
                }
            }
        }
    }

    /// Why it paused, and Resume with the acknowledgment when the call may have changed.
    @ViewBuilder private func paused(_ meeting: Meeting) -> some View {
        let ended = meeting.stretches.last?.ended
        let appLost = meeting.includesAppSound && (meetings.sourceStates[.others] != nil || meeting.stretches.last?.sources.contains(.others) == true)
            && [.computerAudioLost, .computerAudioChanged, .computerAudioStalled].contains(ended)
        if let reason = ended.flatMap({ MeetingWords.pauseReason($0, appName: meeting.appName) }) {
            Label(reason, systemImage: "pause.circle").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if meetings.needsAcknowledgment {
                let blocker = MeetingAcknowledgment.blocker(acknowledged: acknowledged, refusal: model.meetingStartBlocker, action: "resume")
                VStack(alignment: .leading, spacing: 12) {
                    Text("The call may have changed while notes were paused. Confirm again before Within listens.").font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(MeetingAcknowledgment.sentence, isOn: acknowledgment).toggleStyle(.checkbox).font(.system(size: 13, weight: .medium))
                        .focused($focus, equals: .acknowledgment)
                    HStack(spacing: 10) {
                        Button("Resume this meeting") { model.resumeMeeting(acknowledged: acknowledged) }.primaryAction()
                            .disabled(blocker != nil).help(blocker ?? "").accessibilityHint(blocker ?? "")
                        if appLost {
                            Button("Resume with microphone only") { model.resumeMeeting(acknowledged: acknowledged, microphoneOnly: true) }.quietAction()
                                .disabled(blocker != nil).help(blocker ?? "").accessibilityHint(blocker ?? "")
                        }
                        Button("Start a new meeting instead") { startNewInstead() }.quietAction()
                    }
                    if let blocker { Text(blocker).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
                }.withinSurface(padding: 14)
            } else {
                // Resume needs no acknowledgment here; what holds capture or readiness is the only thing that can stop it.
                let blocker = model.meetingStartBlocker
                if appLost {
                    HStack(spacing: 10) {
                        Text("Or keep going without \(meeting.appName)’s sound.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        Button("Resume with microphone only") { model.resumeMeeting(acknowledged: false, microphoneOnly: true) }.quietAction()
                            .disabled(blocker != nil).help(blocker ?? "").accessibilityHint(blocker ?? "")
                    }
                }
                if let blocker {
                    Label(blocker, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func continuePanel(_ meeting: Meeting) -> some View {
        let blocker = MeetingAcknowledgment.blocker(acknowledged: acknowledged, refusal: model.meetingStartBlocker, action: "continue")
        return VStack(alignment: .leading, spacing: 12) {
            Text("Continue this meeting").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("New words are added after a gap. Your microphone is labelled You.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            // A microphone-only meeting stays one, so its labels and export stay true.
            if meeting.includesAppSound { MeetingAppSoundChoice(model: model) }
            else {
                Text("This meeting continues with your microphone only, as it was recorded.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(MeetingAcknowledgment.sentence, isOn: acknowledgment).toggleStyle(.checkbox).font(.system(size: 13, weight: .medium))
                .focused($focus, equals: .acknowledgment)
            HStack(spacing: 10) {
                Button("Continue meeting") { if model.continueMeeting(acknowledged: acknowledged) { continuing = false; acknowledgedAt = nil } }
                    .primaryAction().disabled(blocker != nil).help(blocker ?? "").accessibilityHint(blocker ?? "")
                Button("Cancel") { continuing = false; acknowledgedAt = nil }.quietAction()
                if let blocker { Text(blocker).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.withinSurface(padding: 14)
    }

    // MARK: Columns

    private func transcript(_ meeting: Meeting) -> some View {
        MeetingTranscript(model: model, meetings: meetings, meeting: meeting, firstTurnFocused: $firstTurnFocused)
            .padding(.leading, 28).padding(.trailing, 16).padding(.vertical, 12)
    }

    private func notes(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My notes").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            ZStack(alignment: .topLeading) {
                if meeting.notes.isEmpty {
                    Text("Your notes. Only you write here.").font(.system(size: 14)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 17).padding(.vertical, 12).allowsHitTesting(false).accessibilityHidden(true)
                }
                TextEditor(text: Binding(get: { meetings.meeting?.notes ?? "" }, set: meetings.setNotes))
                    .font(.system(size: 14)).lineSpacing(3).scrollContentBackground(.hidden).padding(12)
                    .focused($focus, equals: .notes)
                    .accessibilityLabel("My notes").accessibilityHint(meeting.notes.isEmpty ? "Only you write here. Saved on this Mac as you type." : "")
            }.background(Palette.canvas.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.padding(.leading, 16).padding(.trailing, 28).padding(.vertical, 12)
    }

    // MARK: Actions

    private func finish() { Task { await model.finishMeeting() } }

    private func resume() {
        if meetings.needsAcknowledgment { focusAcknowledgment() } else { model.resumeMeeting(acknowledged: false) }
    }

    private func continueTapped() { continuing = true; acknowledgedAt = nil; focusAcknowledgment() }

    /// Finishes this meeting, then opens setup, where a new one starts with its own acknowledgment.
    private func startNewInstead() {
        Task { if await model.finishMeeting() { model.newMeeting() } }
    }

    private func focusAcknowledgment() { DispatchQueue.main.async { focus = .acknowledgment } }

    private func export(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingExport.fileName(meeting)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "This saves a copy outside Within. Wherever you save it, Spotlight may index it and backups or sync may copy it."
        let original = NSButton(checkboxWithTitle: "Use the original transcription (before your personal dictionary fixes)", target: nil, action: nil)
        if fixes > 0 {
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 36))
            original.frame = NSRect(x: 16, y: 8, width: 440, height: 20)
            accessory.addSubview(original)
            panel.accessoryView = accessory
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let markdown = model.meetingMarkdown(useOriginalTranscription: fixes > 0 && original.state == .on) else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            exported = "Saved to the location you chose."
        } catch { exported = "The meeting couldn’t be saved there. Choose another location and try again." }
        model.announce(exported ?? "")
    }

    private func takeFocus() {
        guard let request = model.meetingsFocusRequest else { return }
        switch request {
        case .title: model.meetingsFocusRequest = nil; DispatchQueue.main.async { titleFocused = true }
        case .notes:
            model.meetingsFocusRequest = nil; column = .notes
            DispatchQueue.main.async { focus = .notes }
        case .export: model.meetingsFocusRequest = nil; DispatchQueue.main.async { focus = .export }
        // The transcript tab first, below the two-column width; a meeting with no turns gives its title focus instead.
        case .firstTurn:
            model.meetingsFocusRequest = nil
            if meetings.meeting?.segments.isEmpty ?? true { DispatchQueue.main.async { titleFocused = true } }
            else { column = .transcript; DispatchQueue.main.async { firstTurnFocused = true } }
        // Resume from the menu when the acknowledgment is needed: only the box here can give it.
        case .acknowledgment:
            model.meetingsFocusRequest = nil
            if meetings.phase == .paused && meetings.needsAcknowledgment { focusAcknowledgment() }
        default: break
        }
    }
}

/// "Recording · 12:34", "Paused at 12:34" or a finished meeting's length, with the time spelled out for VoiceOver.
private struct MeetingElapsed: View {
    @ObservedObject var meetings: MeetingController
    var body: some View {
        let seconds = meetings.isOpen ? meetings.elapsed : meetings.meeting?.length ?? 0
        let (shown, spoken): (String, String) = switch meetings.phase {
        case .recording: ("Recording · \(MeetingTime.short(seconds))", "Recording, \(MeetingTime.spoken(seconds))")
        case .preparing: ("Starting…", "Starting")
        case .pausing: ("Pausing…", "Pausing")
        case .paused: ("Paused at \(MeetingTime.short(seconds))", "Paused at \(MeetingTime.spoken(seconds))")
        case .finishing: ("Finishing…", "Finishing")
        case .discarding: ("Discarding…", "Discarding")
        case .idle, .finished: (MeetingExport.duration(seconds), "Length, \(MeetingTime.spoken(seconds))")
        }
        Text(shown).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Palette.secondary).lineLimit(1)
            .fixedSize().accessibilityLabel(spoken)
    }
}

/// A source with its state first: "Live · You · Built-in Microphone". The device name truncates first.
private struct MeetingSourceChip: View {
    let source: MeetingSource
    let state: MeetingSourceState
    @ObservedObject var model: AppModel
    let appName: String
    var body: some View {
        let who = source == .you ? "You" : "Others"
        let name = source == .you ? model.selectedInputName : appName
        let (word, symbol): (String, String) = switch state {
        case .live: ("Live", "waveform")
        case .quiet: ("Not hearing \(appName)", "speaker.slash")
        case .lost: ("Lost", "exclamationmark.triangle")
        case .off: ("Off", "pause.circle")
        }
        HStack(spacing: 5) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text("\(word) · \(who)").fixedSize()
            Text("· \(name)").lineLimit(1).truncationMode(.tail)
        }.font(.system(size: 11, weight: .medium))
            .foregroundStyle(state == .lost || state == .quiet ? Palette.warning : state == .live ? Palette.accent : Palette.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(state == .live ? Palette.tint : Palette.canvas.opacity(0.75), in: Capsule())
            // Static text, so the state is exposed as its value; an element with no role drops it.
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(who), \(name)").accessibilityValue(word)
    }
}

// MARK: Transcript

/// Settled turns in your spellings (or the original transcription), gap markers, and the still-changing tail last.
/// Each turn is its own accessibility element; the column never becomes one.
private struct MeetingTranscript: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meetings: MeetingController
    let meeting: Meeting
    var firstTurnFocused: AccessibilityFocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var rotors
    /// New words scroll into view until the user scrolls up; Jump to latest follows again.
    @State private var following = true
    @State private var awaitingScroll = false
    @State private var viewport: CGFloat = 0
    @State private var endPosition: CGFloat?
    private static let end = "end"

    private var rows: [MeetingTimelineRow] { meeting.timeline }
    private var version: [Int] {
        [meeting.segments.count, meeting.segments.last?.text.count ?? 0, meetings.provisional.values.map(\.count).reduce(0, +), meeting.stretches.count]
    }

    var body: some View {
        let rows = rows
        let firstTurn = rows.first { if case .turn = $0 { return true }; return false }?.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Transcript").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let last = meeting.segments.last {
                    Button("Read latest") { model.announce(turnLabel(last) + ": " + model.meetingTurnText(last)) }
                        .buttonStyle(.link).font(.system(size: 12)).accessibilityHint("Speaks the last settled turn")
                }
                if meetings.isOpen && !following {
                    Button("Jump to latest") { following = true; scrollToEnd() }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(rows) { row in
                                switch row {
                                case .turn(let segment): turn(segment, first: row.id == firstTurn)
                                case .gap(let gap, _): marker(gapText(gap), spoken: gapSpoken(gap)).accessibilityRotorEntry(id: row.id, in: rotors)
                                case .stop(let stop): marker(stopText(stop), spoken: stopSpoken(stop)).accessibilityRotorEntry(id: row.id, in: rotors)
                                }
                            }
                            if meetings.phase == .paused, let last = meeting.stretches.last, let end = last.end {
                                marker(trailingPause(at: end, reason: last.ended), spoken: "Paused at \(MeetingTime.spoken(end))")
                            }
                            if meetings.isOpen { live }
                            if !meetings.isOpen && meeting.segments.isEmpty {
                                Text("No words were transcribed in this meeting.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id(Self.end)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TranscriptEnd.self, value: geometry.frame(in: .named("transcript")).minY)
                            })
                    }.padding(.vertical, 4).padding(.trailing, 6)
                }
                .coordinateSpace(name: "transcript")
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { viewport = geometry.size.height; updateFollowing() }
                        .onChange(of: geometry.size.height) { _, height in viewport = height; updateFollowing() }
                })
                .defaultScrollAnchor(meetings.isOpen ? .bottom : .top)
                .onPreferenceChange(TranscriptEnd.self) { position in endPosition = position; updateFollowing() }
                .onAppear {
                    guard meetings.isOpen else { return }
                    awaitingScroll = true; proxy.scrollTo(Self.end, anchor: .bottom)
                }
                .onChange(of: version) {
                    guard meetings.isOpen, following else { return }
                    awaitingScroll = true
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
                .onChange(of: jumpRequest) { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(Self.end, anchor: .bottom) } }
                .accessibilityRotor("Gaps") {
                    ForEach(rows.filter { if case .turn = $0 { return false }; return true }) { row in
                        AccessibilityRotorEntry(Text(verbatim: rotorLabel(row)), id: row.id, in: rotors)
                    }
                }
                .accessibilityRotor("You") { turnEntries(.you, rows) }
                .accessibilityRotor("Others") { turnEntries(.others, rows) }
            }
        }
    }

    @State private var jumpRequest = 0
    private func scrollToEnd() { awaitingScroll = true; jumpRequest += 1 }
    /// The end of the transcript is in view (or about to be, after a scroll this view asked for).
    private func updateFollowing() {
        guard viewport > 0, let endPosition else { return }
        if endPosition <= viewport + 24 { following = true; awaitingScroll = false } else if !awaitingScroll { following = false }
    }

    private func turnEntries(_ source: MeetingSource, _ rows: [MeetingTimelineRow]) -> some AccessibilityRotorContent {
        ForEach(rows.compactMap { row -> MeetingSegment? in if case .turn(let segment) = row, segment.source == source { return segment }; return nil }) { segment in
            AccessibilityRotorEntry(Text(verbatim: turnLabel(segment)), id: segment.id.uuidString, in: rotors)
        }
    }

    private func turnLabel(_ segment: MeetingSegment) -> String { "\(segment.source == .you ? "You" : "Others"), \(MeetingTime.spoken(segment.offset))" }

    private func turn(_ segment: MeetingSegment, first: Bool) -> some View {
        let spelled = model.meetingTurn(segment)
        let text = model.meetingTurnText(segment)
        let fixed = spelled.changed && !model.showingOriginalTranscription
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(MeetingExport.clock(segment.offset)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(segment.source == .you ? "You" : "Others").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(segment.source == .you ? Palette.accent : Palette.text)
                Text(text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        // The bracketed time is spoken as words in the label instead. Static text carries the words as its value.
        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(turnLabel(segment)).accessibilityValue(text)
        .modifier(ReadOriginal(model: model, segment: segment, enabled: fixed))
        .accessibilityRotorEntry(id: segment.id.uuidString, in: rotors)
        .modifier(FirstTurnFocus(focused: firstTurnFocused, first: first))
        .modifier(FixedTurn(model: model, segment: segment, result: spelled, fixed: fixed))
    }

    private func marker(_ text: String, spoken: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore).accessibilityLabel(spoken).accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var live: some View {
        let tails = [MeetingSource.others, .you].filter { !(meetings.provisional[$0] ?? "").isEmpty }
        if !tails.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Live · these words may still change").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                ForEach(tails, id: \.self) { source in
                    let text = meetings.provisional[source] ?? ""
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(source == .you ? "You" : "Others").font(.system(size: 12, weight: .semibold))
                        Text(text).font(.system(size: 14)).italic().fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(Palette.secondary)
                        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel("\(source == .you ? "You" : "Others"), still being transcribed").accessibilityValue(text)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        } else if meeting.segments.isEmpty {
            Text(meetings.phase == .preparing ? "Getting ready…" : meetings.phase == .recording ? "Listening… words appear several seconds after people speak." : "")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
        }
    }

    private func gapText(_ gap: MeetingGap) -> String {
        "— \(gap.label) \(MeetingExport.clock(gap.start))–\(MeetingExport.clock(gap.end))\(gap.detail(appName: meeting.appName).map { " · " + $0 } ?? "") —"
    }
    private func gapSpoken(_ gap: MeetingGap) -> String {
        let why = gap.detail(appName: meeting.appName) ?? (gap.reason == .durationLimit ? "continued past three hours, an untested length" : "paused")
        return "Gap from \(MeetingTime.spoken(gap.start)) to \(MeetingTime.spoken(gap.end)), \(why)"
    }
    private func stopText(_ stop: MeetingStop) -> String {
        "— Stopped at \(MeetingExport.clock(stop.at))\(stop.detail(appName: meeting.appName).map { " · " + $0 } ?? "") —"
    }
    private func stopSpoken(_ stop: MeetingStop) -> String {
        "Stopped at \(MeetingTime.spoken(stop.at))\(stop.detail(appName: meeting.appName).map { ", " + $0 } ?? "")"
    }
    private func trailingPause(at end: TimeInterval, reason: MeetingStretchEnd?) -> String {
        let why = reason.flatMap { MeetingGap(start: end, end: end, reason: $0).detail(appName: meeting.appName) }
        return "— Paused at \(MeetingExport.clock(end))\(why.map { " · " + $0 } ?? "") —"
    }
    private func rotorLabel(_ row: MeetingTimelineRow) -> String {
        switch row {
        case .gap(let gap, _): return gapSpoken(gap)
        case .stop(let stop): return stopSpoken(stop)
        case .turn(let segment): return turnLabel(segment)
        }
    }
}

private struct TranscriptEnd: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// "Fixed": this turn shows personal dictionary fixes. Its value counts them; its action reads the original transcription.
private struct FixedTag: View {
    @ObservedObject var model: AppModel
    let segment: MeetingSegment
    let result: DictionaryResult
    var body: some View {
        Text("Fixed").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.tint, in: Capsule())
            .help("Your dictionary changed " + result.changes.map { "\($0.transcribed) → \($0.written)" }.joined(separator: ", "))
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("Fixed").accessibilityValue(MeetingWords.fixes(result.changes.count))
            .accessibilityAction(named: "Read original transcription") { model.announce(segment.text) }
    }
}

/// A changed turn and its tag, grouped so the tag follows its own turn; an unchanged turn stays a single element.
private struct FixedTurn: ViewModifier {
    let model: AppModel
    let segment: MeetingSegment
    let result: DictionaryResult
    let fixed: Bool
    func body(content: Content) -> some View {
        if fixed {
            content.overlay(alignment: .topTrailing) { FixedTag(model: model, segment: segment, result: result) }.accessibilityElement(children: .contain)
        } else { content }
    }
}

private struct FirstTurnFocus: ViewModifier {
    var focused: AccessibilityFocusState<Bool>.Binding
    let first: Bool
    func body(content: Content) -> some View {
        if first { content.accessibilityFocused(focused) } else { content }
    }
}

private struct ReadOriginal: ViewModifier {
    let model: AppModel
    let segment: MeetingSegment
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: "Read original transcription") { model.announce(segment.text) } } else { content }
    }
}

/// Saved turns in your spellings, each applied once while its text and the dictionary stay the same, so a long
/// meeting's rows and its fix count stay cheap as the open turn grows. Holds one meeting's turns at a time.
@MainActor final class MeetingSpellingCache {
    private var revision = -1
    private var turns: [UUID: (text: String, result: DictionaryResult)] = [:]

    func turn(_ segment: MeetingSegment, dictionary: DictionaryMatcher, revision: Int) -> DictionaryResult {
        if revision != self.revision { turns = [:]; self.revision = revision }
        if let cached = turns[segment.id], cached.text == segment.text { return cached.result }
        if turns.count > 20_000 { turns = [:] }
        let result = MeetingSpellings.turn(segment, dictionary: dictionary)
        turns[segment.id] = (segment.text, result)
        return result
    }
}

// MARK: Words

enum MeetingTime {
    /// "12:34", or "1:12:04" past an hour.
    static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
    /// "1 hour, 12 minutes, 4 seconds".
    static func spoken(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, Int(seconds))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// The Meetings space's sentences. Every one is a proposal pending the owner's copy and legal review.
enum MeetingWords {
    /// Names Time Machine, the backups the switch decides, and claims nothing when the choice couldn't be applied.
    static func emptyLibrary(_ backups: AppModel.MeetingBackupStatus) -> String {
        let kept = switch backups {
        case .included: " and its Time Machine backups"
        case .excluded, .excludedAfterIncluded: " and kept out of Time Machine backups"
        case .unconfirmed: ""
        }
        return "Start notes when a call begins. Within transcribes your microphone and, if you choose, Zoom’s sound. The transcript and your notes are saved only on this Mac\(kept). Audio is never kept."
    }
    static let savedAsYouGo = "The transcript and your notes are saved on this Mac from the moment you start. Audio is never kept."
    static let appSoundScope = "Within transcribes everything Zoom plays: the people in the call, and also its ringtones, notification sounds and any shared video."
    /// No promise that macOS will ask: when it does is unverified. It says what the permission allows and where it is.
    static let appSoundPermission = "To transcribe the other people in your call, Within listens to Zoom’s sound directly on this Mac, not through your speakers. This uses the System Audio Recording permission, which macOS lists in System Settings under Privacy & Security. That permission lets an app record sound from apps on this Mac; Within uses it only for Zoom, and only while meeting notes are on. The sound is transcribed on this Mac and never saved. If Within isn’t allowed, it can still transcribe your microphone."
    static let appSoundUnsupported = "Including the meeting app’s sound needs macOS 14.2 or later. Within will transcribe your microphone only, so with headphones the other people in the call won’t be captured."
    static let muteHint = "Muting in Zoom doesn’t pause Within."
    static let noticeCopied = "Copied. Paste it into the meeting chat if you choose."
    static let clipboard = "Copy uses your clipboard. Other apps, clipboard managers, and Universal Clipboard may read or sync these words."
    static let startNotSaved = "Meeting notes couldn’t be saved on this Mac, so nothing started. Check free space, then try again."
    static let deleteMessage = "The transcript and your notes will be removed from this Mac. It cannot be undone. Existing backups may keep earlier copies."

    static func sources(_ meeting: Meeting) -> String { meeting.includesAppSound ? "\(meeting.appName) + microphone" : "Microphone only" }
    static func spokenSources(_ meeting: Meeting) -> String { meeting.includesAppSound ? "\(meeting.appName) and microphone" : "Microphone only" }

    static func recovered(at seconds: TimeInterval) -> String {
        "Within stopped unexpectedly during this meeting. Text saved up to \(MeetingExport.duration(seconds)) is here; anything after that may be missing. Within did not start listening again."
    }

    static func notHearing(_ appName: String) -> String {
        "\(appName) may be quiet, or System Audio Recording may be off for Within. macOS doesn’t tell apps which."
    }

    static func fixes(_ count: Int) -> String { "Includes \(count) personal dictionary \(count == 1 ? "fix" : "fixes")" }

    /// Why a start, resume or continue didn't begin.
    static func startFailure(_ reason: MeetingStretchEnd, appName: String) -> String {
        switch reason {
        case .microphoneStalled: return "No audio arrived from the microphone. Check the selected input and try again."
        case .microphoneLost: return "The microphone couldn’t start. Check the selected input and try again."
        case .microphonePermission: return "Microphone access is off for Within. Allow it in System Settings, then try again."
        case .computerAudioStalled: return "\(appName)’s audio didn’t start. Try again, or start with your microphone only."
        case .computerAudioLost, .computerAudioChanged: return "\(appName)’s sound couldn’t be included. Join the call first, or start with your microphone only."
        case .speechError: return "Local speech couldn’t start. Check the model in Settings, then try again."
        default: return "Meeting notes couldn’t start. Try again."
        }
    }

    /// The paused meeting's reason line; none for the Pause button.
    static func pauseReason(_ reason: MeetingStretchEnd, appName: String) -> String? {
        if reason == .processingFellBehind { return "Speech processing fell behind, so Within paused to keep your text. Resume to continue." }
        return MeetingGap(start: 0, end: 0, reason: reason).detail(appName: appName).map { "Paused: \($0)." }
    }
}

// MARK: Previews

/// Synthetic meetings for previews and native checks only; never read from or written to disk.
enum MeetingPreviews {
    private static let day: TimeInterval = 86_400
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static func id(_ suffix: String) -> UUID { UUID(uuidString: "7A2B3C4D-5E6F-4A1B-8C2D-\(suffix)")! }

    private static let planning: [MeetingSegment] = [
        MeetingSegment(id: id("000000000001"), source: .others, offset: 12, text: "Thanks for joining, everyone. Let’s start with the launch checklist."),
        MeetingSegment(id: id("000000000002"), source: .you, offset: 24, text: "Sounds good. I finished the onboarding copy yesterday, so that part is ready for review."),
        MeetingSegment(id: id("000000000003"), source: .others, offset: 41, text: "Great. Did the new screenshots make it into the help page?"),
        MeetingSegment(id: id("000000000004"), source: .you, offset: 55, text: "Not yet. I’ll add them this afternoon and send a link when they’re up."),
        MeetingSegment(id: id("000000000005"), source: .others, offset: 78, text: "Perfect. Next is the feedback from last week’s beta."),
        MeetingSegment(id: id("000000000006"), source: .you, offset: 96, text: "Most people asked for a shorter setup, and a few wanted an easier way to change the shortcut."),
        MeetingSegment(id: id("000000000007"), source: .others, offset: 121, text: "Let’s take the setup one first. Can we cut a step without losing the microphone check?"),
    ]
    private static let later: [MeetingSegment] = [
        MeetingSegment(id: id("000000000008"), source: .you, offset: 498, text: "I’m back. Sorry, my laptop went to sleep."),
        MeetingSegment(id: id("000000000009"), source: .others, offset: 512, text: "No problem. We agreed to try moving the shortcut step to the end."),
        MeetingSegment(id: id("000000000010"), source: .you, offset: 540, text: "That works for me. I’ll sketch it before Thursday."),
    ]

    static var live: Meeting {
        var stretch = MeetingStretch(id: id("0000000000A1"), start: 0, sources: [.you, .others])
        stretch.lastCheckpoint = 130
        return Meeting(id: id("0000000000B1"), title: "Weekly planning", created: base, appName: "Zoom", segments: planning, stretches: [stretch])
    }

    /// Locked once and resumed, then paused for `ended`.
    static func paused(_ ended: MeetingStretchEnd) -> Meeting {
        Meeting(id: id("0000000000B2"), title: "Weekly planning", created: base, appName: "Zoom", segments: planning + later,
                notes: "Shortcut step at the end?",
                stretches: [MeetingStretch(id: id("0000000000A2"), start: 0, sources: [.you, .others], end: 410, ended: .lockOrSleep),
                            MeetingStretch(id: id("0000000000A3"), start: 470, sources: [.you, .others], end: 754, ended: ended)])
    }

    static let finished = Meeting(id: id("0000000000B3"), title: "Weekly planning", created: base, appName: "Zoom", segments: planning + later,
        notes: "Launch checklist\n- Screenshots for the help page, today\n- Try the shortcut step at the end of setup",
        stretches: [MeetingStretch(id: id("0000000000A4"), start: 0, sources: [.you, .others], end: 410, ended: .lockOrSleep),
                    MeetingStretch(id: id("0000000000A5"), start: 470, sources: [.you, .others], end: 1932, ended: .finished)],
        state: .finished)

    static let recovered = Meeting(id: id("0000000000B4"), title: "Design review", created: base.addingTimeInterval(-2 * day), appName: "Zoom",
        segments: [MeetingSegment(id: id("000000000011"), source: .others, offset: 8, text: "Can everyone see the new settings layout?"),
                   MeetingSegment(id: id("000000000012"), source: .you, offset: 19, text: "Yes. The spacing reads much calmer than before."),
                   MeetingSegment(id: id("000000000013"), source: .others, offset: 2694, text: "Let’s pick this up again on Monday.")],
        stretches: [MeetingStretch(id: id("0000000000A6"), start: 0, sources: [.you, .others], end: 2710, ended: .unexpectedExit)],
        state: .finished)

    static let microphoneOnly = Meeting(id: id("0000000000B5"), created: base.addingTimeInterval(-5 * day), appName: Meeting.microphoneOnly,
        segments: [MeetingSegment(id: id("000000000014"), source: .you, offset: 6, text: "Notes from the kitchen table chat about the garden.")],
        stretches: [MeetingStretch(id: id("0000000000A7"), start: 0, sources: [.you], end: 905, ended: .finished)], state: .finished)

    static let oneOnOne = Meeting(id: id("0000000000B6"), title: "1:1 with Sam", created: base.addingTimeInterval(-9 * day), appName: "Zoom",
        segments: [MeetingSegment(id: id("000000000015"), source: .others, offset: 5, text: "How was the week?")],
        stretches: [MeetingStretch(id: id("0000000000A8"), start: 0, sources: [.you, .others], end: 1740, ended: .finished)], state: .finished)

    /// Turns the preview dictionary changes, You and Others alike.
    static let fixes = Meeting(id: id("0000000000B7"), title: "Sprint review", created: base.addingTimeInterval(3600), appName: "Zoom",
        segments: [MeetingSegment(id: id("000000000016"), source: .others, offset: 8, text: "Can you open the gira board so shivon can see the sprint?"),
                   MeetingSegment(id: id("000000000017"), source: .you, offset: 19, text: "Sure. I’ll also run cube cuddle get pods to check staging."),
                   MeetingSegment(id: id("000000000018"), source: .others, offset: 33, text: "Thanks. Anything blocking you this week?"),
                   MeetingSegment(id: id("000000000019"), source: .you, offset: 47, text: "Nothing on my side. shivon has the release notes.")],
        stretches: [MeetingStretch(id: id("0000000000A9"), start: 0, sources: [.you, .others], end: 612, ended: .finished)], state: .finished)
}
