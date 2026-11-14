// SPDX-License-Identifier: GPL-3.0-or-later
// Braille language switching (a tester, 14 Nov 2026; JAWS has it, NVDA is working on it, and the tester's own Polyglot
// for Orca does it on Linux). Each line goes to the display in the table for the language it is in, among the
// languages ticked in Language profiles; any other line in the output table. Polyglot's rules: the script first (a
// Cyrillic line is Russian or another Cyrillic language ticked), then Apple's recogniser for text in the same script,
// at least three words (two it is all but certain of) and 85% sure; a short line keeps the language of the lines
// around it. A line's language the document states (a web page's lang) is taken when it is a ticked one.
import Foundation
import TurnOverBraille

public enum BrailleLanguages {
    /// Languages sharing a script: a line in it is one of those ticked, told apart by the recogniser.
    nonisolated static let scriptFamilies: [String: [String]] = [
        "ru": ["ru", "uk", "be", "bg", "sr", "mk", "kk"], "ar": ["ar", "fa", "ur"], "hi": ["hi", "mr", "ne"], "zh": ["zh", "ja"], "he": ["he", "yi"],
    ]

    /// Braille's own memory of the language around (not speech's: a word spoken on its own mustn't move the display).
    nonisolated(unsafe) static var memory: (language: String, at: Date)?
    private static var cache: (text: String, marked: String?, result: String?)?

    /// The language a line is in, among `chosen` (base codes) besides `main`; nil for the main language.
    /// Pure but for `memory`, for the tests.
    nonisolated public static func language(of text: String, marked: String?, main: String, chosen: [String], now: Date = Date(),
                                            memory: inout (language: String, at: Date)?) -> String? {
        let others = chosen.filter { $0 != main }
        guard !others.isEmpty else { return nil }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        // The document's word for it, when it names a ticked language the letters can be in.
        if let m = marked.map(Languages.base), others.contains(m), !Languages.contradicts(m, text) { memory = (m, now); return m }
        // The script: the commonest one other than Latin, if most letters are in it.
        var counts: [String: Int] = [:]
        for l in letters { if let s = Languages.scriptLanguage(l.value) { counts[s, default: 0] += 1 } }
        if let (script, n) = counts.max(by: { $0.value < $1.value }), Double(n) / Double(letters.count) > 0.5 {
            let family = scriptFamilies[script] ?? [script]
            let ticked = others.filter { family.contains($0) }
            guard !ticked.isEmpty else { return nil }   // a script no ticked language is written in: the output table
            if ticked.count == 1 { memory = (ticked[0], now); return ticked[0] }
            let r = Languages.recognise(text, main: ticked[0], among: Array(ticked.dropFirst()), sticky: true, now: now, memory: &memory)
            let found = r ?? ticked[0]
            memory = (found, now)
            return found
        }
        // The main script: the recogniser among the ticked languages written in it.
        let latinTicked = others.filter { l in !Languages.nonLatin.contains(l) }
        guard !latinTicked.isEmpty else { return nil }
        return Languages.recognise(text, main: main, among: latinTicked, sticky: true, now: now, memory: &memory)
    }

    /// The main language: the main voice's, else the Mac's.
    static var mainLanguage: String { Languages.mainLanguage ?? Languages.base(Locale.current.language.languageCode?.identifier ?? "en") }

    /// The table for a line, or nil for the output table: when switching is on and the line is in a ticked language.
    public static func table(for text: String, marked: String?) -> String? {
        guard config.braille.autoLanguageSwitching, !config.braille.languages.isEmpty else { return nil }
        if let c = cache, c.text == text, c.marked == marked { return c.result }
        var result: String?
        if let lang = language(of: text, marked: marked, main: mainLanguage, chosen: config.braille.languages.map(Languages.base), memory: &memory) {
            result = table(forLanguage: lang)
        }
        cache = (text, marked, result)
        return result
    }

    /// The table chosen for a language, else that language's own contracted default.
    public static func table(forLanguage code: String) -> String? {
        if let t = config.braille.languageTables[code], !t.isEmpty, TOBrailleTranslator(forTable: t) != nil { return t }
        return TOBrailleTranslator.defaultTable(forLocale: code, contracted: true)
    }

    /// Settings changed: decide every line again.
    public static func forget() { cache = nil; memory = nil }
}
