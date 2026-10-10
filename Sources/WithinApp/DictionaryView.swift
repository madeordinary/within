import AppKit
import SwiftUI
import WithinCore

/// Settings → Dictionary, behind the developer default. Every change is a discrete action the model saves;
/// this page never reads or writes a file itself, and Try is a pure call that saves and records nothing.
struct DictionaryPage: View {
    enum Focus: Hashable { case search, table, addWord }
    static let fullSentence = "Your dictionary holds up to 500 words. Delete some to add more."
    static let deleteMessage = "This removes your dictionary from Within, including any earlier file it kept. Existing Time Machine backups keep earlier copies until they expire. Like other deleted files, it isn’t a secure erase."
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var selection: DictionaryEntry.ID?
    @State private var editor: DictionaryEditorTarget?
    @State private var deleting: DictionaryEntry?
    @State private var confirmingDeleteAll = false
    @State private var confirmingStartNew = false
    @State private var confirmingDeleteFile = false
    @FocusState private var focus: Focus?
    /// VoiceOver's cursor; keyboard focus alone can't reach buttons while keyboard navigation is off.
    @AccessibilityFocusState private var voiceOverFocus: Focus?
    private var entries: [DictionaryEntry] { model.dictionary.entries }
    private var full: Bool { entries.count >= DictionaryPolicy.maximumEntries }
    private var visible: [DictionaryEntry] { DictionaryPolicy.matching(DictionaryPolicy.sorted(entries), query: query) }
    /// Any file Within keeps for the dictionary: the saved one, readable or not, or an earlier one it set aside.
    private var hasFiles: Bool { model.dictionaryState != .missing || model.dictionaryHasSetAside || !entries.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your dictionary").font(Typography.display(26)).accessibilityAddTraits(.isHeader)
                Text("Fix how Within writes names and terms. Changes happen on this Mac after transcription, and the original transcription stays available.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            if !model.dictionaryMessage.isEmpty {
                Label(model.dictionaryMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
            }
            if model.canEditDictionary { editing } else { notice }
            footer
            DictionaryTryField(model: model).disabled(!model.canEditDictionary)
            Text("Saved on this Mac and included in your Time Machine backups. Within never uploads it, and it’s never part of diagnostics.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: entries.isEmpty) { _, empty in if empty { query = ""; selection = nil } }
        .sheet(item: $editor) { target in
            DictionaryEntryEditor(model: model, entry: target.entry, showingIssues: target.entry.map { model.dictionaryIssues[$0.id] != nil } ?? false) { id in
                guard let id else { return }
                if !visible.contains(where: { $0.id == id }) { query = "" }
                selection = id; moveFocus(to: .table)
            }
        }
        .confirmationDialog(deleting.map { "Delete “\($0.writeAs)” from your dictionary?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { entry in
            Button("Delete word", role: .destructive) { delete(entry) }
            Button("Keep word", role: .cancel) {}
        }
        .confirmationDialog("Delete your whole dictionary?", isPresented: $confirmingDeleteAll) {
            // While the file can't be used, only deleting the files themselves is offered.
            Button("Delete all words", role: .destructive) {
                if model.canEditDictionary { model.deleteAllDictionaryEntries() } else { model.deleteDictionaryFiles() }
                if model.canEditDictionary && entries.isEmpty { moveFocus(to: .addWord) }
            }
            Button("Keep them", role: .cancel) {}
        } message: { Text(Self.deleteMessage) }
        .confirmationDialog("Start a new dictionary?", isPresented: $confirmingStartNew) {
            Button("Start a new dictionary") {
                model.startNewDictionary()
                if model.canEditDictionary { moveFocus(to: .addWord) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.dictionaryState == .newerVersion
                ? "Within will rename the current file, keep it in the Dictionary folder, and start an empty dictionary. Newer versions of Within won’t use the renamed file automatically. Updating Within first keeps your words."
                : "Within will rename the current file, keep it in the Dictionary folder, and start an empty dictionary.")
        }
        .confirmationDialog("Delete your dictionary file?", isPresented: $confirmingDeleteFile) {
            Button("Delete dictionary file", role: .destructive) {
                model.deleteDictionaryFiles()
                if model.canEditDictionary { moveFocus(to: .addWord) }
            }
            Button("Keep the file", role: .cancel) {}
        } message: { Text(Self.deleteMessage) }
    }

    /// Items 3 to 8: hidden while the file can't be used.
    @ViewBuilder private var editing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use my dictionary").font(.system(size: 13, weight: .medium))
                    Text("Applies to dictation and practice. Turn it off to get words exactly as transcribed.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Use my dictionary", isOn: Binding(get: { model.dictionary.enabled }, set: model.setDictionaryEnabled))
                    .labelsHidden().toggleStyle(.switch)
            }
        }.withinSurface(padding: 16)
        if model.isActive && !model.isRecordingNote { DictionaryRecordingLine() }
        if entries.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("No words yet. Add names and terms Within gets wrong, and it will write them your way. Type each one the way Within writes it now. Not sure? Say it in Try dictation and look at what appears.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                addWordButton
            }.withinSurface(padding: 16)
        } else {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary).accessibilityHidden(true)
                    TextField("Search", text: $query).textFieldStyle(.plain).accessibilityLabel("Search dictionary")
                        .focused($focus, equals: .search).accessibilityFocused($voiceOverFocus, equals: .search)
                }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6).frame(width: 180)
                    .background(Palette.canvas.opacity(0.75), in: Capsule())
                Spacer(minLength: 8)
                if full {
                    Text(Self.fullSentence).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
                addWordButton
            }
            let rows = visible
            if rows.isEmpty {
                Text("No words match “\(query)”.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            } else {
                DictionaryTable(model: model, entries: rows, selection: $selection, focus: $focus, voiceOverFocus: $voiceOverFocus,
                    add: { editor = DictionaryEditorTarget(entry: nil) }, edit: { editor = DictionaryEditorTarget(entry: $0) }, delete: { deleting = $0 })
            }
        }
    }

    /// One Add word… at a time: in the toolbar, or in the empty state.
    private var addWordButton: some View {
        Button("Add word…") { editor = DictionaryEditorTarget(entry: nil) }.primaryAction()
            .disabled(full).accessibilityHint(full ? Self.fullSentence : "")
            .focused($focus, equals: .addWord).accessibilityFocused($voiceOverFocus, equals: .addWord)
    }

    /// Item 2: the file is left untouched until the user chooses to set it aside or delete it.
    private var notice: some View {
        let startNew = Button("Start a new dictionary…") { confirmingStartNew = true }.quietAction()
        let deleteFile = Button("Delete dictionary file…", role: .destructive) { confirmingDeleteFile = true }.quietAction()
        let showFile = Button("Show in Finder") { model.showDictionaryFilesInFinder(setAside: false) }.quietAction()
            .accessibilityHint("Shows the dictionary file in Finder")
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.warning).accessibilityHidden(true)
                Text(model.dictionaryState == .newerVersion
                    ? "This dictionary was saved by a newer version of Within. Update Within to use or change it."
                    : "Your dictionary file couldn’t be read, so no changes are being made to your words. The file was left untouched.")
                    .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { startNew; deleteFile; Spacer(minLength: 0); showFile }
                VStack(alignment: .leading, spacing: 10) { HStack(spacing: 10) { startNew; deleteFile }; showFile }
            }
        }.withinSurface(padding: 16)
    }

    /// Item 9. While the notice shows, only the set-aside line and Delete all… remain.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if model.canEditDictionary {
                    Text(entries.count == 1 ? "1 word · up to 500" : "\(entries.count) words · up to 500")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 12)
                Button("Delete all…", role: .destructive) { confirmingDeleteAll = true }.quietAction().disabled(!hasFiles)
            }
            if model.dictionaryHasSetAside {
                HStack(spacing: 12) {
                    Text("An earlier dictionary file is kept in the Dictionary folder.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Show in Finder") { model.showDictionaryFilesInFinder(setAside: true) }.quietAction()
                        .accessibilityHint("Shows the earlier dictionary file in Finder")
                }
            }
        }
    }

    /// Focus goes to the next row, or the search field when no row is left; the model announces the deletion.
    private func delete(_ entry: DictionaryEntry) {
        let remaining = visible.filter { $0.id != entry.id }
        let index = visible.firstIndex { $0.id == entry.id } ?? 0
        let next = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        model.deleteDictionaryEntry(entry.id)
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        selection = next
        moveFocus(to: next != nil ? .table : entries.isEmpty ? .addWord : .search)
    }
    /// After the control that had focus is gone or the content changed.
    private func moveFocus(to target: Focus) {
        DispatchQueue.main.async { focus = target; voiceOverFocus = target }
    }
}

struct DictionaryEditorTarget: Identifiable {
    let id = UUID()
    /// `nil` adds a word.
    let entry: DictionaryEntry?
}

/// Rows sorted by "Change to". A row's switch is off and disabled while the entry needs attention.
struct DictionaryTable: View {
    @ObservedObject var model: AppModel
    let entries: [DictionaryEntry]
    @Binding var selection: DictionaryEntry.ID?
    var focus: FocusState<DictionaryPage.Focus?>.Binding
    var voiceOverFocus: AccessibilityFocusState<DictionaryPage.Focus?>.Binding
    let add: () -> Void
    let edit: (DictionaryEntry) -> Void
    let delete: (DictionaryEntry) -> Void
    private var selected: DictionaryEntry? { entries.first { $0.id == selection } }
    private var full: Bool { model.dictionary.entries.count >= DictionaryPolicy.maximumEntries }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(entries, selection: $selection) {
                TableColumn("Change to") { entry in
                    Text(entry.writeAs).font(.system(size: 13, weight: .medium)).lineLimit(1).modifier(DictionaryCellColor(Palette.text))
                }
                TableColumn("When Within writes") { entry in
                    DictionaryPhrasesCell(entry: entry, issue: model.dictionaryIssues[entry.id]?.first)
                }
                TableColumn("On") { entry in
                    DictionaryEntrySwitch(model: model, entry: entry)
                }.width(44)
            }
            // A fixed height: a Table inside the Settings page's ScrollView has no height of its own.
            .frame(height: 320)
            .accessibilityLabel("Dictionary words")
            .focused(focus, equals: .table).accessibilityFocused(voiceOverFocus, equals: .table)
            .contextMenu(forSelectionType: DictionaryEntry.ID.self, menu: { _ in EmptyView() }, primaryAction: { ids in
                if let id = ids.first, let entry = entries.first(where: { $0.id == id }) { edit(entry) }
            })
            .onKeyPress(.return) {
                guard let selected else { return .ignored }
                edit(selected); return .handled
            }
            .onDeleteCommand { if let selected { delete(selected) } }
            HStack(spacing: 8) {
                Button(action: add) { Image(systemName: "plus").frame(width: 14, height: 16) }.quietAction()
                    .help("Add word").accessibilityLabel("Add word")
                    .disabled(full).accessibilityHint(full ? DictionaryPage.fullSentence : "")
                Button { if let selected { delete(selected) } } label: { Image(systemName: "minus").frame(width: 14, height: 16) }.quietAction()
                    .help("Delete selected word").accessibilityLabel("Delete selected word").disabled(selected == nil)
                Button("Edit…") { if let selected { edit(selected) } }.quietAction().disabled(selected == nil)
            }
        }
    }
}

/// The reason a word isn't used wraps, so it can be read in full without a pointer.
private struct DictionaryPhrasesCell: View {
    let entry: DictionaryEntry
    let issue: DictionaryIssue?
    var body: some View {
        if let issue {
            // A table cell is one line unless it says otherwise.
            Text("Not in use: \(issue.message)").font(.system(size: 11)).modifier(DictionaryCellColor(Palette.warning))
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(entry.heardAs.joined(separator: ", ")).font(.system(size: 11)).modifier(DictionaryCellColor(Palette.secondary)).lineLimit(1)
        }
    }
}

/// On the focused table's selected row the highlight is a vivid colour, so cell text takes the system's
/// selected-text colour there; everywhere else it keeps its full Palette value.
private struct DictionaryCellColor: ViewModifier {
    let color: Color
    @Environment(\.backgroundProminence) private var prominence
    init(_ color: Color) { self.color = color }
    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? Color(nsColor: .alternateSelectedControlTextColor) : color)
    }
}

private struct DictionaryEntrySwitch: View {
    @ObservedObject var model: AppModel
    let entry: DictionaryEntry
    var body: some View {
        let usable = model.dictionaryIssues[entry.id] == nil
        Toggle("Use \(entry.writeAs)", isOn: usable ? Binding(get: { entry.enabled }, set: { model.setDictionaryEntry(entry.id, enabled: $0) }) : .constant(false))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!usable)
    }
}

/// Shown on the page and in the editor while a dictation or practice recording runs: it keeps the dictionary
/// it started with. Notes don't use the dictionary, so a note recording doesn't show it.
struct DictionaryRecordingLine: View {
    var body: some View {
        Label("You’re recording. Changes apply from your next recording.", systemImage: "mic.fill")
            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
    }
}

/// A pure call on the dictionary in use: nothing is saved or recorded, and no microphone is used.
struct DictionaryTryField: View {
    @ObservedObject var model: AppModel
    @State private var text: String
    init(model: AppModel, text: String = "") {
        _model = ObservedObject(wrappedValue: model); _text = State(initialValue: text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try your dictionary").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            TextField("Type a sentence to try", text: $text).textFieldStyle(.roundedBorder).accessibilityLabel("Try your dictionary")
            if !text.isEmpty {
                let result = model.dictionaryMatcher.apply(to: text)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(result.changes.isEmpty ? "No changes." : result.changes.count == 1 ? "1 change." : "\(result.changes.count) changes.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
        }.withinSurface()
    }
}

/// Add or edit one word. A field is checked when it is committed and on Save, never on every keystroke,
/// so "node." on the way to "node.js" is never flagged. Messages sit right after their field.
struct DictionaryEntryEditor: View {
    enum Field: Hashable { case writeAs, phrase(UUID) }
    struct Phrase: Identifiable { let id = UUID(); var text: String }
    @ObservedObject var model: AppModel
    /// `nil` adds a word.
    let entry: DictionaryEntry?
    /// After a successful Save, with the word's id.
    var saved: (DictionaryEntry.ID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var writeAs: String
    @State private var phrases: [Phrase]
    @State private var messages: [Field: [String]]
    @FocusState private var focus: Field?

    /// `writeAs`, `phrases` and `showingIssues` start the editor in a given state, as for an entry that needs attention.
    init(model: AppModel, entry: DictionaryEntry?, writeAs: String? = nil, phrases: [String]? = nil, showingIssues: Bool = false,
         saved: @escaping (DictionaryEntry.ID?) -> Void = { _ in }) {
        _model = ObservedObject(wrappedValue: model)
        self.entry = entry; self.saved = saved
        let typed = writeAs ?? entry?.writeAs ?? ""
        let given = (phrases ?? entry?.heardAs ?? []).map { Phrase(text: $0) }
        let fields = given.isEmpty ? [Phrase(text: "")] : given
        _writeAs = State(initialValue: typed)
        _phrases = State(initialValue: fields)
        _messages = State(initialValue: showingIssues ? Self.grouped(Self.issues(model, entry, typed, fields), fields) : [:])
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(entry == nil ? "Add a word" : "Edit word").font(.system(size: 24, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if model.isActive && !model.isRecordingNote { DictionaryRecordingLine() }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Change to").font(.system(size: 13, weight: .medium)).accessibilityHidden(true)
                        TextField("Change to", text: $writeAs).textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .writeAs).onSubmit { commit(.writeAs) }
                        issueLines(.writeAs)
                        hint("Exactly as you want it written, including capitals. The dictionary fixes how words are written; it doesn’t expand text.")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When Within writes").font(.system(size: 13, weight: .medium)).accessibilityAddTraits(.isHeader)
                        ForEach(Array(phrases.enumerated()), id: \.element.id) { index, phrase in
                            phraseField(index, phrase)
                        }
                        if phrases.count < DictionaryPolicy.maximumPhrases {
                            Button(action: addPhrase) { Label("Add another", systemImage: "plus") }.quietAction()
                        }
                        hint("Type it the way Within writes it now, for example “gira”. Whole words, any capitalization, up to 6 words. Not sure? Say the word in Try dictation and look at what appears.")
                    }
                    if let preview {
                        Text(preview).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            // Pinned below the fields, so ten phrases with messages never push the buttons out of the sheet.
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save).primaryAction().keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 28).padding(.vertical, 16)
        }.frame(width: 486, height: 520).background(Palette.canvas).foregroundStyle(Palette.text).tint(Palette.accent)
            .onAppear { DispatchQueue.main.async { focus = .writeAs } }
            .onChange(of: focus) { old, new in if let old, old != new { commit(old) } }
    }

    private func phraseField(_ index: Int, _ phrase: Phrase) -> some View {
        let label = "Within writes, \(index + 1) of \(phrases.count)"
        let typed = DictionaryPolicy.normalized(phrase.text)
        let remove = typed.isEmpty ? "Remove empty field" : "Remove “\(typed)”"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(label, text: Binding(get: { phrases.first { $0.id == phrase.id }?.text ?? "" },
                                               set: { text in if let at = phrases.firstIndex(where: { $0.id == phrase.id }) { phrases[at].text = text } }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .phrase(phrase.id)).onSubmit { commit(.phrase(phrase.id)) }
                Button { removePhrase(phrase.id) } label: { Image(systemName: "minus.circle").font(.system(size: 14)).frame(width: 20, height: 20) }
                    .buttonStyle(.borderless).foregroundStyle(Palette.secondary)
                    .help(remove).accessibilityLabel(remove).disabled(phrases.count == 1)
            }
            issueLines(.phrase(phrase.id))
        }
    }
    private func issueLines(_ field: Field) -> some View {
        ForEach(Array((messages[field] ?? []).enumerated()), id: \.offset) { _, message in
            Text(message).font(.system(size: 11)).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// "“gira” will be written “Jira”." while the word is valid: what the dictionary does with its first phrase.
    private var preview: String? {
        guard let first = phrases.map({ DictionaryPolicy.normalized($0.text) }).first(where: { !$0.isEmpty }),
              Self.issues(model, entry, writeAs, phrases).isEmpty else { return nil }
        var draft = Self.draft(entry, writeAs, phrases)
        draft.enabled = true
        return "“\(first)” will be written “\(DictionaryMatcher(PersonalDictionary(entries: [draft])).apply(to: first).text)”."
    }

    /// A committed field shows its own problems; other fields only lose messages that no longer apply.
    /// A blank field waits for Save, so tabbing past it never flags it.
    private func commit(_ field: Field?) {
        let current = Self.grouped(Self.issues(model, entry, writeAs, phrases), phrases)
        var next: [Field: [String]] = [:]
        for (key, shown) in messages {
            let still = shown.filter { current[key]?.contains($0) == true }
            if !still.isEmpty { next[key] = still }
        }
        if let field, !text(of: field).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next[field] = current[field] }
        messages = next
    }
    private func text(of field: Field) -> String {
        switch field {
        case .writeAs: return writeAs
        case .phrase(let id): return phrases.first { $0.id == id }?.text ?? ""
        }
    }
    private func addPhrase() {
        guard phrases.count < DictionaryPolicy.maximumPhrases else { return }
        let phrase = Phrase(text: "")
        phrases.append(phrase)
        DispatchQueue.main.async { focus = .phrase(phrase.id) }
    }
    /// Focus moves to the previous phrase field, or the new first one.
    private func removePhrase(_ id: UUID) {
        guard phrases.count > 1, let index = phrases.firstIndex(where: { $0.id == id }) else { return }
        phrases.remove(at: index)
        messages[.phrase(id)] = nil
        commit(nil)
        let target = phrases[max(0, index - 1)].id
        DispatchQueue.main.async { focus = .phrase(target) }
    }
    private func save() {
        let heardAs = phrases.map(\.text)
        // Nothing to save into: the file became unusable or the word is gone.
        guard model.canEditDictionary, entry.map({ old in model.dictionary.entries.contains { $0.id == old.id } }) ?? true else { dismiss(); return }
        let issues = entry.map { model.updateDictionaryEntry($0.id, heardAs: heardAs, writeAs: writeAs) }
            ?? model.addDictionaryEntry(heardAs: heardAs, writeAs: writeAs)
        guard let first = issues.first else {
            let id = entry?.id ?? model.dictionary.entries.last?.id
            dismiss()
            // A failed save has already announced itself; don't talk over it. Announcements never carry words.
            if model.dictionaryMessage.isEmpty { model.announce(entry == nil ? "Word added to your dictionary" : "Changes saved") }
            saved(id)
            return
        }
        messages = Self.grouped(issues, phrases)
        focus = Self.field(for: first, phrases)
        model.announce(Self.announcement(for: first))
    }
    /// The message without dictionary words; the one on screen, right after the focused field, keeps them.
    private static func announcement(for issue: DictionaryIssue) -> String {
        switch issue {
        case .repeatedPhrase: return "You’ve already added this phrase."
        case .usedPhrase, .duplicatePhrase: return "This phrase is already used for another word."
        case .emptyWriteAs, .longWriteAs, .distantWriteAs, .multilineWriteAs, .wordlessWriteAs, .markerInWriteAs, .noPhrase, .tooManyPhrases,
             .longPhrase, .phraseEdges, .phraseCharacters, .overLimit, .dictionaryFull: return issue.message
        }
    }

    private static func draft(_ entry: DictionaryEntry?, _ writeAs: String, _ phrases: [Phrase]) -> DictionaryEntry {
        var draft = entry ?? DictionaryEntry(heardAs: [], writeAs: "", created: Date())
        draft.heardAs = phrases.map(\.text); draft.writeAs = writeAs
        return draft
    }
    /// Phrase positions match the fields one to one; blank fields are ignored by the policy, not removed.
    /// A word past the limit in a hand-edited file says so too: saving it doesn't put it back in use.
    private static func issues(_ model: AppModel, _ entry: DictionaryEntry?, _ writeAs: String, _ phrases: [Phrase]) -> [DictionaryIssue] {
        let overLimit = entry.flatMap { model.dictionaryIssues[$0.id] }?.contains(.overLimit) == true
        return DictionaryPolicy.editorIssues(for: draft(entry, writeAs, phrases), in: model.dictionary) + (overLimit ? [.overLimit] : [])
    }
    private static func field(for issue: DictionaryIssue, _ phrases: [Phrase]) -> Field {
        if let index = issue.phraseIndex, phrases.indices.contains(index) { return .phrase(phrases[index].id) }
        switch issue {
        case .noPhrase, .tooManyPhrases: return .phrase(phrases[0].id)
        default: return .writeAs
        }
    }
    private static func grouped(_ issues: [DictionaryIssue], _ phrases: [Phrase]) -> [Field: [String]] {
        var result: [Field: [String]] = [:]
        for issue in issues { result[field(for: issue, phrases), default: []].append(issue.message) }
        return result
    }
}
