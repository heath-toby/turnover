// SPDX-License-Identifier: GPL-3.0-or-later
// A pronunciation dictionary (NVDA's speech dictionary, VoiceOver's Pronunciation settings): words said the way
// you want them said. The parity checklist of 11 Nov 2026 found none.
//
// Each dictionary is a text file in ~/Library/Application Support/TurnOver, a line each:
//     TurnOver = turn over
//     LBRF = L B R F
//     # a comment
// The word on the left is matched whole, whatever its case; the right is what the voice says. Since 14 Nov 2026 an
// entry has a type as in NVDA (whole word, anywhere, regular expression, phonemes) and may be case sensitive; the
// format is in SpeechDictionaries.lines(fromText:). Entries apply in the order listed, as NVDA's do (until then the
// longest word went first). It changes speech only:
// braille, the copy of the last thing said and the log keep the text as written. A file is read again when it
// changes, so an edit applies at once.
//
// Since 14 Nov 2026 each entry has a scope, as NVDA's voice, language and default dictionaries in one list
// (SpeechDictionaries, in TurnOverVoices: the Settings window edits it): the voice's entries apply first, then the
// language's, then those for every voice; then, unless switched off, the pronunciations made in System Settings
// (Accessibility, Read & Speak, Pronunciation), read from its preferences and never changed. Their words are never
// logged: they can be names.
import Foundation
import TurnOverSpeech
import TurnOverVoices

public enum PronunciationDictionary {
    public typealias IPAMark = SpeechPlayer.IPAMark
    public typealias Entries = [Compiled]
    /// The dictionary's file.
    public static var fileURL: URL { SpeechDictionaries.fileURL() }

    /// An entry made ready: its pattern and what a match becomes.
    public final class Compiled {
        let re: NSRegularExpression
        let template: String
        /// Which speech it is for.
        let scope: SpeechDictionaries.Scope
        /// Set when it ran too long or grew the text too much: skipped until its file changes.
        var disabled = false
        init(re: NSRegularExpression, template: String, scope: SpeechDictionaries.Scope) { self.re = re; self.template = template; self.scope = scope }
    }

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
    /// The word marked with its sounds: the Mac's voices take IPA (AVSpeechSynthesisIPANotationAttribute: measured
    /// with Daniel, 14 Nov 2026, the same sound as SSML phonemes; VoiceOver itself has no way to do this).
    private static func ipaTemplate(_ ipa: String) -> String { "\u{F8F5}" + NSRegularExpression.escapedTemplate(for: ipa) + "\u{F8F6}$0\u{F8F7}" }

    /// An entry as a pattern and template; nil when it can't be used (`Entry.problem`: an invalid regular expression
    /// is skipped, never a failure).
    package static func compile(_ e: SpeechDictionaries.Entry) -> Compiled? {
        guard e.problem == nil else { return nil }
        let options: NSRegularExpression.Options = e.caseSensitive ? [] : [.caseInsensitive]
        func made(_ re: NSRegularExpression?, _ template: String) -> Compiled? { re.map { Compiled(re: $0, template: template, scope: e.scope) } }
        switch e.kind {
        case .word:
            return made(wordPattern(e.pattern, ignoreCase: !e.caseSensitive), NSRegularExpression.escapedTemplate(for: e.replacement))
        case .phonemes:
            return made(wordPattern(e.pattern, ignoreCase: !e.caseSensitive), ipaTemplate(e.replacement))
        case .anywhere:
            return made(try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: e.pattern), options: options),
                        NSRegularExpression.escapedTemplate(for: e.replacement))
        case .regex:
            // The replacement as the user wrote it: $1 for the first group, \$ for a dollar sign.
            return made(try? NSRegularExpression(pattern: e.pattern, options: options), e.replacement)
        }
    }

    /// The entries for this voice and language in NVDA's order: the voice's, then the language's, then every
    /// voice's, each group in the order listed. Pure (tested).
    package static func ordered(_ list: Entries, voice: String?, language: String?) -> Entries {
        list.enumerated().filter { $0.element.scope.applies(voice: voice, language: language) }
            .sorted { ($0.element.scope.rank, $0.offset) < ($1.element.scope.rank, $1.offset) }.map(\.element)
    }

    /// The entries of a dictionary file's text, in the order listed (for the tests too).
    package static func parse(_ text: String) -> Entries {
        SpeechDictionaries.entries(fromText: text).compactMap(compile)
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

    /// Folders whose old per-language and per-voice files were looked for this run (SpeechDictionaries.migrate).
    private static var migrated: Set<String> = []

    /// The text as the voice should say it: the dictionary's entries for this voice, for its language, for every
    /// voice, then System Settings' (`system`), for the voice and language that will say it (`language`, a code; the
    /// app in front for System Settings' entries kept to some apps).
    /// (`folder`: TurnOver's own, but another for the tests.)
    public static func apply(_ text: String, voice: String?, language: String?, system useSystem: Bool, app: String? = nil,
                             folder: URL = SpeechDictionaries.folder) -> String {
        let now = Date()
        if migrated.insert(folder.path).inserted {
            let n = SpeechDictionaries.migrate(in: folder, knownVoices: voice.map { [$0] } ?? [])
            if n > 0 { Log.info("pronunciations: \(n) old dictionary files merged into pronunciations.txt") }
        }
        var s = text
        let list = ordered(entries(at: SpeechDictionaries.fileURL(in: folder), now: now), voice: voice, language: language)
        if !list.isEmpty { s = apply(s, list) }
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

    /// Each entry in turn on the text the one before left.
    package static func apply(_ text: String, _ list: Entries) -> String {
        var s = text
        for c in list where !c.disabled {
            if let out = replaceOutsideMarks(s, c.re, c.template) { s = out }
            else {
                c.disabled = true
                // Never the pattern: it is the user's, and can be a name.
                Log.warning("pronunciations: an entry took too long or made the text too long, and is skipped until its dictionary changes")
            }
        }
        return s
    }

    /// The longest one entry may take on a text, and how far it may grow it, before it is given up (a guard against a
    /// regular expression that backtracks without end, or one that puts its replacement everywhere: 14 Nov 2026).
    /// NSRegularExpression has no time limit of its own; with reportProgress its block is called while it works, and
    /// stopping there ends the search (measured: (a+)+b on 40 a's stopped at 50 ms, 14 Nov 2026).
    package static let timeLimit: TimeInterval = 0.05
    package static func sizeLimit(_ length: Int) -> Int { max(length * 4, length + 10_000) }

    /// Replaced outside the IPA marks (a word given its sounds isn't changed again: an "anywhere" entry for "a" would
    /// otherwise change the sounds themselves); nil when the guard stopped it.
    package static func replaceOutsideMarks(_ s: String, _ re: NSRegularExpression, _ template: String,
                                            timeLimit: TimeInterval = PronunciationDictionary.timeLimit) -> String? {
        let ns = s as NSString
        let limit = sizeLimit(ns.length)
        let started = Date()
        var out = ""
        var tooSlow = false
        var outside: [NSRange] = []
        var at = 0
        while at < ns.length {
            let open = ns.range(of: "\u{F8F5}", range: NSRange(location: at, length: ns.length - at))
            guard open.location != NSNotFound else { break }
            let close = ns.range(of: "\u{F8F7}", range: NSRange(location: open.location, length: ns.length - open.location))
            guard close.location != NSNotFound else { break }
            outside.append(NSRange(location: at, length: open.location - at))
            outside.append(NSRange(location: open.location, length: NSMaxRange(close) - open.location))   // the mark, kept
            at = NSMaxRange(close)
        }
        outside.append(NSRange(location: at, length: ns.length - at))
        for (n, range) in outside.enumerated() {
            if n % 2 == 1 { out += ns.substring(with: range); continue }
            var last = range.location
            re.enumerateMatches(in: s, options: [.reportProgress, .withTransparentBounds], range: range) { m, _, stop in
                if Date().timeIntervalSince(started) > timeLimit { tooSlow = true; stop.pointee = true; return }
                guard let m else { return }
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += re.replacementString(for: m, in: s, offset: 0, template: template)
                last = NSMaxRange(m.range)
                if (out as NSString).length > limit { tooSlow = true; stop.pointee = true }
            }
            if tooSlow { return nil }
            out += ns.substring(with: NSRange(location: last, length: NSMaxRange(range) - last))
        }
        return out
    }
}
