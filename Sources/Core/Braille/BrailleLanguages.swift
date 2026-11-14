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
    /// Main thread only, as the display is.
    static var memory: (language: String, at: Date)?
    private static var cache: (text: String, main: String, result: String?)?

    /// The language a line is in, among `chosen` (base codes) besides `main`; nil for the main language.
    /// Pure but for `memory`, for the tests.
    nonisolated public static func language(of text: String, marked: String?, main: String, chosen: [String], now: Date = Date(),
                                            memory: inout (language: String, at: Date)?) -> String? {
        let others = chosen.filter { $0 != main }
        guard !others.isEmpty else { return nil }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        // The document's word for it: a ticked language the letters can be in is taken; the main language, or one not
        // ticked (a French paragraph with only German ticked), is the output table, never a guess among the ticked
        // ones (a review, 14 Nov 2026). The main language's label is often only a page's default, so it is looked at.
        if let m = marked.map(Languages.base), !m.isEmpty, !Languages.contradicts(m, text) {
            if others.contains(m) { memory = (m, now); return m }
            if m != main { return nil }
        }
        // The script: the commonest one other than Latin, if most letters are in it.
        var counts: [String: Int] = [:]
        for l in letters { if let s = Languages.scriptLanguage(l.value) { counts[s, default: 0] += 1 } }
        if let (script, n) = counts.max(by: { $0.value < $1.value }), Double(n) / Double(letters.count) > 0.5 {
            let family = scriptFamilies[script] ?? [script]
            let ticked = others.filter { family.contains($0) }
            guard !ticked.isEmpty else { return nil }   // a script no ticked language is written in: the output table
            // The main language written in this script too (a Russian reader with Ukrainian ticked): told apart by the
            // recogniser, the main one the output table (a review: every Russian line went to Ukrainian).
            if family.contains(main) { return Languages.recognise(text, main: main, among: ticked, sticky: true, now: now, memory: &memory) }
            if ticked.count == 1 { memory = (ticked[0], now); return ticked[0] }
            let found = Languages.recognise(text, main: ticked[0], among: Array(ticked.dropFirst()), sticky: true, now: now, memory: &memory) ?? ticked[0]
            memory = (found, now)
            return found
        }
        // The Latin alphabet: the recogniser among the ticked languages written in it.
        let latinTicked = others.filter { l in !Languages.nonLatin.contains(l) }
        guard !latinTicked.isEmpty else { return nil }
        return Languages.recognise(text, main: main, among: latinTicked, sticky: true, now: now, memory: &memory)
    }

    /// The output table's language: the language its lines are in without switching ("eng" in
    /// "…duxbury.eng-xueb_g2"), else the Mac's (a review: the speech voice's language was taken, and an English reader
    /// with a German table had English shown in German braille).
    static var mainLanguage: String {
        if let id = BrailleOutput.outputTable, let last = id.split(separator: ".").last {
            let code = String(last.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
            if code.count == 3, let two = Locale.LanguageCode(code).identifier(.alpha2) { return two }
            if code.count == 2 { return code }
        }
        return Languages.base(Locale.current.language.languageCode?.identifier ?? "en")
    }

    /// The table for a line, or nil for the output table: when switching is on and the line is in a ticked language.
    /// `marked`: asked only when needed (an accessibility call).
    public static func table(for text: String, marked: () -> String?) -> String? {
        guard config.braille.autoLanguageSwitching, !config.braille.languages.isEmpty else { return nil }
        let main = mainLanguage
        if let c = cache, c.text == text, c.main == main { return c.result }
        var result: String?
        if let lang = language(of: text, marked: marked(), main: main, chosen: config.braille.languages.map(Languages.base), memory: &memory) {
            result = table(forLanguage: lang)
        }
        cache = (text, main, result)
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
