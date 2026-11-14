// SPDX-License-Identifier: GPL-3.0-or-later
// The speech dictionary's entries, edited as in NVDA (14 Nov 2026, Oliver: "a proper editor", replacing the slashes):
// each entry has a type (whole word, anywhere, regular expression, phonemes), may be case sensitive, has a scope
// (every voice, one language or one voice: one list rather than NVDA's three dictionaries, Oliver, the same day) and
// may have a comment. The list (narrowed by the section's filter), then the chosen entry's fields, then Add, Change,
// Remove and Move up and down: entries apply in the order listed. The file format is
// SpeechDictionaries.lines(fromText:); TurnOver reads the file again within a second of a change.
//
// For phonemes, three ways to find the sounds: a pronunciation already made in System Settings (copied from its
// list, which this window may show: it is the user's own window, but the words are never logged), Hear it (the word
// said with the sounds typed, by the voice of the entry's scope), and Look up on Wiktionary (the word, and only it, sent
// when that button is pressed).
//
// What was tried and isn't here (probes of 14 Nov 2026, macOS 27.2):
// - "How the voice says it now" (the voice's own phonemes for a word, to start from): no route gives them. Public
//   AVSpeechSynthesizer.write(_:toBufferCallback:toMarkerCallback:) sends word and sentence markers but no phoneme
//   markers, for Daniel (compact and enhanced), Samantha, Eloquence Reed and Fred. The private TextToSpeech
//   TTSSpeechSynthesizer calls speechSynthesizer:didFinishSpeakingRequest:successfully:phonemesSpoken:withError:
//   with phonemesSpoken nil, and its marker callback gets TTSWordMarker only. NSSpeechSynthesizer
//   phonemes(from:) and Carbon CopyPhonemesFromText fail with -50 for every voice (MacinTalk Albert and Fred too);
//   willSpeakPhoneme and the phoneme callback are never called; the phoneme symbols property is an error.
//   TTSPhonemeSupport only goes the other way, IPA into an engine's notation (phonemesFromIPA:language: gave
//   "SI'vOOn" for ʃɪˈvɔːn; applebetPhonemesFromIPA: "SIHv1AOAOn", and threw on təˈmɑːtəʊ; eloquencePhonemesFromIPA:
//   "SI1vcn"), with no reverse.
// - "Say it" (recording the word, as System Settings' Pronunciation Record button does): that button is
//   UAPSpokenContentPhoneticRecorder in AccessibilitySettingsExtension.appex, using AssistantServices'
//   AFDictationConnection (Siri dictation, through assistantd) and AFPhonemeTranscription.phonemeSuggestions, from
//   AFSpeechToken.ipaPhoneSequence. The extension is entitled for it (com.apple.private.assistant.settings,
//   com.apple.assistant.dictation.prerecorded, private corespeech XPC services); a third-party app has none of
//   these. Speech.framework's SFTranscriptionSegment has a private ipaPhoneSequence too, but that needs the Speech
//   Recognition permission and could not be checked without asking for it, so it isn't relied on.
import SwiftUI
import AVFoundation
import AppKit
import TurnOverVoices

/// The Settings window's own voice, for Hear it.
@MainActor
final class DictionaryVoice {
    static let shared = DictionaryVoice()
    private let synthesizer = AVSpeechSynthesizer()
    /// The word said with these sounds (AVSpeechSynthesisIPANotationAttribute, as TurnOver says it), in the voice.
    func say(_ word: String, ipa: String, voice: String?) {
        let text = NSMutableAttributedString(string: word)
        text.addAttribute(NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute), value: ipa, range: NSRange(location: 0, length: (word as NSString).length))
        let utterance = AVSpeechUtterance(attributedString: text)
        utterance.voice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
}

/// Wiktionary's pronunciations of a word: its {{IPA|code|/…/}} templates in the language asked for.
enum Wiktionary {
    typealias Pronunciation = SpeechDictionaries.WiktionaryPronunciation

    /// The word's page, as typed and then in small letters, with a 10-second limit. Only the word is sent.
    static func lookUp(_ word: String, language: String) async -> [Pronunciation]? {
        var titles = [word]
        if word.lowercased() != word { titles.append(word.lowercased()) }
        var reached = false
        for title in titles {
            var parts = URLComponents(string: "https://en.wiktionary.org/w/api.php")!
            parts.queryItems = [URLQueryItem(name: "action", value: "parse"), URLQueryItem(name: "page", value: title),
                                URLQueryItem(name: "prop", value: "wikitext"), URLQueryItem(name: "format", value: "json"),
                                URLQueryItem(name: "formatversion", value: "2")]
            guard let url = parts.url else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("TurnOver (a screen reader for macOS)", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { continue }
            reached = true
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let parse = json["parse"] as? [String: Any], let text = parse["wikitext"] as? String else { continue }
            let found = SpeechDictionaries.wiktionaryPronunciations(inWikitext: text, language: language)
            if !found.isEmpty { return found }
        }
        return reached ? [] : nil
    }
}

/// Says a message through the screen reader in use (TurnOver or VoiceOver), for what a button did.
@MainActor
func announceInSettings(_ message: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

struct PronunciationsEditor: View {
    typealias Entry = SpeechDictionaries.Entry
    typealias Scope = SpeechDictionaries.Scope
    let url: URL
    /// The entries shown: those of this scope, or all (nil). It only narrows the list; a new entry takes it as scope.
    let filter: Scope?
    /// The scopes Applies to offers: every voice, the languages, the voices.
    let scopes: [Scope]
    /// A scope's name, in Applies to or in a row.
    let scopeName: (Scope, _ inRow: Bool) -> String
    /// The voice that says an entry of a scope (Hear it), and its language (Wiktionary's section).
    let hearing: (Scope) -> (voice: String?, language: String)
    /// System Settings' pronunciations given as sounds, to copy from (read by the section; never logged).
    let systemSounds: [(word: String, ipa: String)]
    /// The voices in use, to name the old per-voice files correctly when they are merged.
    let knownVoices: [String]
    /// Whether this run of the window has merged the old files yet (SpeechDictionaries.migrate).
    private static var migrated = false

    @State private var lines: [SpeechDictionaries.Line] = []
    @State private var selected: Int?
    @State private var kind = Entry.Kind.word
    @State private var pattern = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var comment = ""
    @State private var scope = Scope.standard
    @State private var unreadable = false
    @State private var systemChoice = -1
    @State private var found: [Wiktionary.Pronunciation] = []
    @State private var foundChoice = -1
    @State private var lookupNote = ""

    private var entries: [Entry] { lines.compactMap(\.entry) }
    /// The entries shown, by their number among all entries.
    private var visible: [Int] { SpeechDictionaries.shown(entries, filter: filter) }
    private var editing: Entry {
        Entry(kind: kind, pattern: pattern.trimmingCharacters(in: .whitespaces),
              replacement: kind == .phonemes ? Self.bareIPA(replacement) : replacement.trimmingCharacters(in: .whitespaces),
              caseSensitive: caseSensitive, comment: comment.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope)
    }
    /// Applies to's choices, with the entry's own if it isn't among them (a voice no longer used).
    private var scopeOptions: [Scope] { scopes.contains(scope) ? scopes : scopes + [scope] }
    /// IPA typed with its slashes or brackets, as it is often copied, without them.
    static func bareIPA(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count > 2, (t.hasPrefix("/") && t.hasSuffix("/")) || (t.hasPrefix("[") && t.hasSuffix("]")) { t = String(t.dropFirst().dropLast()) }
        return t
    }

    static func typeName(_ k: Entry.Kind) -> String {
        switch k {
        case .word: return String(localized: "Whole word", comment: "Speech dictionary entry type")
        case .anywhere: return String(localized: "Anywhere", comment: "Speech dictionary entry type: the pattern inside words too")
        case .regex: return String(localized: "Regular expression", comment: "Speech dictionary entry type")
        case .phonemes: return String(localized: "Phonemes", comment: "Speech dictionary entry type: the word said with sounds given in IPA")
        }
    }
    private static func typeHint(_ k: Entry.Kind) -> String {
        switch k {
        case .word: return String(localized: "The pattern as a whole word, not inside another word.", comment: "Speech dictionary type explained")
        case .anywhere: return String(localized: "The pattern wherever it is, inside words too: a symbol such as &, or letters such as LBRF in LBRFs.", comment: "Speech dictionary type explained")
        case .regex: return String(localized: "A regular expression. In the replacement, $1 is what the first group in brackets found, $2 the second, and so on.", comment: "Speech dictionary type explained")
        case .phonemes: return String(localized: "The pattern as a whole word, said with the sounds you give in IPA, such as ʃɪˈvɔːn for Siobhan. The Mac's voices say them; VoiceOver and the natural voices can't.", comment: "Speech dictionary type explained")
        }
    }
    /// How a row reads: "LBRF, whole word, said as L B R F, all voices".
    static func rowText(_ e: Entry, scope: String) -> String {
        let type = typeName(e.kind).lowercased(with: .current)
        var text = e.caseSensitive
            ? String(localized: "\(e.pattern), \(type), case sensitive", comment: "A speech dictionary entry: its pattern and type")
            : String(localized: "\(e.pattern), \(type)", comment: "A speech dictionary entry: its pattern and type")
        text += e.replacement.isEmpty
            ? String(localized: ", said as nothing", comment: "A speech dictionary entry that removes what it finds")
            : String(localized: ", said as \(e.replacement)", comment: "A speech dictionary entry: what is said instead")
        text += ", " + scope
        if !e.comment.isEmpty { text += String(localized: ". \(e.comment)", comment: "A speech dictionary entry's comment, after it") }
        return text
    }
    private static func problemText(_ p: Entry.Problem) -> String {
        switch p {
        case .noPattern: return String(localized: "Type the pattern first.", comment: "Speech dictionary editor")
        case .tooLong: return String(localized: "The pattern is too long: no more than \(String(Entry.maxPatternLength)) characters.", comment: "Speech dictionary editor")
        case .noPhonemes: return String(localized: "Type the sounds in IPA, or find them with the buttons below.", comment: "Speech dictionary editor")
        case .invalidRegex: return String(localized: "The pattern isn't a valid regular expression.", comment: "Speech dictionary editor")
        case .matchesEmpty: return String(localized: "The pattern can match no text at all, so its replacement would be said between every two letters. Change it so it always matches at least one character.", comment: "Speech dictionary editor")
        }
    }

    // MARK: The file

    /// The file's lines, or nil if it is there but can't be read (never then written over: a review).
    private func read() -> [SpeechDictionaries.Line]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SpeechDictionaries.lines(fromText: text)
    }
    private func load() {
        guard let l = read() else { unreadable = true; return }
        unreadable = false
        lines = l
        if let s = selected, !visible.contains(s) { selected = nil }
    }
    /// Read the file afresh and change it by entry number; refused, with a word, if it changed since it was shown.
    @discardableResult
    private func change(_ edit: (inout [SpeechDictionaries.Line], [Int]) -> Void) -> Bool {
        guard var l = read() else { unreadable = true; return false }
        guard l.compactMap(\.entry) == entries else {
            lines = l
            announceInSettings(String(localized: "The dictionary was changed elsewhere and is shown again. Try once more.", comment: "Speech dictionary editor"))
            return false
        }
        // Where each entry is among the lines.
        let at = l.indices.filter { l[$0].entry != nil }
        edit(&l, at)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? SpeechDictionaries.text(of: l).write(to: url, atomically: true, encoding: .utf8)
        load()
        return true
    }
    /// The fields emptied for a new entry, its scope the filter's (a German name added with German shown is German's).
    private func clearFields() {
        pattern = ""; replacement = ""; comment = ""; caseSensitive = false; found = []; foundChoice = -1; lookupNote = ""; systemChoice = -1
        scope = filter ?? .standard
    }
    private func show(_ i: Int) {
        guard entries.indices.contains(i) else { return }
        let e = entries[i]
        kind = e.kind; pattern = e.pattern; replacement = e.replacement; caseSensitive = e.caseSensitive; comment = e.comment; scope = e.scope
        found = []; foundChoice = -1; lookupNote = ""; systemChoice = -1
    }
    /// The entry as typed, or nil (and the reason said) when TurnOver couldn't use it.
    private func checked() -> Entry? {
        let e = editing
        if let p = e.problem { announceInSettings(Self.problemText(p)); return nil }
        return e
    }

    // MARK: The view

    var body: some View {
        Group {
            if unreadable {
                Text("The dictionary's file can't be read, so it isn't changed here.").font(.caption)
            } else if entries.isEmpty {
                Text("No entries yet. Choose a type, type the pattern and what to say, then Add.").font(.caption)
            } else if visible.isEmpty {
                Text("No entries for this choice in Show. Choose All entries to see them all, or add one here.").font(.caption)
            } else {
                List(visible, id: \.self, selection: $selected) { i in
                    Text(Self.rowText(entries[i], scope: scopeName(entries[i].scope, true))).tag(i)
                }
                .frame(minHeight: 80, maxHeight: 180)
                .accessibilityLabel(String(localized: "Entries", comment: "The list of a speech dictionary's entries"))
                .onChange(of: selected) { _, i in if let i { show(i) } }
            }
            Picker(String(localized: "Type", comment: "A speech dictionary entry's type"), selection: $kind) {
                ForEach(Entry.Kind.allCases, id: \.self) { Text(Self.typeName($0)).tag($0) }
            }
            Text(Self.typeHint(kind)).font(.caption)
            TextField(String(localized: "Pattern", comment: "What a speech dictionary entry finds"), text: $pattern)
            TextField(kind == .phonemes ? String(localized: "Phonemes (IPA)", comment: "A speech dictionary entry's sounds, in IPA")
                                        : String(localized: "Replacement", comment: "What a speech dictionary entry says instead"), text: $replacement)
            Toggle(String(localized: "Case sensitive", comment: "A speech dictionary entry matches only in this case"), isOn: $caseSensitive)
            Picker(String(localized: "Applies to", comment: "A speech dictionary entry's scope: which voices it is for"), selection: $scope) {
                ForEach(scopeOptions, id: \.self) { Text(scopeName($0, false)).tag($0) }
            }
            .accessibilityHint(String(localized: "All voices and languages, only in one language, or only for one voice. A voice's entries apply first, then its language's, then those for all voices.", comment: "Speech dictionary editor"))
            TextField(String(localized: "Comment", comment: "A speech dictionary entry's note, optional"), text: $comment)
            if !pattern.trimmingCharacters(in: .whitespaces).isEmpty, let p = editing.problem, p != .noPhonemes || !replacement.isEmpty {
                Text(Self.problemText(p)).font(.caption)
            }
            if kind == .phonemes { phonemeHelp }
            Button(String(localized: "Add", comment: "Adds a new speech dictionary entry")) {
                guard let e = checked() else { return }
                if change({ l, _ in l.append(.entry(e)) }) {
                    selected = nil; clearFields()
                    announceInSettings(filter == nil || filter == e.scope ? String(localized: "Added", comment: "A speech dictionary entry was added")
                                       : String(localized: "Added. It isn't shown with this choice in Show.", comment: "A speech dictionary entry was added, outside the filter"))
                }
            }
            Button(String(localized: "Change", comment: "Saves the fields into the chosen speech dictionary entry")) {
                guard let i = selected, entries.indices.contains(i) else {
                    announceInSettings(String(localized: "Choose an entry in the list first.", comment: "Speech dictionary editor")); return
                }
                guard let e = checked() else { return }
                if change({ l, at in l[at[i]] = .entry(e) }) {
                    if filter == nil || filter == e.scope {
                        announceInSettings(String(localized: "Changed", comment: "A speech dictionary entry was changed"))
                    } else {
                        selected = nil; clearFields()
                        announceInSettings(String(localized: "Changed. It isn't shown with this choice in Show.", comment: "A speech dictionary entry was changed to a scope outside the filter"))
                    }
                }
            }
            .disabled(selected == nil)
            Button(String(localized: "Remove", comment: "Removes the chosen speech dictionary entry")) {
                guard let i = selected, entries.indices.contains(i) else { return }
                if change({ l, at in l.remove(at: at[i]) }) {
                    selected = nil; clearFields()
                    announceInSettings(String(localized: "Removed", comment: "A speech dictionary entry was removed"))
                }
            }
            .disabled(selected == nil)
            Button(String(localized: "Move up", comment: "Moves the chosen speech dictionary entry earlier: entries apply in order")) { move(-1) }
                .disabled(selected.flatMap { visible.firstIndex(of: $0) }.map { $0 == 0 } ?? true)
            Button(String(localized: "Move down", comment: "Moves the chosen speech dictionary entry later: entries apply in order")) { move(1) }
                .disabled(selected.flatMap { visible.firstIndex(of: $0) }.map { $0 + 1 >= visible.count } ?? true)
            Text("Entries apply in the order listed, each to the text the one before left.").font(.caption)
        }
        .onAppear {
            // The old per-language and per-voice files merged in, once (TurnOver does it too as it first speaks).
            if !Self.migrated { Self.migrated = true; SpeechDictionaries.migrate(in: url.deletingLastPathComponent(), knownVoices: knownVoices) }
            if selected == nil { scope = filter ?? .standard }
            load()
        }
        .onChange(of: filter) { _, f in
            if let s = selected, !visible.contains(s) { selected = nil; clearFields() }
            else if selected == nil { scope = f ?? .standard }
        }
    }

    /// Past the entry before or after it in the list as shown (with a filter, the one shown, not one hidden between).
    private func move(_ by: Int) {
        let shown = visible
        guard let i = selected, let at = shown.firstIndex(of: i), shown.indices.contains(at + by) else { return }
        let j = shown[at + by]
        if change({ l, lineOf in l.swapAt(lineOf[i], lineOf[j]) }) {
            selected = j
            announceInSettings(String(localized: "Moved to \(String(at + by + 1)) of \(String(shown.count))", comment: "A speech dictionary entry moved: its place in the list"))
        }
    }

    /// For phonemes: System Settings' pronunciations to copy, Hear it, and Wiktionary.
    @ViewBuilder private var phonemeHelp: some View {
        if !systemSounds.isEmpty {
            Picker(String(localized: "Use a pronunciation from System Settings", comment: "Copies the sounds of one of System Settings' pronunciations"), selection: $systemChoice) {
                Text(String(localized: "Choose one", comment: "Nothing chosen yet in a list")).tag(-1)
                ForEach(systemSounds.indices, id: \.self) { i in Text(verbatim: "\(systemSounds[i].word): \(systemSounds[i].ipa)").tag(i) }
            }
            .accessibilityHint(String(localized: "The pronunciations given as sounds in System Settings, Accessibility, Read & Speak, Pronunciation. Choosing one copies its sounds into Phonemes, and its word into Pattern if that is empty.", comment: "Speech dictionary editor"))
            .onChange(of: systemChoice) { _, i in
                guard systemSounds.indices.contains(i) else { return }
                replacement = systemSounds[i].ipa
                if pattern.trimmingCharacters(in: .whitespaces).isEmpty { pattern = systemSounds[i].word }
            }
        }
        Button(String(localized: "Hear it", comment: "Says the pattern with the sounds typed")) {
            let word = pattern.trimmingCharacters(in: .whitespaces), ipa = Self.bareIPA(replacement)
            guard !word.isEmpty, !ipa.isEmpty else {
                announceInSettings(String(localized: "Type the word and its sounds first.", comment: "Speech dictionary editor: Hear it with nothing to say")); return
            }
            DictionaryVoice.shared.say(word, ipa: ipa, voice: hearing(scope).voice)
        }
        .accessibilityHint(String(localized: "Says the word with these sounds, in the voice of the entry's Applies to.", comment: "Speech dictionary editor"))
        Button(String(localized: "Look up on Wiktionary", comment: "Finds a word's pronunciation on Wiktionary")) {
            let word = pattern.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { announceInSettings(String(localized: "Type the word first.", comment: "Speech dictionary editor")); return }
            lookupNote = String(localized: "Looking up…", comment: "Wiktionary lookup under way")
            found = []; foundChoice = -1
            let language = hearing(scope).language
            Task {
                let result = await Wiktionary.lookUp(word, language: language)
                // The word may have changed while it looked.
                guard pattern.trimmingCharacters(in: .whitespaces) == word else { lookupNote = ""; return }
                switch result {
                case nil: lookupNote = String(localized: "Wiktionary couldn't be reached.", comment: "Wiktionary lookup failed")
                case let list? where list.isEmpty: lookupNote = String(localized: "Wiktionary has no pronunciation of \(word) in this language.", comment: "Wiktionary lookup found nothing")
                case let list?:
                    found = list
                    lookupNote = list.count == 1 ? String(localized: "Wiktionary has 1 pronunciation. Choose it below.", comment: "Wiktionary lookup result")
                                                 : String(localized: "Wiktionary has \(String(list.count)) pronunciations. Choose one below.", comment: "Wiktionary lookup result")
                }
                announceInSettings(lookupNote)
            }
        }
        .accessibilityHint(String(localized: "Sends the word in Pattern, and only that, to Wiktionary, and lists the pronunciations it has.", comment: "Speech dictionary editor"))
        if !lookupNote.isEmpty { Text(lookupNote).font(.caption) }
        if !found.isEmpty {
            Picker(String(localized: "Found on Wiktionary", comment: "Pronunciations found on Wiktionary"), selection: $foundChoice) {
                Text(String(localized: "Choose one", comment: "Nothing chosen yet in a list")).tag(-1)
                ForEach(found.indices, id: \.self) { i in
                    Text(verbatim: found[i].accent.isEmpty ? found[i].ipa : "\(found[i].ipa) (\(found[i].accent))").tag(i)
                }
            }
            .onChange(of: foundChoice) { _, i in if found.indices.contains(i) { replacement = found[i].ipa } }
        }
    }
}
