import SwiftUI
import WithinCore

/// Notes space: saved notes beside a page you can type into or talk into.
struct NotesView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    var body: some View {
        HStack(spacing: 0) {
            noteList.frame(width: 250)
            Divider()
            if let note = model.selectedNote {
                NoteEditor(model: model, note: note)
            } else {
                emptyState
            }
        }
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notes").font(Typography.display(26)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { model.newNote() } label: { Image(systemName: "square.and.pencil").frame(width: 28, height: 26) }
                    .buttonStyle(.borderless).help("New note").accessibilityLabel("New note")
                    .keyboardShortcut("n", modifiers: .command)
            }
            if !model.notes.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary).accessibilityHidden(true)
                    TextField("Search notes", text: $query).textFieldStyle(.plain).accessibilityLabel("Search notes")
                }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Palette.canvas.opacity(0.75), in: Capsule())
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(NoteText.matching(model.notes, query: query)) { note in row(note) }
                }
            }
        }.padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
    }

    private func row(_ note: Note) -> some View {
        let selected = model.selectedNoteID == note.id
        let recording = model.recordingNoteID == note.id
        return Button { model.selectedNoteID = note.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if recording { Circle().fill(Palette.accent).frame(width: 7, height: 7).accessibilityHidden(true) }
                    Text(note.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                Text(note.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                .background(selected ? Palette.tint : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(recording ? "\(note.displayTitle), recording" : note.displayTitle)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("A page for your thoughts.").font(Typography.display(28))
            Text("Start a note, press Record and talk. Words appear a few seconds after you speak and are saved only on this Mac.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("New note") { model.newNote() }.primaryAction()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }
}

struct NoteEditor: View {
    @ObservedObject var model: AppModel
    let note: Note
    @State private var confirmingDelete = false
    private var recordingThis: Bool { model.recordingNoteID == note.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Untitled", text: Binding(get: { model.selectedNote?.title ?? "" }, set: { model.updateNote(note.id, title: $0) }))
                    .textFieldStyle(.plain).font(Typography.display(28)).accessibilityLabel("Note title")
                Button { confirmingDelete = true } label: { Image(systemName: "trash").frame(width: 28, height: 26) }
                    .buttonStyle(.borderless).foregroundStyle(Palette.secondary).help("Delete note")
                    .accessibilityLabel("Delete note").disabled(recordingThis)
            }.padding(.horizontal, 32).padding(.top, 30)
            Text(note.created.formatted(date: .complete, time: .shortened))
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.horizontal, 32).padding(.top, 4)
            TextEditor(text: Binding(get: { model.selectedNote?.body ?? "" }, set: { model.updateNote(note.id, body: $0) }))
                .font(.system(size: 14)).lineSpacing(4).scrollContentBackground(.hidden)
                .padding(.horizontal, 27).padding(.top, 14)
                .accessibilityLabel("Note text")
            recorder.padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 8)
        }.confirmationDialog("Delete this note?", isPresented: $confirmingDelete) {
            Button("Delete note", role: .destructive) { model.deleteNote(note.id) }
            Button("Keep note", role: .cancel) {}
        } message: { Text("It will be removed from this Mac. It cannot be undone.") }
    }

    @ViewBuilder private var recorder: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recordingThis {
                ScrollViewReader { proxy in
                    ScrollView {
                        (Text(model.liveConfirmed) + Text(model.liveVolatile.isEmpty ? "" : " " + model.liveVolatile).foregroundColor(Palette.secondary))
                            .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).id("tail")
                        if model.liveConfirmed.isEmpty && model.liveVolatile.isEmpty {
                            Text(model.phase == .preparing ? "Getting ready…" : model.phase == .transcribing ? "Saving your words…" : "Listening… words appear here in short bursts, a few seconds behind you.")
                                .font(.system(size: 13)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxHeight: 110)
                        .onChange(of: model.liveVolatile) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
                }.accessibilityElement(children: .combine).accessibilityLabel("Live transcript")
                HStack(spacing: 12) {
                    LevelBars(levels: LevelBars.seed(Double(model.level)), color: Palette.accent).accessibilityHidden(true)
                    Text(model.phase == .transcribing ? "Saving…" : String(format: "Recording · %d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                    Spacer()
                    Button("Stop") { model.stop() }.primaryAction().disabled(model.phase != .recording && model.phase != .preparing)
                        .accessibilityLabel("Stop recording and save")
                }
            } else {
                HStack(spacing: 12) {
                    Button { model.startNoteRecording(note.id) } label: { Label("Record", systemImage: "mic.fill") }
                        .primaryAction().disabled(!model.canStart || model.isRecordingNote)
                        .accessibilityHint("Starts the microphone and adds your words to this note")
                    Text(model.selectedInputName).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                    Spacer()
                    Label("Saved on this Mac", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            if !model.notesMessage.isEmpty {
                Text(model.notesMessage).font(.system(size: 11)).foregroundStyle(Palette.warning)
            }
        }.padding(14).background(Palette.canvas.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
