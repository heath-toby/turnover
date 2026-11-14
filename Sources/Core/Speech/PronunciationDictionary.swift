// SPDX-License-Identifier: GPL-3.0-or-later
// A pronunciation dictionary (NVDA's speech dictionary, VoiceOver's Pronunciation settings): words said the way
// you want them said. The parity checklist of 11 Nov 2026 found none.
//
// Each dictionary is a text file in ~/Library/Application Support/TurnOver, a line each:
//     TurnOver = turn over
//     LBRF = L B R F
//     # a comment
// The word on the left is matched whole, whatever its case; the right is what the voice says. It changes speech only:
// braille, the copy of the last thing said and the log keep the text as written. A file is read again when it
// changes, so an edit applies at once.
//
// Since 14 Nov 2026 there are three, as in NVDA (SpeechDictionaries, in TurnOverVoices: the Settings window edits
// them): the voice's own, the language's, and the default (pronunciations.txt, the one there was before), applied in
// that order; then, unless switched off, the pronunciations made in System Settings (Accessibility, Read & Speak,
// Pronunciation), read from its preferences and never changed. Their words are never logged: they can be names.
import Foundation
import TurnOverSpeech
import TurnOverVoices

public enum PronunciationDictionary {
    public typealias IPAMark = SpeechPlayer.IPAMark
    public typealias Entries = [(NSRegularExpression, String)]
    /// The default dictionary.
    public static var fileURL: URL { SpeechDictionaries.fileURL(.standard) }

    /// Each file as last read, by path, and when it was last looked at (no more than once a second).
    private struct Loaded { var stamp: Date?; var checkedAt: Date; var entries: Entries }
    private static var files: [String: Loaded] = [:]
    /// System Settings' list, as last read, with its entries made into patterns once.
    private static var system: Loaded?
    private static var systemEntries: [(entry: SpeechDictionaries.SystemEntry, re: NSRegularExpression, template: String)] = []

    /// A word as a pattern: whole (not inside another word: letters or digits either side), and not a word already
    /// given its sounds by a dictionary before (inside the IPA marks), which a later one would mark again.
    package static func wordPattern(_ word: String, ignoreCase: Bool) -> NSRegularExpression? {
        let pattern = "(?<![\\p{L}\\p{N}\\x{F8F5}\\x{F8F6}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}\\x{F8F6}\\x{F8F7}])"
        return try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }
    /// What a word becomes: the text to say, or, between slashes, the word marked with its IPA.
    package static func template(say: String) -> String {
        // Between slashes, the pronunciation in IPA: the word stays, marked with its phonemes, which the Mac's
        // voices take (AVSpeechSynthesisIPANotationAttribute: measured with Daniel, 14 Nov 2026, the same
        // sound as SSML phonemes; VoiceOver itself has no way to do this).
        if say.count > 2, say.hasPrefix("/"), say.hasSuffix("/") { return ipaTemplate(String(say.dropFirst().dropLast())) }
        return NSRegularExpression.escapedTemplate(for: say)
    }
    private static func ipaTemplate(_ ipa: String) -> String { "\u{F8F5}" + NSRegularExpression.escapedTemplate(for: ipa) + "\u{F8F6}$0\u{F8F7}" }

    /// The entries of a dictionary file's text (for the tests too).
    package static func parse(_ text: String) -> [(NSRegularExpression, String)] {
        var out: [(NSRegularExpression, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.range(of: "=") else { continue }
            let word = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            let say = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            if let re = wordPattern(word, ignoreCase: true) { out.append((re, template(say: say))) }
        }
        // Longest first: "New York City" before "New York".
        return out.sorted { $0.0.pattern.count > $1.0.pattern.count }
    }

    /// A file's entries, read again if it changed (looked at no more than once a second).
    private static func entries(at url: URL, now: Date) -> Entries {
        if let known = files[url.path], now.timeIntervalSince(known.checkedAt) <= 1 { return known.entries }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let known = files[url.path], known.stamp == stamp { files[url.path]?.checkedAt = now; return known.entries }
        let text = stamp == nil ? "" : ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        let list = parse(text)
        files[url.path] = Loaded(stamp: stamp, checkedAt: now, entries: list)
        if stamp != nil { Log.info("pronunciations: \(list.count) entries read from \(url.lastPathComponent)") }
        return list
    }

    /// System Settings' pronunciations, read again if its preferences changed (looked at no more than once a second).
    private static func refreshSystem(now: Date) {
        if let known = system, now.timeIntervalSince(known.checkedAt) <= 1 { return }
        let url = SpeechDictionaries.systemPreferencesURL
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let known = system, known.stamp == stamp { system?.checkedAt = now; return }
        system = Loaded(stamp: stamp, checkedAt: now, entries: [])
        let list = stamp == nil ? [] : ((try? Data(contentsOf: url)).flatMap(SpeechDictionaries.systemEntries(fromPreferences:)) ?? [])
        systemEntries = compiled(list)
        // Counts only: the words can be the names of the user's contacts.
        if stamp != nil { Log.info("pronunciations: \(list.count) from System Settings, \(list.filter(\.active).count) switched on") }
    }

    /// System Settings' entries as patterns, longest first: its sounds as IPA marks, else its replacement.
    package static func compiled(_ list: [SpeechDictionaries.SystemEntry]) -> [(entry: SpeechDictionaries.SystemEntry, re: NSRegularExpression, template: String)] {
        list.compactMap { e in
            guard e.active, let re = wordPattern(e.original, ignoreCase: e.ignoreCase) else { return nil }
            if let ipa = e.phonemes, !ipa.isEmpty { return (e, re, ipaTemplate(ipa)) }
            guard let say = e.replacement else { return nil }
            return (e, re, NSRegularExpression.escapedTemplate(for: say))
        }.sorted { $0.re.pattern.count > $1.re.pattern.count }
    }

    /// The text as the voice should say it: the voice's dictionary, the language's, the default, then System Settings'
    /// (`system`), for the voice and language that will say it (`language`, a code; the app in front for System
    /// Settings' entries kept to some apps).
    /// (`folder`: TurnOver's own, but another for the tests.)
    public static func apply(_ text: String, voice: String?, language: String?, system useSystem: Bool, app: String? = nil,
                             folder: URL = SpeechDictionaries.folder) -> String {
        let now = Date()
        var s = text
        for scope in SpeechDictionaries.scopes(voice: voice, language: language) {
            let list = entries(at: SpeechDictionaries.fileURL(scope, in: folder), now: now)
            if !list.isEmpty { s = apply(s, list) }
        }
        guard useSystem else { return s }
        refreshSystem(now: now)
        return applySystem(s, systemEntries, voice: voice, language: language, app: app)
    }

    /// System Settings' entries that apply to this voice, language and app, applied. Pure (tested).
    package static func applySystem(_ text: String, _ list: [(entry: SpeechDictionaries.SystemEntry, re: NSRegularExpression, template: String)],
                                    voice: String?, language: String?, app: String?) -> String {
        var s = text
        for (entry, re, template) in list where entry.applies(voice: voice, language: language, app: app) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    /// Text with IPA marks (from `apply`) as plain text and the phonemes for each marked range (UTF-16 offsets in the
    /// plain text). Pure (tested).
    public static func phonemes(in marked: String) -> (text: String, ipa: [IPAMark]) {
        guard marked.contains("\u{F8F5}") else { return (marked, []) }
        var out = "", marks: [IPAMark] = []
        var rest = Substring(marked)
        while let a = rest.firstIndex(of: "\u{F8F5}"), let b = rest[a...].firstIndex(of: "\u{F8F6}"), let c = rest[b...].firstIndex(of: "\u{F8F7}") {
            out += rest[..<a]
            let ipa = String(rest[rest.index(after: a)..<b]), word = String(rest[rest.index(after: b)..<c])
            let start = (out as NSString).length
            out += word
            marks.append(IPAMark(location: start, length: (word as NSString).length, ipa: ipa))
            rest = rest[rest.index(after: c)...]
        }
        out += rest
        return (out, marks)
    }

    package static func apply(_ text: String, _ list: [(NSRegularExpression, String)]) -> String {
        var s = text
        for (re, say) in list {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: say)
        }
        return s
    }
}
