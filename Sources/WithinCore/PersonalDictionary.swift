import Foundation

/// A word the user taught Within: the ways the speech model writes it, and how it should be written.
public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// "When Within writes": matched whole-word, in any capitalization.
    public var heardAs: [String]
    /// "Change to": written exactly as typed, including capitals and punctuation.
    public var writeAs: String
    public var enabled: Bool
    public let created: Date
    public var modified: Date

    public init(id: UUID = UUID(), heardAs: [String], writeAs: String, enabled: Bool = true, created: Date) {
        self.id = id; self.heardAs = heardAs; self.writeAs = writeAs; self.enabled = enabled
        self.created = created; self.modified = created
    }
}

/// The whole saved file. `version` changes only for incompatible meaning, never for additive fields.
public struct PersonalDictionary: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// The largest saved file Within reads. A reader needs at most one byte more to tell.
    public static let maximumFileSize = 2_000_000
    public var version: Int
    /// "Use my dictionary". Off means words are written exactly as transcribed.
    public var enabled: Bool
    public var entries: [DictionaryEntry]

    public init(enabled: Bool = true, entries: [DictionaryEntry] = []) {
        version = Self.currentVersion; self.enabled = enabled; self.entries = entries
    }

    public enum Decoded: Equatable, Sendable { case loaded(PersonalDictionary), unreadable, newerVersion }

    /// The version is read before the full payload, so a newer file with a different shape is
    /// recognized as newer, never as corrupt. Repeated entry ids are made unique in memory only.
    public static func decode(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        guard data.count <= maximumFileSize,
              let probe = try? decoder.decode(DictionaryVersionProbe.self, from: data) else { return .unreadable }
        guard probe.version <= currentVersion else { return .newerVersion }
        guard let dictionary = try? decoder.decode(PersonalDictionary.self, from: data) else { return .unreadable }
        return .loaded(DictionaryPolicy.uniquingIDs(dictionary))
    }
}

/// Decoded first, before the full payload, so a newer file with a different shape is still recognized as newer.
struct DictionaryVersionProbe: Decodable { let version: Int }

public struct DictionaryChange: Equatable, Sendable {
    /// The exact source text that matched.
    public let transcribed: String
    /// The entry's "Change to".
    public let written: String
    /// Where `written` sits in `DictionaryResult.text`, as UTF-8 offsets.
    public let outputUTF8Range: Range<Int>
    public init(transcribed: String, written: String, outputUTF8Range: Range<Int>) {
        self.transcribed = transcribed; self.written = written; self.outputUTF8Range = outputUTF8Range
    }
}

public struct DictionaryResult: Equatable, Sendable {
    /// The original transcription.
    public let original: String
    /// Your spellings.
    public let text: String
    public let changes: [DictionaryChange]
    public var changed: Bool { !changes.isEmpty }
    public init(original: String, text: String, changes: [DictionaryChange]) {
        self.original = original; self.text = text; self.changes = changes
    }
    public init(unchanged text: String) { self.init(original: text, text: text, changes: []) }
}

/// A problem with an entry. Phrase issues carry the phrase's position in `heardAs`.
public enum DictionaryIssue: Equatable, Hashable, Sendable {
    case emptyWriteAs, longWriteAs, distantWriteAs, multilineWriteAs, wordlessWriteAs, markerInWriteAs
    case noPhrase, tooManyPhrases
    case longPhrase(Int), phraseEdges(Int), phraseCharacters(Int)
    case repeatedPhrase(Int, phrase: String)
    case usedPhrase(Int, phrase: String, writeAs: String)
    case duplicatePhrase(Int, phrase: String, earlierWriteAs: String)
    case overLimit, dictionaryFull

    public var phraseIndex: Int? {
        switch self {
        case .longPhrase(let index), .phraseEdges(let index), .phraseCharacters(let index),
             .repeatedPhrase(let index, _), .usedPhrase(let index, _, _), .duplicatePhrase(let index, _, _): return index
        default: return nil
        }
    }

    public var message: String {
        switch self {
        case .emptyWriteAs: return "Enter how Within should write it."
        case .longWriteAs: return "Keep it to 100 characters or fewer."
        case .distantWriteAs: return "Keep this close to what Within writes. The dictionary fixes spellings; it doesn’t expand text."
        case .multilineWriteAs: return "Use a single line of text."
        case .wordlessWriteAs: return "Include at least one letter or number."
        case .markerInWriteAs: return "Remove the “<”, “|” and “>” characters."
        case .noPhrase: return "Add at least one way Within writes it."
        case .tooManyPhrases: return "Use up to 10 ways Within writes it."
        case .longPhrase: return "Keep each one to 64 characters and 6 words."
        case .phraseEdges: return "Start and end with a letter or number."
        case .phraseCharacters: return "Use letters, numbers, spaces, hyphens, apostrophes and periods."
        case .repeatedPhrase(_, let phrase): return "You’ve already added “\(phrase)”."
        case .usedPhrase(_, let phrase, let writeAs): return "“\(phrase)” is already used for “\(writeAs)”."
        case .duplicatePhrase(_, let phrase, let earlier): return "“\(phrase)” is also used for “\(earlier)”, which is used instead."
        case .overLimit: return "Your dictionary holds up to 500 words. This one isn’t used."
        case .dictionaryFull: return "Your dictionary holds up to 500 words. Delete some to add more."
        }
    }
}

public enum DictionaryPolicy {
    public static let maximumEntries = 500
    public static let maximumPhrases = 10
    public static let maximumPhraseLength = 64
    public static let maximumPhraseWords = 6
    public static let maximumWriteAsLength = 100

    /// Trims the ends, as `TranscriptFormatting.clean` does, and collapses each internal run of two or
    /// more spaces to one space; a single space of any kind is kept as typed. This is the only change
    /// ever made to what the user typed, and it runs after prohibited input is rejected.
    public static func normalized(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var run = String.UnicodeScalarView()
        for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if scalar.properties.generalCategory == .spaceSeparator { run.append(scalar); continue }
            if !run.isEmpty { result.append(contentsOf: run.count == 1 ? run : " ".unicodeScalars); run = String.UnicodeScalarView() }
            result.append(scalar)
        }
        return String(result)
    }

    /// Every problem with an entry about to be saved, in field order.
    public static func editorIssues(for entry: DictionaryEntry, in dictionary: PersonalDictionary) -> [DictionaryIssue] {
        var others: [Path: String] = [:]
        for other in prioritized(dictionary.entries).map({ dictionary.entries[$0] }) where other.id != entry.id {
            for (index, phrase) in other.heardAs.enumerated() {
                if let path = review(phrase, at: index).path, others[path] == nil { others[path] = normalized(other.writeAs) }
            }
        }
        let isNew = !dictionary.entries.contains { $0.id == entry.id }
        return (isNew && dictionary.entries.count >= maximumEntries ? [.dictionaryFull] : []) + review(entry, others: others).issues
    }

    /// Problems with a loaded file's entries. Entries with issues are kept but never used.
    public static func loadIssues(_ dictionary: PersonalDictionary) -> [UUID: [DictionaryIssue]] {
        var result: [UUID: [DictionaryIssue]] = [:]
        for (index, issues) in audit(dictionary).issues.enumerated() where !issues.isEmpty {
            result[dictionary.entries[index].id, default: []] += issues
        }
        return result
    }

    /// The first entry with an id keeps it; later ones get a fresh id in memory, with their content unchanged.
    /// A fresh id is the next unused one after the repeated id, so it sorts after it and priority order,
    /// and with it which entry wins a duplicate phrase, is the same on every load.
    public static func uniquingIDs(_ dictionary: PersonalDictionary) -> PersonalDictionary {
        var copy = dictionary
        var taken = Set(copy.entries.map(\.id))
        var seen = Set<UUID>()
        for index in copy.entries.indices where !seen.insert(copy.entries[index].id).inserted {
            let old = copy.entries[index]
            var id = old.id.uuid
            repeat {
                withUnsafeMutableBytes(of: &id) { bytes in
                    for byte in bytes.indices.reversed() { bytes[byte] &+= 1; if bytes[byte] != 0 { break } }
                }
            } while !taken.insert(UUID(uuid: id)).inserted
            var fresh = DictionaryEntry(id: UUID(uuid: id), heardAs: old.heardAs, writeAs: old.writeAs, enabled: old.enabled, created: old.created)
            fresh.modified = old.modified
            copy.entries[index] = fresh
        }
        return copy
    }

    public static func matching(_ entries: [DictionaryEntry], query: String) -> [DictionaryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        let found = { (text: String) in text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return entries.filter { found($0.writeAs) || $0.heardAs.contains(where: found) }
    }

    public static func sorted(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.sorted {
            let order = $0.writeAs.localizedStandardCompare($1.writeAs)
            return order == .orderedSame ? $0.created < $1.created : order == .orderedAscending
        }
    }

    struct Step: Hashable { let kind: SeparatorKind; let word: String }
    typealias Path = [Step]
    struct Usable { let writeAs: String; let paths: [Path] }

    /// Positions in priority order: `created` ascending, then the id's text.
    static func prioritized(_ entries: [DictionaryEntry]) -> [Int] {
        entries.indices.sorted { (entries[$0].created, entries[$0].id.uuidString, $0) < (entries[$1].created, entries[$1].id.uuidString, $1) }
    }

    /// Issues by entry position, and the entries the matcher may use, in priority order.
    static func audit(_ dictionary: PersonalDictionary) -> (issues: [[DictionaryIssue]], usable: [Usable]) {
        var issues = [[DictionaryIssue]](repeating: [], count: dictionary.entries.count)
        var usable: [Usable] = []
        var used: [Path: String] = [:]
        for (rank, index) in prioritized(dictionary.entries).enumerated() {
            let entry = dictionary.entries[index]
            let reviewed = review(entry)
            issues[index] = reviewed.issues
            if rank >= maximumEntries {
                issues[index].append(.overLimit)
            } else if entry.enabled, reviewed.issues.isEmpty {
                if let repeated = reviewed.phrases.first(where: { used[$0.path] != nil }) {
                    issues[index].append(.duplicatePhrase(repeated.index, phrase: repeated.phrase, earlierWriteAs: used[repeated.path]!))
                } else {
                    for phrase in reviewed.phrases { used[phrase.path] = reviewed.writeAs }
                    usable.append(Usable(writeAs: reviewed.writeAs, paths: reviewed.phrases.map(\.path)))
                }
            }
        }
        return (issues, usable)
    }

    private static func review(_ entry: DictionaryEntry, others: [Path: String] = [:])
        -> (issues: [DictionaryIssue], writeAs: String, phrases: [(index: Int, phrase: String, path: Path)]) {
        var phraseIssues: [DictionaryIssue] = []
        var phrases: [(index: Int, phrase: String, path: Path)] = []
        var given = 0
        for (index, raw) in entry.heardAs.enumerated() {
            let reviewed = review(raw, at: index)
            if reviewed.phrase.isEmpty { continue }
            given += 1
            phraseIssues += reviewed.issues
            guard let path = reviewed.path else { continue }
            if phrases.contains(where: { $0.path == path }) {
                phraseIssues.append(.repeatedPhrase(index, phrase: reviewed.phrase))
            } else if let writeAs = others[path] {
                phraseIssues.append(.usedPhrase(index, phrase: reviewed.phrase, writeAs: writeAs))
                phrases.append((index, reviewed.phrase, path))
            } else {
                phrases.append((index, reviewed.phrase, path))
            }
        }
        let writeAs = normalized(entry.writeAs)
        var issues: [DictionaryIssue] = []
        if entry.writeAs.unicodeScalars.contains(where: isLineBreakOrControl) { issues.append(.multilineWriteAs) }
        if entry.writeAs.unicodeScalars.contains(where: { "<|>".unicodeScalars.contains($0) }) { issues.append(.markerInWriteAs) }
        if writeAs.isEmpty {
            issues.append(.emptyWriteAs)
        } else {
            if writeAs.count > maximumWriteAsLength { issues.append(.longWriteAs) }
            // Read after a space, as in a transcript: a leading combining mark joins the character before it.
            if !(" " + writeAs).contains(where: { $0.isLetter || $0.isNumber }) { issues.append(.wordlessWriteAs) }
            // Both limits come from one phrase: the longest in characters, then in words.
            if let longest = phrases.max(by: { ($0.phrase.count, $0.path.count) < ($1.phrase.count, $1.path.count) }) {
                let words = writeAs.unicodeScalars.split(whereSeparator: { $0.properties.generalCategory == .spaceSeparator }).count
                if words > longest.path.count + 2 || writeAs.count > max(40, 3 * longest.phrase.count) { issues.append(.distantWriteAs) }
            }
        }
        if given == 0 { issues.append(.noPhrase) }
        if given > maximumPhrases { issues.append(.tooManyPhrases) }
        return (issues + phraseIssues, writeAs, phrases)
    }

    /// One phrase's own problems, and its matching path when it has none. A blank phrase is ignored.
    static func review(_ raw: String, at index: Int) -> (issues: [DictionaryIssue], phrase: String, path: Path?) {
        if raw.unicodeScalars.contains(where: isLineBreakOrControl) { return ([.phraseCharacters(index)], raw, nil) }
        let phrase = normalized(raw)
        guard let first = phrase.first, let last = phrase.last else { return ([], "", nil) }
        let spans = DictionaryTokenizer.spans(phrase)
        let words = spans.filter(\.isWord)
        var issues: [DictionaryIssue] = []
        if phrase.count > maximumPhraseLength || words.count > maximumPhraseWords { issues.append(.longPhrase(index)) }
        // "ʼ" counts as a letter to Unicode and as a word scalar to the tokenizer, but a phrase uses it as an apostrophe.
        let modifierApostrophe: Unicode.Scalar = "\u{2BC}"
        let isEdge = { (character: Character) in
            (character.isLetter || character.isNumber) && character.unicodeScalars.first != modifierApostrophe
        }
        let edges = isEdge(first) && isEdge(last)
        if !edges { issues.append(.phraseEdges(index)) }
        let misplaced = spans.indices.contains { position in
            guard !spans[position].isWord else { return false }
            if position == 0 || position == spans.count - 1 { return edges }
            let separator = phrase.unicodeScalars[spans[position].range]
            return !((separator.count == 1 && spans[position].kind == .space) || spans[position].kind == .hyphen)
        }
        let scalars = Array(phrase.unicodeScalars)
        let isWordCharacter = { (scalar: Unicode.Scalar) in DictionaryTokenizer.isWordScalar(scalar) && !DictionaryTokenizer.isApostrophe(scalar) }
        let looseApostrophe = scalars.indices.dropFirst().dropLast().contains { position in
            scalars[position] == modifierApostrophe && !(isWordCharacter(scalars[position - 1]) && isWordCharacter(scalars[position + 1]))
        }
        // ":" and "," join digits in text, but a phrase is letters, numbers, spaces, hyphens, apostrophes and periods.
        let digitJoiner = phrase.unicodeScalars.contains(where: DictionaryTokenizer.isDigitJoiner)
        if misplaced || looseApostrophe || digitJoiner { issues.append(.phraseCharacters(index)) }
        guard issues.isEmpty else { return (issues, phrase, nil) }
        let path = spans.indices.filter { spans[$0].isWord }.map { position in
            Step(kind: position == 0 ? .start : spans[position - 1].kind, word: DictionaryTokenizer.key(phrase[spans[position].range]))
        }
        return ([], phrase, path)
    }

    /// Bidirectional controls count as control characters: in "Change to" they would reorder the text after it.
    private static func isLineBreakOrControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return scalar.properties.isBidiControl
        }
    }
}

enum SeparatorKind: UInt8, Hashable, Sendable { case start, space, hyphen, other }

struct DictionarySpan: Sendable {
    let range: Range<String.Index>
    let isWord: Bool
    /// For separators: how a phrase may cross it.
    let kind: SeparatorKind
    /// For words ending in an apostrophe and "s": where the stem ends.
    let stemEnd: String.Index?
}

/// Splits text into alternating word and separator spans in one pass over its scalars.
enum DictionaryTokenizer {
    static func spans(_ text: String) -> [DictionarySpan] {
        let scalars = text.unicodeScalars
        var spans: [DictionarySpan] = []
        var start = scalars.startIndex
        var index = start
        var inWord = false
        while index < scalars.endIndex {
            let next = scalars.index(after: index)
            let word = isWordScalar(scalars[index])
                || (inWord && isJoiner(scalars[index]) && next < scalars.endIndex && isWordScalar(scalars[next]))
                || (inWord && isDigitJoiner(scalars[index]) && next < scalars.endIndex && isDigit(scalars[next]) && isDigit(scalars[scalars.index(before: index)]))
            if word != inWord, index > start {
                spans.append(span(scalars, start..<index, isWord: inWord))
                start = index
            }
            inWord = word
            index = next
        }
        if start < scalars.endIndex { spans.append(span(scalars, start..<scalars.endIndex, isWord: inWord)) }
        return spans
    }

    private static func span(_ scalars: String.UnicodeScalarView, _ range: Range<String.Index>, isWord: Bool) -> DictionarySpan {
        if isWord {
            let last = scalars.index(before: range.upperBound)
            var stemEnd: String.Index?
            if last > range.lowerBound, scalars[last] == "s" || scalars[last] == "S" {
                let apostrophe = scalars.index(before: last)
                if apostrophe > range.lowerBound, isApostrophe(scalars[apostrophe]) { stemEnd = apostrophe }
            }
            return DictionarySpan(range: range, isWord: true, kind: .other, stemEnd: stemEnd)
        }
        let first = scalars[range.lowerBound]
        let kind: SeparatorKind
        if scalars[range].allSatisfy({ $0 == "\t" || $0.properties.generalCategory == .spaceSeparator }) {
            kind = .space
        } else if scalars.index(after: range.lowerBound) == range.upperBound, first == "-" || first == "\u{2010}" {
            kind = .hyphen
        } else {
            kind = .other
        }
        return DictionarySpan(range: range, isWord: false, kind: kind, stemEnd: nil)
    }

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return (scalar.value | 0x20) &- 0x61 < 26 || scalar.value &- 0x30 < 10 }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// "‘" is a misused apostrophe often enough ("don‘t") that reading it as one makes a miss, never a wrong change.
    static func isApostrophe(_ scalar: Unicode.Scalar) -> Bool { scalar == "'" || scalar == "\u{2019}" || scalar == "\u{2BC}" || scalar == "\u{2018}" }
    static func isJoiner(_ scalar: Unicode.Scalar) -> Bool { scalar == "." || isApostrophe(scalar) }
    /// Times and grouped numbers ("10:42", "1,000") stay one word, so no part of them is ever replaced.
    static func isDigitJoiner(_ scalar: Unicode.Scalar) -> Bool { scalar == ":" || scalar == "," }
    static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .decimalNumber }

    /// Case-folded with no locale, diacritics kept, and every apostrophe read as "'".
    static func key(_ word: Substring) -> String {
        if word.utf8.allSatisfy({ $0 < 0x80 }) {
            return String(decoding: word.utf8.map { $0 &- 0x41 < 26 ? $0 | 0x20 : $0 }, as: UTF8.self)
        }
        let folded = word.folding(options: [.caseInsensitive], locale: nil)
        guard folded.unicodeScalars.contains(where: { $0 != "'" && isApostrophe($0) }) else { return folded }
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars { scalars.append(isApostrophe(scalar) ? "'" : scalar) }
        return String(scalars)
    }
}

/// Whole-word replacement over a compiled trie: leftmost match first, then the one with the most
/// words; single pass; each replacement written exactly as typed. Cost does not depend on entry count.
public struct DictionaryMatcher: Sendable {
    struct EdgeKey: Hashable, Sendable { let kind: SeparatorKind; let word: Int }
    struct Node: Sendable { var children: [EdgeKey: Int] = [:]; var entry: Int? }

    private var nodes = [Node()]
    private var words: [String: Int] = [:]
    private var outputs: [String] = []

    public static let empty = DictionaryMatcher()
    private init() {}

    public var isEmpty: Bool { nodes[0].children.isEmpty }

    /// Only enabled entries without load issues are compiled; an off dictionary compiles nothing.
    public init(_ dictionary: PersonalDictionary) {
        guard dictionary.enabled else { return }
        for usable in DictionaryPolicy.audit(dictionary).usable {
            for path in usable.paths { insert(path, entry: outputs.count) }
            outputs.append(usable.writeAs)
        }
    }

    private mutating func insert(_ path: DictionaryPolicy.Path, entry: Int) {
        var node = 0
        for step in path {
            let word: Int
            if let known = words[step.word] { word = known } else { word = words.count; words[step.word] = word }
            let key = EdgeKey(kind: step.kind, word: word)
            if let child = nodes[node].children[key] { node = child; continue }
            nodes.append(Node())
            nodes[node].children[key] = nodes.count - 1
            node = nodes.count - 1
        }
        if nodes[node].entry == nil { nodes[node].entry = entry }
    }

    /// `startsInsideWord` means the text begins partway through a word, so the first word span never starts a match.
    public func apply(to text: String, startsInsideWord: Bool = false) -> DictionaryResult {
        guard !isEmpty, !text.isEmpty else { return DictionaryResult(unchanged: text) }
        var source = text
        source.makeContiguousUTF8()
        let spans = DictionaryTokenizer.spans(source)
        var wordIDs = [Int](repeating: -2, count: spans.count)
        var stemIDs = [Int](repeating: -2, count: spans.count)
        func wordID(_ position: Int) -> Int {
            if wordIDs[position] == -2 { wordIDs[position] = words[DictionaryTokenizer.key(source[spans[position].range])] ?? -1 }
            return wordIDs[position]
        }
        func stemID(_ position: Int) -> Int {
            guard let end = spans[position].stemEnd else { return -1 }
            if stemIDs[position] == -2 { stemIDs[position] = words[DictionaryTokenizer.key(source[spans[position].range.lowerBound..<end])] ?? -1 }
            return stemIDs[position]
        }

        var output = ""
        var changes: [DictionaryChange] = []
        var copied = source.startIndex
        var position = 0
        if startsInsideWord, let first = spans.firstIndex(where: \.isWord) { position = first + 1 }
        while position < spans.count {
            guard spans[position].isWord else { position += 1; continue }
            var best: (entry: Int, last: Int, stem: Bool)?
            var node = 0, kind = SeparatorKind.start, current = position
            while true {
                let stem = stemID(current)
                if stem >= 0, let child = nodes[node].children[EdgeKey(kind: kind, word: stem)], let entry = nodes[child].entry {
                    best = (entry, current, true)
                }
                let word = wordID(current)
                guard word >= 0, let child = nodes[node].children[EdgeKey(kind: kind, word: word)] else { break }
                node = child
                if let entry = nodes[node].entry { best = (entry, current, false) }
                guard current + 2 < spans.count, spans[current + 1].kind != .other else { break }
                kind = spans[current + 1].kind
                current += 2
            }
            guard let match = best else { position += 1; continue }
            let start = spans[position].range.lowerBound
            let end = match.stem ? spans[match.last].stemEnd! : spans[match.last].range.upperBound
            let written = outputs[match.entry]
            if source[start..<end] != written, Self.replacesWholeCharacters(in: source, start..<end, with: written) {
                if output.isEmpty { output.reserveCapacity(source.utf8.count + 64) }
                output += source[copied..<start]
                let lower = output.utf8.count
                output += written
                changes.append(DictionaryChange(transcribed: String(source[start..<end]), written: written, outputUTF8Range: lower..<output.utf8.count))
                copied = end
            }
            position = match.last + 1
        }
        guard !changes.isEmpty else { return DictionaryResult(unchanged: text) }
        output += source[copied...]
        return DictionaryResult(original: text, text: output, changes: changes)
    }

    /// A replacement swaps whole characters for whole characters: the match starts and ends on character
    /// boundaries, and "Change to" joins neither the character before it nor the one after it (the ends of
    /// the text count as spaces). Otherwise it is a miss, so no character around the match changes and
    /// "Change to" keeps its own letters.
    private static func replacesWholeCharacters(in source: String, _ range: Range<String.Index>, with written: String) -> Bool {
        guard String.Index(range.lowerBound, within: source) != nil, String.Index(range.upperBound, within: source) != nil else { return false }
        let before = range.lowerBound > source.startIndex ? String(source[source.index(before: range.lowerBound)..<range.lowerBound]) : " "
        let after = range.upperBound < source.endIndex ? String(source[range.upperBound..<source.index(after: range.upperBound)]) : " "
        return (before + written + after).count == before.count + written.count + after.count
    }
}
