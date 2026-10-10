import XCTest
@testable import WithinCore

final class PersonalDictionaryTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ writeAs: String, _ heardAs: String..., order: TimeInterval = 0, enabled: Bool = true) -> DictionaryEntry {
        DictionaryEntry(heardAs: heardAs, writeAs: writeAs, enabled: enabled, created: day.addingTimeInterval(order))
    }

    private func matcher(_ entries: DictionaryEntry..., enabled: Bool = true) -> DictionaryMatcher {
        DictionaryMatcher(PersonalDictionary(enabled: enabled, entries: entries))
    }

    private func assertUnchanged(_ inputs: [String], by matcher: DictionaryMatcher, file: StaticString = #filePath, line: UInt = #line) {
        for input in inputs {
            let result = matcher.apply(to: input)
            XCTAssertEqual(result.text, input, file: file, line: line)
            XCTAssertEqual(result.original, input, file: file, line: line)
            XCTAssertTrue(result.changes.isEmpty, file: file, line: line)
        }
    }

    private func issues(_ entry: DictionaryEntry, in dictionary: PersonalDictionary = PersonalDictionary()) -> [DictionaryIssue] {
        DictionaryPolicy.editorIssues(for: entry, in: dictionary)
    }

    // MARK: Matching

    func testReplacesWholeWordInAnyCapitalization() {
        let gira = matcher(entry("Jira", "gira"))
        XCTAssertEqual(gira.apply(to: "I filed it in gira.").text, "I filed it in Jira.")
        XCTAssertEqual(gira.apply(to: "GIRA").text, "Jira")
        XCTAssertEqual(gira.apply(to: "Gira").text, "Jira")
    }

    func testNeverMatchesInsideAWord() {
        assertUnchanged(["giraffe", "agira", "giras"], by: matcher(entry("Jira", "gira")))
    }

    func testReplacementIsWrittenExactlyAsTyped() {
        XCTAssertEqual(matcher(entry("iPhone", "iphone")).apply(to: "Iphone is here.").text, "iPhone is here.")
    }

    func testPunctuationNextToAMatchIsKept() {
        XCTAssertEqual(matcher(entry("Jira", "gira")).apply(to: "(gira), “gira”! gira's board.").text, "(Jira), “Jira”! Jira's board.")
    }

    func testContractionsAreNeverSplit() {
        let don = matcher(entry("Dawn", "don"))
        assertUnchanged(["don't", "don’t"], by: don)
        XCTAssertEqual(don.apply(to: "don.").text, "Dawn.")
    }

    func testApostropheInsideANameBlocksAMatch() {
        assertUnchanged(["O'Neil", "O’Neil"], by: matcher(entry("Neal", "neil")))
    }

    func testBothApostrophesAreTheSamePhrase() {
        XCTAssertEqual(matcher(entry("O’Neil", "o’neil")).apply(to: "ask o'neil").text, "ask O’Neil")
        let straight = matcher(entry("O'Neil", "o'neil"))
        XCTAssertEqual(straight.apply(to: "ask o’neil").text, "ask O'Neil")
        XCTAssertEqual(straight.apply(to: "o’neil’s desk").text, "O'Neil’s desk")
    }

    func testPeriodJoinedWordsAreNeverSplit() {
        let node = matcher(entry("Node", "node"))
        assertUnchanged(["node.js"], by: node)
        XCTAssertEqual(node.apply(to: "the node.").text, "the Node.")
    }

    func testHyphenIsAWordBoundary() {
        XCTAssertEqual(matcher(entry("Jira", "gira")).apply(to: "gira-based").text, "Jira-based")
        let email = matcher(entry("email", "e-mail"))
        XCTAssertEqual(email.apply(to: "an e-mail").text, "an email")
        XCTAssertEqual(email.apply(to: "E\u{2010}Mail").text, "email")
        assertUnchanged(["e mail", "e - mail", "e--mail"], by: email)
    }

    func testMultiwordPhraseAcceptsAnyHorizontalWhitespace() {
        let kubectl = matcher(entry("kubectl", "cube cuddle"))
        for input in ["cube cuddle", "cube  cuddle", "cube\tcuddle", "cube\u{00A0}cuddle"] {
            XCTAssertEqual(kubectl.apply(to: input).text, "kubectl")
        }
    }

    func testPhraseNeverSpansLineBreaksOrPunctuation() {
        assertUnchanged(["cube\ncuddle", "cube, cuddle", "cube.\ncuddle"], by: matcher(entry("kubectl", "cube cuddle")))
    }

    func testLongestMatchWins() {
        let york = matcher(entry("New York", "new york", order: 1), entry("NYC", "new york city", order: 2))
        XCTAssertEqual(york.apply(to: "new york city hall").text, "NYC hall")
        XCTAssertEqual(york.apply(to: "new york state").text, "New York state")
    }

    func testLeftmostMatchWinsOverALaterOverlap() {
        let apple = matcher(entry("Big Apple", "big apple", order: 1), entry("Apple Pie", "apple pie", order: 2))
        XCTAssertEqual(apple.apply(to: "big apple pie").text, "Big Apple pie")
    }

    func testSinglePassNeverChains() {
        XCTAssertEqual(matcher(entry("beta", "alpha", order: 1), entry("gamma", "beta", order: 2)).apply(to: "alpha beta").text, "beta gamma")
    }

    func testPossessiveStemIsKeptWhenALongerPhraseDeadEnds() {
        let gira = matcher(entry("Jira", "gira", order: 1), entry("Jira board", "gira's board", order: 2))
        XCTAssertEqual(gira.apply(to: "gira's issue").text, "Jira's issue")
        XCTAssertEqual(gira.apply(to: "gira's board").text, "Jira board")
        XCTAssertEqual(gira.apply(to: "GIRA’S issue").text, "Jira’S issue")
        let mcdonald = matcher(entry("McDonald", "mcdonald", order: 1), entry("McDonald's app", "mcdonald's app", order: 2))
        XCTAssertEqual(mcdonald.apply(to: "mcdonald's coffee").text, "McDonald's coffee")
        XCTAssertEqual(mcdonald.apply(to: "the mcdonald's app").text, "the McDonald's app")
    }

    func testPossessiveStemOnlyEndsAPhrase() {
        assertUnchanged(["gira's board"], by: matcher(entry("Jira board", "gira board")))
        let ab = matcher(entry("AB", "a b", order: 1), entry("ABC", "a b's c", order: 2))
        XCTAssertEqual(ab.apply(to: "a b's d").text, "AB's d")
        XCTAssertEqual(ab.apply(to: "a b's c").text, "ABC")
        let giras = matcher(entry("Jira", "gira", order: 1), entry("Giras", "gira's", order: 2))
        for input in ["gira's", "gira\u{2019}s", "GIRA'S"] { XCTAssertEqual(giras.apply(to: input).text, "Giras") }
        XCTAssertEqual(giras.apply(to: "gira's board").text, "Giras board")
        let york = matcher(entry("New York", "new york")).apply(to: "new york's mayor")
        XCTAssertEqual(york.text, "New York's mayor")
        XCTAssertEqual(york.changes, [DictionaryChange(transcribed: "new york", written: "New York", outputUTF8Range: 0..<8)])
    }

    func testApostrophesAroundAMatchAreCopiedAsTheyAppear() {
        let gira = matcher(entry("Jira", "gira"))
        for (input, output) in [("gira's'", "Jira's'"), ("gira'S", "Jira'S"), ("'gira", "'Jira"), ("gira'", "Jira'"),
                                ("\u{2019}gira", "\u{2019}Jira"), ("gira''s", "Jira''s"), ("gira\u{2BC}s board", "Jira\u{2BC}s board")] {
            let result = gira.apply(to: input)
            XCTAssertEqual(result.text, output)
            XCTAssertEqual(result.changes.map(\.transcribed), ["gira"])
        }
        assertUnchanged(["gira'sx", "gira's's", "gira's\u{301}"], by: gira)
    }

    func testSeparatorKindMustMatchThePhrase() {
        let kubectl = matcher(entry("kubectl", "cube cuddle"))
        assertUnchanged(["cube-cuddle", "cube\u{2028}cuddle", "cube\u{2029}cuddle", "cube\r\ncuddle", "cube\u{200B}cuddle"], by: kubectl)
        for input in ["cube\u{3000}cuddle", "cube\u{202F}cuddle"] { XCTAssertEqual(kubectl.apply(to: input).text, "kubectl") }
        let hyphen = matcher(entry("email", "e-mail"))
        assertUnchanged(["e\u{00A0}mail", "e\u{2011}mail", "e\u{2013}mail"], by: hyphen)
        XCTAssertEqual(hyphen.apply(to: "e-mail's").text, "email's")
        XCTAssertEqual(hyphen.apply(to: "E-MAIL\u{2019}S inbox").text, "email\u{2019}S inbox")
        let space = matcher(entry("email", "e mail"))
        assertUnchanged(["e-mail", "e\u{2010}mail"], by: space)
        XCTAssertEqual(space.apply(to: "E\u{00A0}MAIL").text, "email")
        let gira = matcher(entry("Jira", "gira"))
        XCTAssertEqual(gira.apply(to: "gira\u{2011}based").text, "Jira\u{2011}based")
        XCTAssertEqual(gira.apply(to: "gira\u{2013}gira").text, "Jira\u{2013}Jira")
        XCTAssertEqual(gira.apply(to: "gira/gira").text, "Jira/Jira")
    }

    func testPeriodsJoinOnlyBetweenWordCharacters() {
        let versions = matcher(entry("Node", "node", order: 1), entry("V2.1", "v2.1", order: 2))
        XCTAssertEqual(versions.apply(to: "v2.1.").text, "V2.1.")
        XCTAssertEqual(versions.apply(to: "node...").text, "Node...")
        XCTAssertEqual(versions.apply(to: "...node").text, "...Node")
        XCTAssertEqual(versions.apply(to: "node.\nnode").text, "Node.\nNode")
        assertUnchanged(["v2.1.3"], by: versions)
        let gira = matcher(entry("Jira", "gira"))
        XCTAssertEqual(gira.apply(to: "gira..js").text, "Jira..js")
        assertUnchanged(["v2.gira", "gira.\u{301}x"], by: gira)
    }

    /// A prepended format character joins the character after it, and a leading combining mark joins the
    /// one before it, so a replacement there would change a character outside the match: it is a miss.
    func testReplacementNeverJoinsTheCharactersAroundIt() {
        let dictionary = PersonalDictionary(entries: [entry("C#", "see sharp", order: 1), entry("Q", "xy", order: 2), entry("3", "three", order: 3),
                                                      entry("X", "ex", order: 4), entry("J", "gira", order: 5), entry("\u{301}Jira", "jeera", order: 6)])
        XCTAssertEqual(DictionaryPolicy.loadIssues(dictionary), [:])
        let short = DictionaryMatcher(dictionary)
        XCTAssertEqual(short.apply(to: "see sharp, xy").text, "C#, Q")
        let inputs = ["\u{600}see sharp", "\u{600}xy", "\u{6DD}three", "\u{70F}ex", "(\u{600}xy)", "\u{600}gira", "a \u{600}xy",
                      "xy\u{200D}", "(jeera)", "jeera", "a jeera b"]
        for input in inputs { XCTAssertEqual(TranscriptFormatting.clean(input), input) }
        assertUnchanged(inputs, by: short)
        XCTAssertEqual(short.apply(to: "\u{600} xy").text, "\u{600} Q")
        XCTAssertEqual(short.apply(to: "\u{FEFF}xy").text, "\u{FEFF}Q")
    }

    func testCanonicallyEqualMatchKeepsTheSourceBytes() {
        for (writeAs, phrase, input) in [("Caf\u{E9}", "caf\u{E9}", "Cafe\u{301} x"), ("Key", "key", "\u{212A}ey")] {
            let result = matcher(entry(writeAs, phrase)).apply(to: input)
            XCTAssertEqual(Array(result.text.utf8), Array(input.utf8))
            XCTAssertTrue(result.changes.isEmpty)
        }
    }

    func testChangeRangesCountUTF8BytesAroundMultibyteText() {
        let unicode = matcher(entry("J\u{ED}ra", "gira", order: 1), entry("J\u{ED}ra b\u{F6}rd", "gira's board", order: 2),
                              entry("kubectl", "cube cuddle", order: 3), entry("\u{DC}n\u{EF}c\u{F8}d\u{E9}", "unicode", order: 5))
        let zoe = "Zo\u{EB}\u{2019}s \u{1F469}\u{200D}\u{1F4BB} "
        let expected = [(zoe + "gira's board", zoe + "J\u{ED}ra b\u{F6}rd"), (zoe + "gira's issue", zoe + "J\u{ED}ra's issue"),
                        ("\u{65E5}\u{672C} gira, \u{1F44D}\u{1F3FD} unicode\u{2019}s cube cuddle",
                         "\u{65E5}\u{672C} J\u{ED}ra, \u{1F44D}\u{1F3FD} \u{DC}n\u{EF}c\u{F8}d\u{E9}\u{2019}s kubectl"),
                        ("\u{FEFF}gira", "\u{FEFF}J\u{ED}ra")]
        for (input, output) in expected {
            let result = unicode.apply(to: input)
            XCTAssertEqual(Array(result.text.utf8), Array(output.utf8))
            let bytes = Array(result.text.utf8)
            for change in result.changes {
                XCTAssertEqual(String(decoding: bytes[change.outputUTF8Range], as: UTF8.self), change.written)
            }
        }
        XCTAssertEqual(unicode.apply(to: zoe + "gira's board").changes.map(\.outputUTF8Range), [21..<32])
    }

    func testLeadingFragmentIsNeverMatched() {
        let ary = matcher(entry("Ary", "ary"))
        XCTAssertEqual(ary.apply(to: "ary is quiet", startsInsideWord: true).text, "ary is quiet")
        XCTAssertEqual(ary.apply(to: "ary is quiet").text, "Ary is quiet")
        XCTAssertEqual(ary.apply(to: " ary is quiet", startsInsideWord: true).text, " ary is quiet")
        XCTAssertEqual(ary.apply(to: "ary ary", startsInsideWord: true).text, "ary Ary")
        let fragments = matcher(entry("Neal", "neil", order: 1), entry("JS", "js", order: 2), entry("Ess", "s", order: 3))
        for input in ["'neil is here", "\u{2019}neil is here", ".js is great", "'s board"] {
            let result = fragments.apply(to: input, startsInsideWord: true)
            XCTAssertEqual(result.text, input)
            XCTAssertTrue(result.changes.isEmpty)
        }
        let york = matcher(entry("Jira", "gira", order: 1), entry("NYC", "new york city", order: 2))
        XCTAssertEqual(york.apply(to: "new york city", startsInsideWord: true).text, "new york city")
        XCTAssertEqual(york.apply(to: "york city new york city", startsInsideWord: true).text, "york city NYC")
        XCTAssertEqual(york.apply(to: "\u{301}gira gira", startsInsideWord: true).text, "\u{301}gira Jira")
    }

    func testDisabledEntriesAndAnOffDictionaryChangeNothing() {
        let disabled = matcher(entry("Jira", "gira", enabled: false))
        let off = matcher(entry("Jira", "gira"), enabled: false)
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertTrue(off.isEmpty)
        assertUnchanged(["gira", "I filed it in gira."], by: disabled)
        assertUnchanged(["gira", "I filed it in gira."], by: off)
    }

    func testEmptyAndWhitespaceInputIsReturnedUnchanged() {
        assertUnchanged(["", "   ", "\n"], by: matcher(entry("Jira", "gira")))
    }

    func testEmptyMatcherReturnsInputUnchanged() {
        let inputs = ["gira", "  two  spaces  ", "<|nospeech|>", "cafe\u{301}", "line\nbreak"]
        assertUnchanged(inputs, by: .empty)
        assertUnchanged(inputs, by: DictionaryMatcher(PersonalDictionary()))
        XCTAssertTrue(DictionaryMatcher.empty.isEmpty)
    }

    func testResultKeepsOriginalAndListsChanges() {
        let jira = matcher(entry("Jira", "gira", "jira"))
        let result = jira.apply(to: "Zoë’s “gira” plan, in Jira.")
        XCTAssertEqual(result.original, "Zoë’s “gira” plan, in Jira.")
        XCTAssertEqual(result.text, "Zoë’s “Jira” plan, in Jira.")
        XCTAssertEqual(result.changes.map(\.transcribed), ["gira"])
        XCTAssertEqual(result.changes.map(\.written), ["Jira"])
        XCTAssertTrue(result.changed)
        let bytes = Array(result.text.utf8)
        for change in result.changes {
            XCTAssertEqual(String(decoding: bytes[change.outputUTF8Range], as: UTF8.self), change.written)
        }
        let same = jira.apply(to: "Jira")
        XCTAssertEqual(same.text, "Jira")
        XCTAssertFalse(same.changed)
    }

    func testAccentedLettersAreWordCharactersAndDiacriticsMatter() {
        let jose = matcher(entry("José", "jose"))
        assertUnchanged(["josefina", "joséfina"], by: jose)
        XCTAssertEqual(jose.apply(to: "jose's").text, "José's")
        assertUnchanged(["zoë"], by: matcher(entry("Zoey", "zoe")))
        assertUnchanged(["zoe"], by: matcher(entry("Zoë", "zoë")))
        XCTAssertEqual(matcher(entry("Café", "caf\u{E9}")).apply(to: "cafe\u{301} time").text, "Café time")
        XCTAssertEqual(matcher(entry("Café", "cafe\u{301}")).apply(to: "caf\u{E9} time").text, "Café time")
    }

    func testCaseFoldingCoversAccentedCapitals() {
        XCTAssertEqual(matcher(entry("École", "école")).apply(to: "ÉCOLE").text, "École")
    }

    /// Observed with Foundation on macOS: "ß" and "ẞ" fold to "ss", "İ" folds to "i" plus U+0307,
    /// and "ı" keeps its own letter, whatever the region, because no locale is passed.
    func testSharpSAndTurkishIFoldAsObserved() {
        XCTAssertEqual(matcher(entry("Strasse", "strasse")).apply(to: "straße STRAẞE").text, "Strasse Strasse")
        XCTAssertEqual(matcher(entry("Straße", "straße")).apply(to: "STRASSE").text, "Straße")
        let istanbul = matcher(entry("Istanbul", "istanbul"))
        XCTAssertEqual(istanbul.apply(to: "ISTANBUL").text, "Istanbul")
        assertUnchanged(["İstanbul", "ıstanbul"], by: istanbul)
    }

    func testASCIIKeysAndWordCharactersMatchUnicodeProperties() {
        for value in UInt8(0x20)...UInt8(0x7E) {
            let scalar = Unicode.Scalar(value)
            let text = String(scalar)
            XCTAssertEqual(DictionaryTokenizer.key(text[...]), text.folding(options: [.caseInsensitive], locale: nil))
            XCTAssertEqual(DictionaryTokenizer.isWordScalar(scalar), scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
        }
    }

    func testNumbersAreWordCharacters() {
        let b2b = matcher(entry("B2B", "b2b"))
        assertUnchanged(["b2bx"], by: b2b)
        XCTAssertEqual(b2b.apply(to: "b2b.").text, "B2B.")
    }

    private var stableEntries: [DictionaryEntry] {
        [entry("Jira", "gira", order: 1), entry("New York", "new york", order: 2), entry("NYC", "new york city", order: 3),
         entry("email", "e-mail", order: 4), entry("kubectl", "cube cuddle", order: 5), entry("Ex", "x", order: 6),
         entry("Tag", "tag", order: 7), entry("Why", "y", order: 8), entry("O'Neil", "o’neil", order: 9),
         entry("B2B", "b2b", order: 10), entry("José", "jose", order: 11)]
    }

    private func generatedInputs(seed: UInt64, count: Int) -> [String] {
        var random = SeededGenerator(seed: seed)
        let words = ["gira", "GIRA", "x", "tag", "y", "new", "york", "city", "e", "mail", "cube", "cuddle", "o’neil", "b2b", "jose", "word", "é"]
        let separators = [" ", "  ", "\t", "\n", "<", "|", ">", "<|", "|>", ", ", "-", "'s ", ".", "’s", " (", ") ", "“", "”"]
        return (0..<count).map { _ in
            (0..<Int.random(in: 1...8, using: &random)).map { _ in
                words.randomElement(using: &random)! + separators.randomElement(using: &random)!
            }.joined()
        }
    }

    func testOutputStaysStableUnderClean() {
        let dictionary = PersonalDictionary(entries: stableEntries)
        XCTAssertEqual(DictionaryPolicy.loadIssues(dictionary), [:])
        let stable = DictionaryMatcher(dictionary)
        XCTAssertEqual(stable.apply(to: "x|tag|>").text, "Ex|Tag|>")
        XCTAssertEqual(stable.apply(to: "<|x y").text, "<|Ex Why")
        XCTAssertEqual(stable.apply(to: "x|>").text, "Ex|>")
        let examples = ["x|tag|>", "<|x y", "x|>", "I filed it in gira.", "(gira), “gira”! gira's board.", "new york city hall",
                        "an e-mail", "cube cuddle", "cube\ncuddle", "o'neil’s desk", "b2b.", "jose's", "gira-based", "x <y> z"]
        var checked = 0
        for input in examples + generatedInputs(seed: 24, count: 2_000) where TranscriptFormatting.clean(input) == input {
            for startsInsideWord in [false, true] {
                let output = stable.apply(to: input, startsInsideWord: startsInsideWord).text
                XCTAssertEqual(TranscriptFormatting.clean(output), output, "input: \(input)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 500)
    }

    func testNonEmptySpeechNeverBecomesEmpty() {
        let stable = DictionaryMatcher(PersonalDictionary(entries: stableEntries + [entry("A", "word", order: 12)]))
        var checked = 0
        for input in generatedInputs(seed: 25, count: 2_000) {
            let clean = TranscriptFormatting.clean(input)
            guard !clean.isEmpty else { continue }
            XCTAssertFalse(TranscriptFormatting.clean(stable.apply(to: clean).text).isEmpty, "input: \(clean)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1_000)
    }

    func testInvariantsHoldAcrossScripts() {
        let dictionary = PersonalDictionary(entries: [
            entry("Jira", "gira", order: 1), entry("New York", "new york", order: 2), entry("NYC", "new york city", order: 3),
            entry("email", "e-mail", order: 4), entry("kubectl", "cube cuddle", order: 5), entry("Caf\u{E9}", "cafe", order: 6),
            entry("Ex", "x", order: 7), entry("O\u{2019}Neil", "o'neil", order: 8), entry("Stra\u{DF}e", "strasse", order: 9),
            entry("\u{DC}n\u{EF}", "uni", order: 10), entry("Giras", "gira's", order: 11), entry("Zo\u{EB}", "zoe", order: 12),
            entry("\u{1F469}\u{200D}\u{1F4BB} Dev", "dev", order: 13), entry("\u{130}zmir", "izmir", order: 14), entry("V2.1", "v2.1", order: 15),
            entry("C#", "see sharp", order: 16), entry("Q", "xy", order: 17), entry("Jira\u{200B}", "jeera", order: 18)])
        XCTAssertEqual(DictionaryPolicy.loadIssues(dictionary), [:])
        let broad = DictionaryMatcher(dictionary)
        let words = ["gira", "GIRA", "new", "york", "city", "e", "mail", "cube", "cuddle", "cafe", "caf\u{E9}", "cafe\u{301}", "x", "o'neil",
                     "strasse", "stra\u{DF}e", "uni", "zoe", "zo\u{EB}", "dev", "izmir", "\u{130}ZM\u{130}R", "v2.1", "\u{212A}ey", "\u{FB01}le",
                     "\u{1C5}", "\u{65E5}\u{672C}", "\u{301}", "see", "sharp", "xy", "jeera"]
        let separators = [" ", "  ", "\t", "\u{A0}", "\u{202F}", "\u{3000}", "\r\n", "\u{2028}", "\u{2029}", "\u{85}", "\u{200D}", "\u{200B}",
                          "\u{2010}", "\u{2011}", "\u{2013}", "-", " \u{1F469}\u{200D}\u{1F4BB} ", "\u{1F44D}\u{1F3FD}", " \u{1F44D}\u{200D}", "<", "|", ">", "<|", "|>",
                          "\u{201C}", "\u{201D}", "'", "\u{2019}", "\u{2BC}", "'s ", "\u{2019}s ", "\u{2BC}s ", "...", "\u{FE0F}", "\u{AD}",
                          "\u{600}", "\u{6DD}", "\u{70F}", ", ", "(", ")", "\u{1F1FA}\u{1F1F8}", "\u{1F1FA}"]
        var random = SeededGenerator(seed: 28)
        var checked = 0
        for _ in 0..<3_000 {
            let input = (0..<Int.random(in: 1...7, using: &random)).map { _ in
                words.randomElement(using: &random)! + separators.randomElement(using: &random)!
            }.joined()
            for startsInsideWord in [false, true] {
                let result = broad.apply(to: input, startsInsideWord: startsInsideWord)
                XCTAssertEqual(result.changed, result.text != result.original, "input: \(input)")
                if !result.changed { XCTAssertEqual(Array(result.text.utf8), Array(input.utf8), "input: \(input)") }
                let utf8 = result.text.utf8
                for change in result.changes {
                    XCTAssertEqual(String(decoding: Array(utf8)[change.outputUTF8Range], as: UTF8.self), change.written, "input: \(input)")
                    // Each replacement starts and ends on a character boundary, so no character around it changed.
                    for offset in [change.outputUTF8Range.lowerBound, change.outputUTF8Range.upperBound] {
                        XCTAssertNotNil(String.Index(utf8.index(utf8.startIndex, offsetBy: offset), within: result.text), "input: \(input)")
                    }
                }
                guard TranscriptFormatting.clean(input) == input else { continue }
                XCTAssertEqual(TranscriptFormatting.clean(result.text), result.text, "input: \(input)")
                XCTAssertFalse(result.text.isEmpty)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1_000)
    }

    func testEarliestEnabledEntryWinsADuplicatePhrase() {
        let later = entry("Gyra", "gira", order: 2)
        let earlier = entry("Jira", "GIRA", order: 1)
        let dictionary = PersonalDictionary(entries: [later, earlier])
        XCTAssertEqual(DictionaryMatcher(dictionary).apply(to: "gira").text, "Jira")
        XCTAssertEqual(DictionaryPolicy.loadIssues(dictionary), [later.id: [.duplicatePhrase(0, phrase: "gira", earlierWriteAs: "Jira")]])
        let first = DictionaryEntry(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, heardAs: ["gira"], writeAs: "Jira", created: day)
        let second = DictionaryEntry(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, heardAs: ["gira"], writeAs: "Gyra", created: day)
        XCTAssertEqual(DictionaryMatcher(PersonalDictionary(entries: [second, first])).apply(to: "gira").text, "Jira")
        let jira = entry("Jira", "gira", order: 1)
        let node = entry("Node", "node", "GIRA", order: 2)
        let both = PersonalDictionary(entries: [node, jira])
        XCTAssertEqual(DictionaryPolicy.loadIssues(both), [node.id: [.duplicatePhrase(1, phrase: "GIRA", earlierWriteAs: "Jira")]])
        XCTAssertEqual(DictionaryMatcher(both).apply(to: "gira node").text, "Jira node")
    }

    func testDisabledDuplicateNeverBlocksAnEnabledEntry() {
        let dictionary = PersonalDictionary(entries: [entry("Gyra", "gira", order: 1, enabled: false), entry("Jira", "gira", order: 2)])
        XCTAssertEqual(DictionaryPolicy.loadIssues(dictionary), [:])
        XCTAssertEqual(DictionaryMatcher(dictionary).apply(to: "gira").text, "Jira")
    }

    func testEntriesWithIssuesAreSkipped() {
        let marker = entry("Jira<", "gira", order: 1)
        let edges = entry("Node", "node!", order: 2)
        let valid = entry("B2B", "b2b", order: 3)
        let laterGira = entry("Jira", "gira", order: 4)
        let dictionary = PersonalDictionary(entries: [marker, edges, valid, laterGira])
        XCTAssertEqual(DictionaryPolicy.loadIssues(dictionary), [marker.id: [.markerInWriteAs], edges.id: [.phraseEdges(0)]])
        XCTAssertEqual(DictionaryMatcher(dictionary).apply(to: "gira node b2b").text, "Jira node B2B")
    }

    func testRepeatedEntryIDsGetNewIDsInMemory() throws {
        let id = UUID()
        let first = DictionaryEntry(id: id, heardAs: ["gira"], writeAs: "Jira", created: day)
        var second = DictionaryEntry(id: id, heardAs: ["node"], writeAs: "Node", enabled: false, created: day.addingTimeInterval(5))
        second.modified = day.addingTimeInterval(9)
        let third = DictionaryEntry(id: id, heardAs: ["b2b"], writeAs: "B2B", created: day.addingTimeInterval(7))
        let original = PersonalDictionary(entries: [first, second, third])
        let fixed = DictionaryPolicy.uniquingIDs(original)
        XCTAssertEqual(fixed.entries[0], first)
        XCTAssertEqual(Set(fixed.entries.map(\.id)).count, 3)
        for (kept, given) in zip(fixed.entries, original.entries) {
            XCTAssertEqual(kept.heardAs, given.heardAs)
            XCTAssertEqual(kept.writeAs, given.writeAs)
            XCTAssertEqual(kept.enabled, given.enabled)
            XCTAssertEqual(kept.created, given.created)
            XCTAssertEqual(kept.modified, given.modified)
        }
        guard case .loaded(let decoded) = PersonalDictionary.decode(try JSONEncoder().encode(original)) else { return XCTFail("not loaded") }
        XCTAssertEqual(decoded.entries.first?.id, id)
        XCTAssertEqual(Set(decoded.entries.map(\.id)).count, 3)
    }

    func testRepeatedIDsLeaveTheFirstInFileOrderWinning() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000FF"))
        let jira = DictionaryEntry(id: id, heardAs: ["gira"], writeAs: "Jira", created: day)
        let gyra = DictionaryEntry(id: id, heardAs: ["gira"], writeAs: "Gyra", created: day)
        for (entries, winner) in [([jira, gyra], "Jira"), ([gyra, jira], "Gyra")] {
            let fixed = DictionaryPolicy.uniquingIDs(PersonalDictionary(entries: entries))
            XCTAssertEqual(fixed, DictionaryPolicy.uniquingIDs(PersonalDictionary(entries: entries)))
            XCTAssertEqual(fixed.entries.map(\.id.uuidString), ["00000000-0000-0000-0000-0000000000FF", "00000000-0000-0000-0000-000000000100"])
            XCTAssertEqual(DictionaryMatcher(fixed).apply(to: "gira").text, winner)
        }
        let next = DictionaryEntry(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000100")), heardAs: ["node"], writeAs: "Node", created: day)
        XCTAssertEqual(DictionaryPolicy.uniquingIDs(PersonalDictionary(entries: [jira, gyra, next])).entries[1].id.uuidString,
                       "00000000-0000-0000-0000-000000000101")
    }

    func testEntriesOverTheLimitAreNotUsed() {
        var entries = (0..<501).map { entry("W\($0)", "w\($0)", order: TimeInterval($0)) }
        let last = entries.removeLast()
        let dictionary = PersonalDictionary(entries: [last] + entries)
        XCTAssertEqual(DictionaryPolicy.loadIssues(dictionary), [last.id: [.overLimit]])
        XCTAssertEqual(DictionaryMatcher(dictionary).apply(to: "w0 w499 w500").text, "W0 W499 w500")
        var quiet = (0..<500).map { entry("W\($0)", "w\($0)", order: TimeInterval($0), enabled: false) }
        let gira = entry("Jira", "gira", order: 600)
        quiet.append(gira)
        XCTAssertEqual(DictionaryPolicy.loadIssues(PersonalDictionary(entries: quiet)), [gira.id: [.overLimit]])
        XCTAssertTrue(DictionaryMatcher(PersonalDictionary(entries: quiet)).isEmpty)
    }

    /// Source and expected text are built together from known tokens, without the matcher or its tokenizer.
    private func largeCase() -> (matcher: DictionaryMatcher, source: String, expected: String, changes: Int) {
        let entries = (0..<500).map { index in
            DictionaryEntry(heardAs: (0..<10).map { $0.isMultiple(of: 2) ? "q\(index)k\($0)" : "q\(index)k\($0) zed" },
                            writeAs: "W\(index)", created: day.addingTimeInterval(TimeInterval(index)))
        }
        var random = SeededGenerator(seed: 31)
        let fillers = ["lorem", "ipsum", "dolor", "amet", "nunc", "Vitae"]
        let separators = [" ", " ", " ", ", ", ". ", "\n", " (", ") ", "; ", "-", "\n\n", " “", "” "]
        let gaps = [" ", "  ", "\t", "\u{00A0}"]
        let suffixes = ["'s", "’s", "'S"]
        func variant(_ word: String) -> String {
            switch Int.random(in: 0..<3, using: &random) {
            case 0: return word
            case 1: return word.uppercased()
            default: return word.prefix(1).uppercased() + word.dropFirst()
            }
        }
        func phrase(_ index: Int, _ k: Int) -> String {
            k.isMultiple(of: 2) ? variant("q\(index)k\(k)") : variant("q\(index)k\(k)") + gaps.randomElement(using: &random)! + variant("zed")
        }
        var source = "", expected = "", changes = 0
        while source.utf8.count < 200_000 {
            if !source.isEmpty {
                let separator = separators.randomElement(using: &random)!
                source += separator; expected += separator
            }
            let index = Int.random(in: 0..<500, using: &random), k = Int.random(in: 0..<10, using: &random)
            switch Int.random(in: 0..<20, using: &random) {
            case 0..<8:
                let filler = fillers.randomElement(using: &random)!
                source += filler; expected += filler
            case 8..<16:
                source += phrase(index, k); expected += "W\(index)"; changes += 1
            case 16..<18:
                let suffix = suffixes.randomElement(using: &random)!
                source += phrase(index, k) + suffix; expected += "W\(index)" + suffix; changes += 1
            case 18:
                let miss = "q\(index)k\(k / 2 * 2)x"
                source += miss; expected += miss
            default:
                let bare = "q\(index)k\(k / 2 * 2 + 1)"
                source += bare; expected += bare
            }
        }
        return (DictionaryMatcher(PersonalDictionary(entries: entries)), source, expected, changes)
    }

    func testLargeInputIsHandledInOnePass() {
        let large = largeCase()
        XCTAssertGreaterThanOrEqual(large.source.utf8.count, 200_000)
        XCTAssertGreaterThan(large.changes, 5_000)
        let result = large.matcher.apply(to: large.source)
        XCTAssertEqual(result.text, large.expected)
        XCTAssertEqual(result.changes.count, large.changes)
        XCTAssertEqual(result.original, large.source)
    }

    func testLargeInputTimeIsRecorded() {
        let large = largeCase()
        measure { _ = large.matcher.apply(to: large.source) }
    }

    // MARK: Validation and normalization

    func testProhibitedCharactersAreRejectedBeforeSpacesAreCollapsed() {
        XCTAssertEqual(issues(entry("Ji\tra", "gira")), [.multilineWriteAs])
        XCTAssertEqual(issues(entry("Jira\n", "gira")), [.multilineWriteAs])
        XCTAssertEqual(issues(entry("Jira\u{2028}", "gira")), [.multilineWriteAs])
        XCTAssertEqual(issues(entry("Jira", "gira\t")), [.phraseCharacters(0)])
        XCTAssertEqual(issues(entry("Jira", "\ngira")), [.phraseCharacters(0)])
        XCTAssertEqual(issues(entry("kubectl", "cube\tcuddle")), [.phraseCharacters(0)])
    }

    func testNormalizationTrimsAndCollapsesSpaces() {
        XCTAssertEqual(DictionaryPolicy.normalized("  Ada   Example "), "Ada Example")
        XCTAssertEqual(DictionaryPolicy.normalized("Ada\u{00A0} Example\u{3000}"), "Ada Example")
        XCTAssertEqual(DictionaryPolicy.normalized("   "), "")
        XCTAssertEqual(issues(entry("  Ada   Example ", "ada example")), [])
        XCTAssertEqual(DictionaryPolicy.normalized("Mac \u{A0}OS"), "Mac OS")
        XCTAssertEqual(DictionaryPolicy.normalized("10\u{202F}km"), "10\u{202F}km")
        XCTAssertEqual(DictionaryPolicy.normalized("\u{200B} Jira \u{200B}"), "Jira")
        XCTAssertEqual(DictionaryPolicy.normalized("Ji\u{200B}ra"), "Ji\u{200B}ra")
        let narrow = matcher(entry("10\u{202F}km", "ten km")).apply(to: "run ten km now")
        XCTAssertEqual(narrow.text, "run 10\u{202F}km now")
        XCTAssertEqual(narrow.changes.map(\.written), ["10\u{202F}km"])
        XCTAssertEqual(issues(entry("New York", "new\u{A0}york")), [])
        XCTAssertEqual(matcher(entry("New York", "new\u{A0}york")).apply(to: "new york").text, "New York")
        for (writeAs, input, expected) in [("Jira\u{200B}", "a gira", "a Jira"), ("\u{200B}Jira", "gira b", "Jira b"), ("\u{200B}Jira\u{200B}", "gira", "Jira")] {
            let output = matcher(entry(writeAs, "gira")).apply(to: input).text
            XCTAssertEqual(output, expected)
            XCTAssertEqual(TranscriptFormatting.clean(output), output)
        }
    }

    func testChangeToIsJudgedAsItWillAppearInText() {
        for writeAs in ["\u{345}", "\u{E33}", "\u{93E}"] {
            XCTAssertEqual(issues(entry(writeAs, "x")), [.wordlessWriteAs], "writeAs: \(writeAs)")
            XCTAssertTrue(matcher(entry(writeAs, "x")).isEmpty)
        }
        for writeAs in ["Jira\u{202E}", "Ji\u{2066}ra", "\u{200F}Jira"] {
            XCTAssertEqual(issues(entry(writeAs, "gira")), [.multilineWriteAs], "writeAs: \(writeAs)")
        }
    }

    func testEveryChangeToProblemIsReported() {
        XCTAssertEqual(issues(entry("", "node")), [.emptyWriteAs])
        XCTAssertEqual(Set(issues(entry(String(repeating: ".", count: 101), "node"))), [.longWriteAs, .wordlessWriteAs, .distantWriteAs])
        XCTAssertEqual(Set(issues(entry(String(repeating: "-", count: 50), "node"))), [.wordlessWriteAs, .distantWriteAs])
        XCTAssertEqual(Set(issues(entry(String(repeating: "ab ", count: 40) + "x", "node"))), [.longWriteAs, .distantWriteAs])
        XCTAssertEqual(Set(issues(entry(String(repeating: "a", count: 101), "node"))), [.longWriteAs, .distantWriteAs])
        XCTAssertEqual(Set(issues(entry(String(repeating: "!", count: 50), "x"))), [.wordlessWriteAs, .distantWriteAs])
    }

    func testEveryIssueHasItsMessage() {
        let existing = entry("Jira", "gira", order: 1)
        let dictionary = PersonalDictionary(entries: [existing])
        func messages(_ entry: DictionaryEntry) -> [String] { issues(entry, in: dictionary).map(\.message) }
        XCTAssertEqual(messages(entry("", "node")), ["Enter how Within should write it."])
        XCTAssertEqual(messages(entry(String(repeating: "a", count: 101), String(repeating: "p", count: 34))), ["Keep it to 100 characters or fewer."])
        XCTAssertEqual(messages(entry("Please write this whole thing", "node")),
                       ["Keep this close to what Within writes. The dictionary fixes spellings; it doesn’t expand text."])
        XCTAssertEqual(messages(entry("No\nde", "node")), ["Use a single line of text."])
        XCTAssertEqual(messages(entry("...", "node")), ["Include at least one letter or number."])
        XCTAssertEqual(messages(entry("Node>", "node")), ["Remove the “<”, “|” and “>” characters."])
        XCTAssertEqual(messages(entry("Node")), ["Add at least one way Within writes it."])
        XCTAssertEqual(messages(DictionaryEntry(heardAs: (1...11).map { "n\($0)" }, writeAs: "Node", created: day)),
                       ["Use up to 10 ways Within writes it."])
        XCTAssertEqual(messages(entry("Node", "one two three four five six seven")), ["Keep each one to 64 characters and 6 words."])
        XCTAssertEqual(messages(entry("Node", "node.")), ["Start and end with a letter or number."])
        XCTAssertEqual(messages(entry("Node", "no,de")), ["Use letters, numbers, spaces, hyphens, apostrophes and periods."])
        XCTAssertEqual(messages(entry("Node", "node", "NODE")), ["You’ve already added “NODE”."])
        XCTAssertEqual(messages(entry("Jira", "Gira")), ["“Gira” is already used for “Jira”."])
        let later = entry("Gyra", "gira", order: 2)
        XCTAssertEqual(DictionaryPolicy.loadIssues(PersonalDictionary(entries: [existing, later]))[later.id]?.map(\.message),
                       ["“gira” is also used for “Jira”, which is used instead."])
        let full = PersonalDictionary(entries: (0..<500).map { entry("W\($0)", "w\($0)", order: TimeInterval($0)) })
        let over = entry("Node", "node", order: 600)
        XCTAssertEqual(DictionaryPolicy.loadIssues(PersonalDictionary(entries: full.entries + [over]))[over.id]?.map(\.message),
                       ["Your dictionary holds up to 500 words. This one isn’t used."])
        XCTAssertEqual(issues(entry("Node", "node"), in: full).map(\.message), ["Your dictionary holds up to 500 words. Delete some to add more."])
    }

    func testDuplicatePhraseIsRejectedAcrossEntriesIgnoringCaseSpacingAndApostrophe() {
        let oneil = entry("O’Neil", "o'neil", order: 1)
        let york = entry("New York", "new york", order: 2, enabled: false)
        let dictionary = PersonalDictionary(entries: [oneil, york])
        XCTAssertEqual(issues(entry("O’Neill", "o’neil"), in: dictionary), [.usedPhrase(0, phrase: "o’neil", writeAs: "O’Neil")])
        XCTAssertEqual(issues(entry("NY", "  New   YORK "), in: dictionary), [.usedPhrase(0, phrase: "New YORK", writeAs: "New York")])
        XCTAssertEqual(issues(oneil, in: dictionary), [])
        XCTAssertEqual(issues(entry("Neal", "neil", "NEIL "), in: dictionary), [.repeatedPhrase(1, phrase: "NEIL")])
    }

    func testEditorDuplicatesCompareSeparatorKindsAndEveryApostrophe() {
        let dictionary = PersonalDictionary(entries: [entry("email", "e-mail", order: 1), entry("O'Neil", "o'neil", order: 2, enabled: false)])
        XCTAssertEqual(issues(entry("E mail", "e mail"), in: dictionary), [])
        XCTAssertEqual(issues(entry("E-mail", "E\u{2010}MAIL"), in: dictionary), [.usedPhrase(0, phrase: "E\u{2010}MAIL", writeAs: "email")])
        XCTAssertEqual(issues(entry("ONeil", "O\u{2BC}NEIL"), in: dictionary), [.usedPhrase(0, phrase: "O\u{2BC}NEIL", writeAs: "O'Neil")])
        XCTAssertEqual(issues(entry("New York", "new york")), [])
    }

    func testModifierApostropheIsAnApostropheInPhrases() {
        for phrase in ["neil\u{2BC}", "\u{2BC}neil", "\u{2BC}", "\u{2BC}s"] {
            XCTAssertEqual(issues(entry("Neal", phrase)), [.phraseEdges(0)], "phrase: \(phrase)")
        }
        for phrase in ["x \u{2BC} y", "gira \u{2BC}s", "o\u{2BC}\u{2BC}neil"] {
            XCTAssertEqual(issues(entry("Neal", phrase)), [.phraseCharacters(0)], "phrase: \(phrase)")
        }
        XCTAssertEqual(issues(entry("O\u{2019}Neil", "o\u{2BC}neil")), [])
        let lone = matcher(entry("Ex", "\u{2BC}"))
        XCTAssertTrue(lone.isEmpty)
        assertUnchanged(["a \u{2BC} b"], by: lone)
    }

    func testPhrasePunctuationIsCheckedWhereItSits() {
        for phrase in ["e - mail", "e--mail", "e\u{2013}mail", "e\u{2011}mail", "e -mail", "e- mail", "o' neil", "node. js", "rock 'n' roll", "gira 's"] {
            XCTAssertEqual(issues(entry("Word", phrase)), [.phraseCharacters(0)], "phrase: \(phrase)")
        }
        XCTAssertEqual(issues(entry("Neil", "'neil")), [.phraseEdges(0)])
        XCTAssertEqual(issues(entry("Neil", "neil'")), [.phraseEdges(0)])
        XCTAssertEqual(issues(entry("Email", "e\u{2010}mail")), [])
        XCTAssertEqual(issues(entry("Node", "node.js")), [])
    }

    func testLimitsAreCountedAfterNormalization() {
        XCTAssertEqual(issues(entry("Word", String(repeating: "a", count: 64))), [])
        XCTAssertEqual(issues(entry("Word", String(repeating: "a", count: 65))), [.longPhrase(0)])
        let spaced = "  " + Array(repeating: String(repeating: "b", count: 11), count: 5).joined(separator: "    ") + "  "
        XCTAssertEqual(spaced.count, 75)
        XCTAssertEqual(issues(entry("Word", spaced)), [])
        XCTAssertEqual(issues(entry("Word", "a b c d e f")), [])
        XCTAssertEqual(issues(entry("Word", "a-b-c-d-e-f-g")), [.longPhrase(0)])
        XCTAssertEqual(issues(entry("Word", "a.b.c.d.e.f.g")), [])
        let phrase = String(repeating: "p", count: 34)
        XCTAssertEqual(issues(entry(String(repeating: "a", count: 100), phrase)), [])
        XCTAssertEqual(issues(entry(String(repeating: "a", count: 101), phrase)), [.longWriteAs])
        XCTAssertEqual(issues(entry("  " + String(repeating: "a", count: 100) + "   ", phrase)), [])
    }

    func testCapitalizationFixIsAllowed() {
        let jira = entry("Jira", "jira")
        XCTAssertEqual(issues(jira), [])
        XCTAssertEqual(matcher(jira).apply(to: "open jira").text, "open Jira")
    }

    func testChangeToMustStayCloseToThePhrase() {
        XCTAssertEqual(issues(entry("New York City", "nyc")), [])
        XCTAssertEqual(issues(entry("NYC", "new york city")), [])
        let sentence = "Please send the full quarterly report to everyone by Friday."
        XCTAssertEqual(sentence.count, 60)
        XCTAssertEqual(issues(entry(sentence, "rpt")), [.distantWriteAs])
        XCTAssertEqual(issues(entry(String(repeating: "x", count: 40), "rpt")), [])
        XCTAssertEqual(issues(entry(String(repeating: "x", count: 41), "rpt")), [.distantWriteAs])
        XCTAssertEqual(issues(entry("one two three four five", "new york city")), [])
        XCTAssertEqual(issues(entry("one two three four five six", "new york city")), [.distantWriteAs])
        // Both limits come from one phrase, so two phrases never combine into a looser bound.
        let fiveWords = "Aaaaaaaaaa Bbbbbbbbbb Cccccccccc Dddddddddd Eeee"
        XCTAssertEqual(fiveWords.count, 48)
        XCTAssertEqual(issues(entry(fiveWords, "kay bee see", "abcdefghijklmnopqrst")), [.distantWriteAs])
        XCTAssertEqual(issues(entry(fiveWords + "ee", "abcdefghijklmnopqrstuvwxyz", "a b c d e f")), [.distantWriteAs])
        XCTAssertEqual(issues(entry("New York City", "nyc", "new york city")), [])
        // The longest phrase is the one with the most characters.
        XCTAssertEqual(issues(entry("Kube A B C", "kubernetes", "cube a b")), [.distantWriteAs])
    }

    func testMarkerCharactersAreRejected() {
        for writeAs in ["a<", "x|", "y>"] {
            XCTAssertEqual(issues(entry(writeAs, "node")), [.markerInWriteAs])
        }
    }

    func testEntryLimitIsEnforced() {
        let full = PersonalDictionary(entries: (0..<500).map { entry("W\($0)", "w\($0)", order: TimeInterval($0)) })
        XCTAssertEqual(issues(entry("Node", "node"), in: full), [.dictionaryFull])
        var edited = full.entries[3]
        edited.writeAs = "Word three"
        XCTAssertEqual(issues(edited, in: full), [])
        XCTAssertEqual(issues(entry("Node", "node"), in: PersonalDictionary(entries: Array(full.entries.dropLast()))), [])
    }

    func testSearchMatchesChangeToAndPhrasesIgnoringCaseAndAccents() {
        let jose = entry("José Example", "hosay")
        let jira = entry("Jira", "gira")
        XCTAssertEqual(DictionaryPolicy.matching([jose, jira], query: "jose"), [jose])
        XCTAssertEqual(DictionaryPolicy.matching([jose, jira], query: "GIRA"), [jira])
        XCTAssertEqual(DictionaryPolicy.matching([jose, jira], query: "  "), [jose, jira])
        XCTAssertEqual(DictionaryPolicy.matching([jose, jira], query: "nothing"), [])
        XCTAssertEqual(DictionaryPolicy.sorted([jose, jira, entry("ada", "ayda")]).map(\.writeAs), ["ada", "Jira", "José Example"])
        let late = entry("Jira", "gira", order: 5)
        let early = entry("Jira", "jeera", order: 1)
        XCTAssertEqual(DictionaryPolicy.sorted([late, early]).map(\.id), [early.id, late.id])
        XCTAssertEqual(DictionaryPolicy.sorted([entry("File 10", "file ten"), entry("File 2", "file two")]).map(\.writeAs), ["File 2", "File 10"])
        let plain = entry("Jose", "hosay")
        let zoe = entry("Zoey", "zo\u{EB}")
        XCTAssertEqual(DictionaryPolicy.matching([plain, zoe], query: "jos\u{E9}"), [plain])
        XCTAssertEqual(DictionaryPolicy.matching([plain, zoe], query: "ZOE"), [zoe])
    }

    // MARK: Schema

    func testStoredDictionaryHasOnlyItsFields() throws {
        let data = try JSONEncoder().encode(PersonalDictionary(entries: [entry("Jira", "gira")]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "enabled", "entries"])
        let stored = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(stored.keys), ["id", "heardAs", "writeAs", "enabled", "created", "modified"])
        XCTAssertEqual(object["version"] as? Int, 1)
    }

    func testNewerVersionIsDetectedBeforeTheFullDecode() throws {
        XCTAssertEqual(PersonalDictionary.decode(Data(#"{"version": 2, "entries": {"shape": "different"}}"#.utf8)), .newerVersion)
        XCTAssertEqual(PersonalDictionary.decode(Data(#"{"version": 1, "entries": {"shape": "different"}}"#.utf8)), .unreadable)
        var older = PersonalDictionary()
        older.version = 0
        XCTAssertEqual(PersonalDictionary.decode(Data(#"{"version": 0, "enabled": true, "entries": []}"#.utf8)), .loaded(older))
        XCTAssertEqual(PersonalDictionary.decode(Data(#"{"entries": []}"#.utf8)), .unreadable)
        XCTAssertEqual(PersonalDictionary.decode(Data((#"{"version": 2}"# + String(repeating: " ", count: PersonalDictionary.maximumFileSize)).utf8)), .unreadable)
        XCTAssertEqual(PersonalDictionary.decode(Data("not a dictionary".utf8)), .unreadable)
        let saved = PersonalDictionary(entries: [entry("Jira", "gira")])
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(PersonalDictionary.decode(data), .loaded(saved))
        let padded = { (size: Int) in data + Data(repeating: 0x20, count: size - data.count) }
        XCTAssertEqual(PersonalDictionary.decode(padded(PersonalDictionary.maximumFileSize)), .loaded(saved))
        XCTAssertEqual(PersonalDictionary.decode(padded(PersonalDictionary.maximumFileSize + 1)), .unreadable)
    }

    func testAddedFieldsStillLoad() {
        let json = #"""
        {"version": 1, "enabled": true, "future": 3, "entries": [{"id": "00000000-0000-0000-0000-00000000000A", "heardAs": ["gira"],
         "writeAs": "Jira", "enabled": true, "created": 0, "modified": 0, "color": "red"}]}
        """#
        guard case .loaded(let dictionary) = PersonalDictionary.decode(Data(json.utf8)) else { return XCTFail("not loaded") }
        XCTAssertEqual(dictionary.entries.map(\.writeAs), ["Jira"])
    }
}

/// A fixed-seed generator so property inputs are the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 33)
    }
}
