// SPDX-License-Identifier: GPL-3.0-or-later
// The speech dictionary (NVDA's speech dictionaries, as one list: 14 Nov 2026, Oliver), shared by TurnOver, which
// reads it as it speaks, and the Settings window, which edits it. Here because both use it: the file, its format, the
// order entries apply in, and the pronunciations made in System Settings (Accessibility, Read & Speak,
// Pronunciation), which TurnOver uses after its own.
//
// One file, pronunciations.txt in ~/Library/Application Support/TurnOver, of `word = say` lines (and typed entries:
// see `lines(fromText:)`). Each entry has a scope: every voice and language, one language (by its base code), or
// one voice (by its identifier). Applied in NVDA's order: the voice's entries, then the language's, then those for
// every voice, each group in the order listed and each entry to the text the one before left.
// (The same day it was three kinds of file, pronunciations/language-<code>.txt and pronunciations/voice-<id>.txt
// beside the default, edited one at a time; Oliver asked for one list with a scope per entry instead. Those files
// are merged into pronunciations.txt once, by `migrate(in:)`, and kept renamed to *.migrated.)
//
// The words in System Settings' list can be names from the user's contacts: they are never logged or printed, only
// counted (privacy, 14 Nov 2026).
import Foundation

public enum SpeechDictionaries {
    /// Which speech an entry is for.
    public enum Scope: Hashable, Sendable {
        /// Every voice and language.
        case standard
        /// One language, by its base code ("de").
        case language(String)
        /// One voice, by its identifier ("com.apple.voice.premium.en-GB.Malcolm", "external:af_heart").
        case voice(String)

        /// The scope as text, for the Settings window's filter: "default", "language-de", "voice-…".
        public var id: String {
            switch self {
            case .standard: return "default"
            case .language(let code): return "language-" + SpeechDictionaries.baseLanguage(code)
            case .voice(let identifier): return "voice-" + identifier
            }
        }
        public init?(id: String) {
            if id == "default" { self = .standard }
            else if id.hasPrefix("language-"), id.count > 9 { self = .language(String(id.dropFirst(9))) }
            else if id.hasPrefix("voice-"), id.count > 6 { self = .voice(String(id.dropFirst(6))) }
            else { return nil }
        }

        /// Whether an entry of this scope is used for speech in this voice and language.
        public func applies(voice: String?, language: String?) -> Bool {
            switch self {
            case .standard: return true
            case .language(let code): return language.map { SpeechDictionaries.baseLanguage($0) == SpeechDictionaries.baseLanguage(code) } ?? false
            case .voice(let identifier): return voice == identifier
            }
        }
        /// NVDA's order: a voice's entries first (0), then a language's (1), then every voice's (2).
        public var rank: Int {
            switch self {
            case .voice: return 0
            case .language: return 1
            case .standard: return 2
            }
        }
    }

    /// "en-GB" → "en".
    public static func baseLanguage(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// TurnOver's folder in Application Support.
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TurnOver", isDirectory: true)
    }

    /// The dictionary's file.
    public static func fileURL(in folder: URL = SpeechDictionaries.folder) -> URL {
        folder.appendingPathComponent("pronunciations.txt")
    }

    // MARK: Entries (14 Nov 2026, Oliver: an editor "NVDA-style", with a type for each entry)

    /// One entry of a dictionary: what to find, what to say instead, and how to find it.
    public struct Entry: Equatable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            /// The pattern as a whole word, not inside another (the only kind before 14 Nov 2026).
            case word
            /// The pattern wherever it is, inside words too: a symbol such as "&", or "LBRF" in "LBRFs".
            case anywhere
            /// A regular expression (ICU, as NSRegularExpression); the replacement may use $1 and the like.
            case regex
            /// The pattern as a whole word, said with the sounds in the replacement, in IPA.
            case phonemes
        }
        public var kind: Kind
        public var pattern: String
        /// What is said instead; for phonemes the IPA itself, without slashes.
        public var replacement: String
        public var caseSensitive: Bool
        /// A note of the user's own, kept on the `#` line before the entry.
        public var comment: String
        /// Which speech it is for (14 Nov 2026): every voice, a language or a voice.
        public var scope: Scope
        public init(kind: Kind = .word, pattern: String, replacement: String, caseSensitive: Bool = false, comment: String = "", scope: Scope = .standard) {
            self.kind = kind; self.pattern = pattern; self.replacement = replacement; self.caseSensitive = caseSensitive; self.comment = comment
            self.scope = scope
        }

        /// The longest pattern used; a longer one is skipped (a guard, as for a regular expression's time).
        public static let maxPatternLength = 1000

        /// Whether TurnOver can use it: a pattern; for phonemes, sounds; for a regular expression, one that compiles and
        /// doesn't match empty text (which would put the replacement between every two letters).
        public var problem: Problem? {
            if pattern.isEmpty { return .noPattern }
            if pattern.count > Self.maxPatternLength { return .tooLong }
            switch kind {
            case .phonemes: if replacement.isEmpty { return .noPhonemes }
            case .regex:
                guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return .invalidRegex }
                if re.firstMatch(in: "", range: NSRange(location: 0, length: 0)) != nil { return .matchesEmpty }
            case .word, .anywhere: break
            }
            return nil
        }
        public enum Problem: Sendable { case noPattern, tooLong, noPhonemes, invalidRegex, matchesEmpty }
    }

    /// A line of a dictionary file: an entry (with the comment just before it), or anything else, kept as it is.
    public enum Line: Equatable, Sendable {
        case entry(Entry)
        case other(String)
        public var entry: Entry? { if case .entry(let e) = self { return e }; return nil }
    }

    /// The file format, a line each (old files are read as they always were):
    ///     LBRF = L B R F                  a whole word, any case
    ///     Siobhan = /ʃɪˈvɔːn/             a whole word said with these sounds (IPA between slashes)
    ///     @anywhere & = and               a type, and `case` for case sensitive, after an @:
    ///     @regex,case (\d+)px = $1 pixels    word, anywhere, regex, phonemes
    ///     @phonemes,lang=de Bach = bax    a scope too: lang=<base code> or voice=<identifier>, the value
    ///     @word,voice=external%3Aaf_heart LBRF = L B R F    percent-encoded past letters, digits and . - _
    ///     # a comment                     kept with the entry after it
    /// An = inside the pattern is written \= (and a backslash before one \\); the replacement is the rest of the line.
    public static func lines(fromText text: String) -> [Line] {
        var out: [Line] = []
        var comments: [String] = []
        func flushComments() { out += comments.map(Line.other); comments = [] }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { comments.append(raw); continue }
            if var e = entry(fromLine: line) {
                e.comment = comments.map { $0.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
                comments = []
                out.append(.entry(e))
            } else {
                flushComments()
                out.append(.other(raw))
            }
        }
        flushComments()
        return out
    }

    /// The entries alone, in their order.
    public static func entries(fromText text: String) -> [Entry] { lines(fromText: text).compactMap(\.entry) }

    /// The text of a file of these lines.
    public static func text(of lines: [Line]) -> String {
        var out: [String] = []
        for l in lines {
            switch l {
            case .other(let s): out.append(s)
            case .entry(let e):
                if !e.comment.isEmpty { out.append("# " + e.comment.replacingOccurrences(of: "\n", with: " ")) }
                out.append(line(for: e))
            }
        }
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    private static let typeWords: [String: Entry.Kind] = ["word": .word, "anywhere": .anywhere, "regex": .regex, "phonemes": .phonemes]

    /// An entry's line (without its comment): the old `word = say` when that says it all, else with its @ types.
    public static func line(for e: Entry) -> String {
        let pattern = escapePattern(e.pattern)
        let replacement = e.kind == .phonemes ? "/" + e.replacement + "/" : e.replacement
        let looksLikeSounds = e.replacement.count > 2 && e.replacement.hasPrefix("/") && e.replacement.hasSuffix("/")
        let plain = !e.caseSensitive && e.scope == .standard && !e.pattern.hasPrefix("@") && !e.pattern.hasPrefix("#")
            && (e.kind == .phonemes || (e.kind == .word && !looksLikeSounds))
        var words = [e.kind.rawValue]
        if e.caseSensitive { words.append("case") }
        switch e.scope {
        case .standard: break
        case .language(let code): words.append("lang=" + encodeScopeValue(baseLanguage(code)))
        case .voice(let identifier): words.append("voice=" + encodeScopeValue(identifier))
        }
        let head = plain ? "" : "@" + words.joined(separator: ",") + " "
        return head + pattern + " = " + replacement
    }

    /// A scope's value in its @ word: letters, digits, dot, dash, underscore as they are, anything else percent-encoded
    /// (a voice's "external:af_heart" as external%3Aaf_heart), so a comma, space or = can never end the word early.
    public static func encodeScopeValue(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(Unicode.Scalar(b))
            if b < 0x80, c.isLetter || c.isNumber || c == "." || c == "-" || c == "_" { out.append(c) }
            else { out += String(format: "%%%02X", b) }
        }
        return out
    }
    /// The value back; nil when it is empty or not valid percent-encoding.
    public static func decodeScopeValue(_ s: Substring) -> String? {
        guard !s.isEmpty, let v = s.removingPercentEncoding, !v.isEmpty else { return nil }
        return v
    }

    /// An entry from a line; nil for a blank line, a comment, or one without a pattern and an =.
    public static func entry(fromLine raw: String) -> Entry? {
        var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty, !rest.hasPrefix("#") else { return nil }
        var kind = Entry.Kind.word, caseSensitive = false, typed = false, scope = Scope.standard
        // "@anywhere,case,lang=de …": only when every word after the @ is one of these; else "@home = …" is a word, as
        // before. A scope's value keeps its case (a voice's identifier), the rest is read in any case.
        if rest.hasPrefix("@"), let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            var known = true
            var k = kind, c = false, sc = Scope.standard
            let words = rest[rest.index(after: rest.startIndex)..<space].split(separator: ",", omittingEmptySubsequences: false)
            for w in words {
                if let eq = w.firstIndex(of: "=") {
                    let key = w[..<eq].lowercased(), value = decodeScopeValue(w[w.index(after: eq)...])
                    if key == "lang", let value, !baseLanguage(value).isEmpty { sc = .language(baseLanguage(value)) }
                    else if key == "voice", let value { sc = .voice(value) }
                    else { known = false; break }
                } else if let t = typeWords[w.lowercased()] { k = t }
                else if w.lowercased() == "case" { c = true }
                else { known = false; break }
            }
            if known, !words.isEmpty {
                kind = k; caseSensitive = c; scope = sc
                typed = true
                rest = rest[space...].drop(while: { $0 == " " || $0 == "\t" })
            }
        }
        // The pattern runs to the first = not escaped (\=); \\ is a backslash, any other backslash stays.
        var pattern = "", separator: Substring.Index?
        var i = rest.startIndex
        while i < rest.endIndex {
            let c = rest[i]
            let next = rest.index(after: i)
            if c == "\\", next < rest.endIndex, rest[next] == "=" || rest[next] == "\\" {
                pattern.append(rest[next]); i = rest.index(after: next); continue
            }
            if c == "=" { separator = i; break }
            pattern.append(c); i = next
        }
        guard let separator else { return nil }
        pattern = pattern.trimmingCharacters(in: .whitespaces)
        var replacement = rest[rest.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return nil }
        let slashed = replacement.count > 2 && replacement.hasPrefix("/") && replacement.hasSuffix("/")
        if !typed && slashed { kind = .phonemes }
        if kind == .phonemes && slashed { replacement = String(replacement.dropFirst().dropLast()) }
        return Entry(kind: kind, pattern: pattern, replacement: replacement, caseSensitive: caseSensitive, scope: scope)
    }

    /// A pattern as written in the file: = as \=, and a backslash that would read as an escape doubled.
    static func escapePattern(_ p: String) -> String {
        var out = ""
        let chars = Array(p)
        for (i, c) in chars.enumerated() {
            if c == "=" { out += "\\=" }
            else if c == "\\", i + 1 < chars.count, chars[i + 1] == "=" || chars[i + 1] == "\\" { out += "\\\\" }
            else { out.append(c) }
        }
        return out
    }

    /// The entries the Settings window shows for its filter, by their number among all: those of the scope, or
    /// every one (nil). The filter only narrows what is shown.
    public static func shown(_ entries: [Entry], filter: Scope?) -> [Int] {
        entries.indices.filter { filter == nil || entries[$0].scope == filter }
    }

    // MARK: The files of the morning of 14 Nov 2026, merged into one

    /// The folder those files were in, inside TurnOver's.
    public static let legacyFolderName = "pronunciations"

    /// Its file name for a voice: letters, digits, dots and dashes kept, anything else an underscore (as it was).
    public static func legacyFileName(voice identifier: String) -> String {
        "voice-" + String(String.UnicodeScalarView(identifier.unicodeScalars.map { c -> Unicode.Scalar in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "." || c == "-") ? c : "_"
        })) + ".txt"
    }

    /// The scope of an old file by its name; nil for any other file. A voice's identifier lost its colon to an
    /// underscore: one of `knownVoices` with that file name is taken, else "external_…" is a natural voice's
    /// "external:…" (Apple's identifiers have letters, digits, dots, dashes and underscores, kept as they were).
    public static func legacyScope(fileName name: String, knownVoices: [String] = []) -> Scope? {
        guard name.hasSuffix(".txt") else { return nil }
        let stem = name.dropLast(4)
        if stem.hasPrefix("language-"), stem.count > 9 {
            let code = baseLanguage(String(stem.dropFirst(9)))
            return code.isEmpty ? nil : .language(code)
        }
        guard stem.hasPrefix("voice-"), stem.count > 6 else { return nil }
        if let known = knownVoices.first(where: { legacyFileName(voice: $0) == name }) { return .voice(known) }
        let id = String(stem.dropFirst(6))
        if id.hasPrefix("external_") { return .voice("external:" + id.dropFirst(9)) }
        return .voice(id)
    }

    /// Entries of pronunciations/language-*.txt and voice-*.txt added to pronunciations.txt with their scope (any
    /// already there, scope and all, not twice: a merge cut short is merged again safely), then each old file renamed
    /// to *.migrated, never deleted. Only when pronunciations.txt is missing or can be read, and an old file only once
    /// it is read; written atomically, and nothing renamed if the write fails. Returns how many files were merged.
    /// Run by TurnOver as it first speaks and by the Settings window as it shows the dictionary.
    @discardableResult
    public static func migrate(in folder: URL = SpeechDictionaries.folder, knownVoices: [String] = []) -> Int {
        let fm = FileManager.default
        let old = folder.appendingPathComponent(legacyFolderName, isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return 0 }
        let found = names.sorted().compactMap { name in legacyScope(fileName: name, knownVoices: knownVoices).map { (name, $0) } }
        guard !found.isEmpty else { return 0 }
        let main = fileURL(in: folder)
        var text = ""
        if fm.fileExists(atPath: main.path) {
            guard let t = try? String(contentsOf: main, encoding: .utf8) else { return 0 }
            text = t
        }
        var lines = self.lines(fromText: text)
        // Compared without their comments: the same rule with another note is still the same rule.
        func bare(_ e: Entry) -> Entry { var e = e; e.comment = ""; return e }
        var have = lines.compactMap(\.entry).map(bare)
        var merged: [String] = []
        for (name, scope) in found {
            guard let t = try? String(contentsOf: old.appendingPathComponent(name), encoding: .utf8) else { continue }
            for var e in entries(fromText: t) {
                e.scope = scope
                if !have.contains(bare(e)) { lines.append(.entry(e)); have.append(bare(e)) }
            }
            merged.append(name)
        }
        guard !merged.isEmpty else { return 0 }
        let newText = self.text(of: lines)
        if newText != text {
            do { try newText.write(to: main, atomically: true, encoding: .utf8) } catch { return 0 }
        }
        for name in merged {
            let from = old.appendingPathComponent(name)
            var to = old.appendingPathComponent(name + ".migrated")
            var n = 2
            while fm.fileExists(atPath: to.path) { to = old.appendingPathComponent("\(name).\(n).migrated"); n += 1 }
            try? fm.moveItem(at: from, to: to)
        }
        return merged.count
    }

    // MARK: Wiktionary (the Settings window's Look up on Wiktionary, 14 Nov 2026)

    public struct WiktionaryPronunciation: Hashable, Sendable {
        public let ipa: String
        /// Where it is said so ("RP, AU"), or empty.
        public let accent: String
    }

    /// The pronunciations in a Wiktionary page's wikitext: its {{IPA|code|/…/|a=accent}} templates, for a language
    /// by its base code. Pure (tested).
    public static func wiktionaryPronunciations(inWikitext text: String, language: String) -> [WiktionaryPronunciation] {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{IPA\\|([^|}]+)\\|([^}]*)\\}\\}") else { return [] }
        var out: [WiktionaryPronunciation] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let codeRange = Range(m.range(at: 1), in: text), let restRange = Range(m.range(at: 2), in: text),
                  baseLanguage(String(text[codeRange])) == baseLanguage(language) else { continue }
            let parts = text[restRange].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let accent = parts.first { $0.hasPrefix("a=") }.map { $0.dropFirst(2).replacingOccurrences(of: ",", with: ", ") } ?? ""
            for p in parts where !p.contains("=") {
                // "/təˈmɑː.təʊ/" or "[tʰəˈmeɪ̯ɾo]": the sounds without their brackets or syllable dots.
                guard p.count > 2, let first = p.first, let last = p.last, (first == "/" && last == "/") || (first == "[" && last == "]") else { continue }
                let ipa = p.dropFirst().dropLast().replacingOccurrences(of: ".", with: "")
                // A part of a word ("-ˈme(ː)tʰo(ː)") isn't a pronunciation of it.
                guard !ipa.isEmpty, !ipa.hasPrefix("-"), !ipa.hasSuffix("-"), !ipa.contains("("),
                      !out.contains(where: { $0.ipa == ipa }) else { continue }
                out.append(WiktionaryPronunciation(ipa: ipa, accent: accent))
            }
        }
        return out
    }

    // MARK: System Settings' pronunciations

    /// System Settings' list: com.apple.SpeakSelection, key CustomPronunciationSubstitutions, an NSKeyedArchiver
    /// archive of an array of TTSSubstitution objects (macOS 27.2, 14 Nov 2026). Read only, never written.
    public static var systemPreferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.SpeakSelection.plist")
    }
    public static let systemPreferencesKey = "CustomPronunciationSubstitutions"

    public struct SystemEntry: Equatable, Sendable {
        public var original: String
        public var replacement: String?
        /// The pronunciation in IPA, when it was given as sounds (Listen, or typed phonemes).
        public var phonemes: String?
        public var active: Bool
        public var ignoreCase: Bool
        /// Language codes ("en-GB"); empty for every language.
        public var languages: [String]
        /// Voice identifiers; empty for every voice.
        public var voiceIds: [String]
        public var appliesToAllApps: Bool
        public var bundleIdentifiers: [String]
        public init(original: String, replacement: String? = nil, phonemes: String? = nil, active: Bool = true, ignoreCase: Bool = true,
                    languages: [String] = [], voiceIds: [String] = [], appliesToAllApps: Bool = true, bundleIdentifiers: [String] = []) {
            self.original = original; self.replacement = replacement; self.phonemes = phonemes; self.active = active; self.ignoreCase = ignoreCase
            self.languages = languages; self.voiceIds = voiceIds; self.appliesToAllApps = appliesToAllApps; self.bundleIdentifiers = bundleIdentifiers
        }
        /// Whether it is used for speech in this voice and language, in this app. A language matches by its base
        /// ("en-GB" for an en-US voice too): the list's languages are the Mac's, the voice's may be another dialect.
        public func applies(voice: String?, language: String?, app: String?) -> Bool {
            guard active, !original.isEmpty else { return false }
            if !languages.isEmpty {
                guard let language, languages.contains(where: { baseLanguage($0) == baseLanguage(language) }) else { return false }
            }
            if !voiceIds.isEmpty {
                guard let voice, voiceIds.contains(voice) else { return false }
            }
            if !appliesToAllApps, !bundleIdentifiers.isEmpty {
                guard let app, bundleIdentifiers.contains(app) else { return false }
            }
            return true
        }
    }

    /// The entries of System Settings' preferences file (its whole contents); nil if it can't be read as one.
    public static func systemEntries(fromPreferences data: Data) -> [SystemEntry]? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        guard let archive = plist[systemPreferencesKey] as? Data else { return [] }
        return systemEntries(fromArchive: archive)
    }

    /// The entries of the archived list; nil if it can't be decoded. Unknown classes inside become empty objects
    /// (a later macOS adding one doesn't lose the rest), and a failure is an error, never an exception.
    public static func systemEntries(fromArchive data: Data) -> [SystemEntry]? {
        guard let u = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        u.requiresSecureCoding = false
        u.decodingFailurePolicy = .setErrorAndReturn
        u.setClass(SystemPronunciationRecord.self, forClassName: "TTSSubstitution")
        let stand = UnknownClassStandIn()
        u.delegate = stand
        let root = try? u.decodeTopLevelObject(forKey: NSKeyedArchiveRootObjectKey)
        u.finishDecoding()
        guard let list = root as? NSArray else { return nil }
        return list.compactMap { ($0 as? SystemPronunciationRecord)?.entry }
    }
}

/// A TTSSubstitution, as decoded (and, for the tests, archived under that name). Read with the keys System Settings
/// writes: originalString, replacementString, phonemes, active, ignoreCase, languages, voiceIds, appliesToAllApps,
/// bundleIdentifiers (uuid and replacementRange are not needed).
@objc(TOSystemPronunciationRecord)
public final class SystemPronunciationRecord: NSObject, NSCoding {
    public var originalString: String?
    public var replacementString: String?
    public var phonemes: String?
    public var active = true
    public var ignoreCase = true
    public var languages: [String] = []
    public var voiceIds: [String] = []
    public var appliesToAllApps = true
    public var bundleIdentifiers: [String] = []

    public override init() { super.init() }

    public required init?(coder: NSCoder) {
        func string(_ key: String) -> String? { (coder.decodeObject(forKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func strings(_ key: String) -> [String] {
            switch coder.decodeObject(forKey: key) {
            case let set as NSSet: return set.allObjects.compactMap { $0 as? String }
            case let array as NSArray: return array.compactMap { $0 as? String }
            case let one as String: return one.isEmpty ? [] : [one]
            default: return []
            }
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool { coder.containsValue(forKey: key) ? coder.decodeBool(forKey: key) : fallback }
        originalString = string("originalString")
        replacementString = string("replacementString")
        phonemes = string("phonemes")
        active = bool("active", true)
        ignoreCase = bool("ignoreCase", true)
        languages = strings("languages")
        voiceIds = strings("voiceIds")
        appliesToAllApps = bool("appliesToAllApps", true)
        bundleIdentifiers = strings("bundleIdentifiers")
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(originalString, forKey: "originalString")
        coder.encode(replacementString, forKey: "replacementString")
        coder.encode(phonemes, forKey: "phonemes")
        coder.encode(active, forKey: "active")
        coder.encode(ignoreCase, forKey: "ignoreCase")
        coder.encode(NSSet(array: languages), forKey: "languages")
        coder.encode(voiceIds.isEmpty ? nil : NSSet(array: voiceIds), forKey: "voiceIds")
        coder.encode(appliesToAllApps, forKey: "appliesToAllApps")
        coder.encode(bundleIdentifiers.isEmpty ? nil : NSSet(array: bundleIdentifiers), forKey: "bundleIdentifiers")
        coder.encode(NSUUID(), forKey: "uuid")
    }

    var entry: SpeechDictionaries.SystemEntry? {
        guard let originalString else { return nil }
        return SpeechDictionaries.SystemEntry(original: originalString, replacement: replacementString, phonemes: phonemes, active: active,
                                              ignoreCase: ignoreCase, languages: languages, voiceIds: voiceIds,
                                              appliesToAllApps: appliesToAllApps, bundleIdentifiers: bundleIdentifiers)
    }
}

/// Whatever the archive holds that isn't known here, decoded as nothing.
@objc(TOUnknownArchivedObject)
final class UnknownArchivedObject: NSObject, NSCoding {
    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}
}

final class UnknownClassStandIn: NSObject, NSKeyedUnarchiverDelegate {
    func unarchiver(_ unarchiver: NSKeyedUnarchiver, cannotDecodeObjectOfClassName name: String, originalClasses classNames: [String]) -> AnyClass? {
        UnknownArchivedObject.self
    }
}
