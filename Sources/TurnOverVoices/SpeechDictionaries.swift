// SPDX-License-Identifier: GPL-3.0-or-later
// Speech dictionaries (NVDA's: a voice's, then the default; 14 Nov 2026, Oliver: "in NVDA's style"), shared by
// TurnOver, which reads them as it speaks, and the Settings window, which edits them. Here because both use it: which
// files there are and in what order they apply, and the pronunciations made in System Settings (Accessibility, Read &
// Speak, Pronunciation), which TurnOver uses after its own.
//
// Three kinds of dictionary, each a text file of `word = say` lines (and, since 14 Nov 2026, typed entries: see
// `lines(fromText:)`) in ~/Library/Application Support/TurnOver:
//     pronunciations.txt                          the default: every voice and language
//     pronunciations/language-de.txt              one language's, by its base code
//     pronunciations/voice-<identifier>.txt       one voice's
// Applied as NVDA does: the voice's, then the language's, then the default; each to the text the one before left.
//
// The words in System Settings' list can be names from the user's contacts: they are never logged or printed, only
// counted (privacy, 14 Nov 2026).
import Foundation

public enum SpeechDictionaries {
    public enum Scope: Hashable, Sendable {
        case standard
        case language(String)
        case voice(String)

        /// The scope as text, for the TurnOver menu to ask the Settings window for it: "default", "language-de",
        /// "voice-com.apple.voice.premium.en-GB.Malcolm".
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
    }

    /// "en-GB" → "en".
    public static func baseLanguage(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// TurnOver's folder in Application Support.
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TurnOver", isDirectory: true)
    }

    /// A dictionary's file, relative to TurnOver's folder. A voice's identifier keeps letters, digits, dots and dashes;
    /// anything else (the colon of "external:af_heart", a slash) becomes an underscore, so it is always one file name.
    public static func fileName(_ scope: Scope) -> String {
        func safe(_ s: String) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.map { c -> Unicode.Scalar in
                c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "." || c == "-") ? c : "_"
            }))
        }
        switch scope {
        case .standard: return "pronunciations.txt"
        case .language(let code): return "pronunciations/language-\(safe(baseLanguage(code))).txt"
        case .voice(let identifier): return "pronunciations/voice-\(safe(identifier)).txt"
        }
    }
    public static func fileURL(_ scope: Scope, in folder: URL = SpeechDictionaries.folder) -> URL {
        folder.appendingPathComponent(fileName(scope))
    }

    /// The dictionaries for an utterance, in the order they apply: the voice's, the language's, the default.
    public static func scopes(voice: String?, language: String?) -> [Scope] {
        var out: [Scope] = []
        if let voice, !voice.isEmpty { out.append(.voice(voice)) }
        if let language, !baseLanguage(language).isEmpty { out.append(.language(language)) }
        out.append(.standard)
        return out
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
        public init(kind: Kind = .word, pattern: String, replacement: String, caseSensitive: Bool = false, comment: String = "") {
            self.kind = kind; self.pattern = pattern; self.replacement = replacement; self.caseSensitive = caseSensitive; self.comment = comment
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
        let plain = !e.caseSensitive && !e.pattern.hasPrefix("@") && !e.pattern.hasPrefix("#")
            && (e.kind == .phonemes || (e.kind == .word && !looksLikeSounds))
        let head = plain ? "" : "@" + ([e.kind.rawValue] + (e.caseSensitive ? ["case"] : [])).joined(separator: ",") + " "
        return head + pattern + " = " + replacement
    }

    /// An entry from a line; nil for a blank line, a comment, or one without a pattern and an =.
    public static func entry(fromLine raw: String) -> Entry? {
        var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty, !rest.hasPrefix("#") else { return nil }
        var kind = Entry.Kind.word, caseSensitive = false, typed = false
        // "@anywhere,case …": only when every word after the @ is one of these; else "@home = …" is a word, as before.
        if rest.hasPrefix("@"), let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let words = rest[rest.index(after: rest.startIndex)..<space].lowercased().split(separator: ",").map(String.init)
            if !words.isEmpty, words.allSatisfy({ typeWords[$0] != nil || $0 == "case" }) {
                for w in words { if let k = typeWords[w] { kind = k } else { caseSensitive = true } }
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
        return Entry(kind: kind, pattern: pattern, replacement: replacement, caseSensitive: caseSensitive)
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
