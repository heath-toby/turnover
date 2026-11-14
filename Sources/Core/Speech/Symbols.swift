// SPDX-License-Identifier: GPL-3.0-or-later
// Symbols and punctuation. Every symbol has a level; it is spoken by name when
// its level is at or below the user's setting (none, some, most, all, as screen
// readers commonly offer), otherwise it goes to the synthesizer as-is (a pause
// for a comma, nothing for a quote). A lone character is always named. The names
// are TurnOver's own: the plain English names, as macOS and VoiceOver use them.
import Foundation
import Carbon
import NaturalLanguage

nonisolated public enum Symbols {
    private struct Symbol { let name: String; let level: SymbolLevel }

    private static let table: [Character: Symbol] = [
        "#": .init(name: String(localized: "symbol.number", defaultValue: "number", comment: "The symbol #"), level: .some), "%": .init(name: String(localized: "symbol.percent", defaultValue: "percent", comment: "The symbol %"), level: .some), "&": .init(name: String(localized: "symbol.and", defaultValue: "and", comment: "The symbol &"), level: .some),
        "*": .init(name: String(localized: "symbol.star", defaultValue: "star", comment: "The symbol *"), level: .some), "@": .init(name: String(localized: "symbol.at", defaultValue: "at", comment: "The symbol @"), level: .some), "/": .init(name: String(localized: "symbol.slash", defaultValue: "slash", comment: "The symbol /"), level: .some),
        "\\": .init(name: String(localized: "symbol.backslash", defaultValue: "backslash", comment: "The symbol \\"), level: .some), "+": .init(name: String(localized: "symbol.plus", defaultValue: "plus", comment: "The symbol +"), level: .some), "=": .init(name: String(localized: "symbol.equals", defaultValue: "equals", comment: "The symbol ="), level: .some),
        "<": .init(name: String(localized: "symbol.less than", defaultValue: "less than", comment: "The symbol <"), level: .some), ">": .init(name: String(localized: "symbol.greater than", defaultValue: "greater than", comment: "The symbol >"), level: .some), "^": .init(name: String(localized: "symbol.caret", defaultValue: "caret", comment: "The symbol ^"), level: .some),
        "|": .init(name: String(localized: "symbol.bar", defaultValue: "bar", comment: "The symbol |"), level: .some), "~": .init(name: String(localized: "symbol.tilde", defaultValue: "tilde", comment: "The symbol ~"), level: .some), "`": .init(name: String(localized: "symbol.grave", defaultValue: "grave", comment: "The symbol `"), level: .some),
        "$": .init(name: String(localized: "symbol.dollar", defaultValue: "dollar", comment: "The symbol $"), level: .some), "£": .init(name: String(localized: "symbol.pound", defaultValue: "pound", comment: "The symbol £"), level: .some), "€": .init(name: String(localized: "symbol.euro", defaultValue: "euro", comment: "The symbol €"), level: .some),
        "¥": .init(name: String(localized: "symbol.yen", defaultValue: "yen", comment: "The symbol ¥"), level: .some), "©": .init(name: String(localized: "symbol.copyright", defaultValue: "copyright", comment: "The symbol ©"), level: .some), "®": .init(name: String(localized: "symbol.registered", defaultValue: "registered", comment: "The symbol ®"), level: .some),
        "™": .init(name: String(localized: "symbol.trademark", defaultValue: "trademark", comment: "The symbol ™"), level: .some), "°": .init(name: String(localized: "symbol.degrees", defaultValue: "degrees", comment: "The symbol °"), level: .some), "§": .init(name: String(localized: "symbol.section", defaultValue: "section", comment: "The symbol §"), level: .some),
        "¶": .init(name: String(localized: "symbol.pilcrow", defaultValue: "pilcrow", comment: "The symbol ¶"), level: .some), "•": .init(name: String(localized: "symbol.bullet", defaultValue: "bullet", comment: "The symbol •"), level: .some), "·": .init(name: String(localized: "symbol.middle dot", defaultValue: "middle dot", comment: "The symbol ·"), level: .some),
        "\"": .init(name: String(localized: "symbol.quote", defaultValue: "quote", comment: "The symbol \""), level: .most), "'": .init(name: String(localized: "symbol.apostrophe", defaultValue: "apostrophe", comment: "The symbol '"), level: .most), "‘": .init(name: String(localized: "symbol.left single quote", defaultValue: "left single quote", comment: "The symbol ‘"), level: .most),
        "’": .init(name: String(localized: "symbol.right single quote", defaultValue: "right single quote", comment: "The symbol ’"), level: .most), "“": .init(name: String(localized: "symbol.left quote", defaultValue: "left quote", comment: "The symbol “"), level: .most), "”": .init(name: String(localized: "symbol.right quote", defaultValue: "right quote", comment: "The symbol ”"), level: .most),
        "(": .init(name: String(localized: "symbol.left paren", defaultValue: "left paren", comment: "The symbol ("), level: .most), ")": .init(name: String(localized: "symbol.right paren", defaultValue: "right paren", comment: "The symbol )"), level: .most), "[": .init(name: String(localized: "symbol.left bracket", defaultValue: "left bracket", comment: "The symbol ["), level: .most),
        "]": .init(name: String(localized: "symbol.right bracket", defaultValue: "right bracket", comment: "The symbol ]"), level: .most), "{": .init(name: String(localized: "symbol.left brace", defaultValue: "left brace", comment: "The symbol {"), level: .most), "}": .init(name: String(localized: "symbol.right brace", defaultValue: "right brace", comment: "The symbol }"), level: .most),
        "-": .init(name: String(localized: "symbol.dash", defaultValue: "dash", comment: "The symbol -"), level: .most), "–": .init(name: String(localized: "symbol.en dash", defaultValue: "en dash", comment: "The symbol –"), level: .most), "—": .init(name: String(localized: "symbol.em dash", defaultValue: "em dash", comment: "The symbol —"), level: .most),
        ":": .init(name: String(localized: "symbol.colon", defaultValue: "colon", comment: "The symbol :"), level: .most), ";": .init(name: String(localized: "symbol.semicolon", defaultValue: "semicolon", comment: "The symbol ;"), level: .most), "_": .init(name: String(localized: "symbol.underscore", defaultValue: "underscore", comment: "The symbol _"), level: .most),
        ",": .init(name: String(localized: "symbol.comma", defaultValue: "comma", comment: "The symbol ,"), level: .all), ".": .init(name: String(localized: "symbol.period", defaultValue: "period", comment: "The symbol ."), level: .all), "!": .init(name: String(localized: "symbol.exclamation", defaultValue: "exclamation", comment: "The symbol !"), level: .all),
        "?": .init(name: String(localized: "symbol.question mark", defaultValue: "question mark", comment: "The symbol ?"), level: .all), "…": .init(name: String(localized: "symbol.ellipsis", defaultValue: "ellipsis", comment: "The symbol …"), level: .all),
    ]

    /// The name of one character, always (the caret-character and spelling rule).
    /// The name of one character, with "cap" before a capital when the setting says so (main thread: the setting).
    /// `locale`: the language the letter is in, for lowering a capital (`letterLocale`); nil, TurnOver's own.
    @MainActor public static func name(of c: Character, locale: Locale? = nil) -> String {
        let n = name(of: c, sayCap: config.speech.sayCapForCapitals, locale: locale)
        // A capital with its pitch to be raised: marked for the speech queue, which strips the mark (Speech.enqueue).
        return c.isUppercase && (config.speech.capitalPitch > 0 || config.speech.capitalTone) ? Speech.capitalMark + n : n
    }

    /// The language TurnOver's own words are in (the catalog's, from the Mac's language): a capital's letter is lowered
    /// by its rules when nothing says what language the letter itself is in.
    nonisolated public static var interfaceLocale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    // The language a capital's letter is lowered in (Oliver's review of PR 123, 29 Oct 2026: an English text read by a
    // Turkish TurnOver said dotless ı for I). Typing, the keyboard layout's language: Turkish Q and F type Turkish.
    // Moving through text, the text's own language, when the line says it clearly enough. Else TurnOver's language.

    /// The keyboard layout's language, from the input source in use (Turkish Q and Turkish F are "tr").
    @MainActor public static var typingLocale: Locale? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return nil }
        return typingLocale(layoutLanguages: Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? [])
    }
    /// The first of a layout's languages (the one it is for), or nil when it names none.
    public static func typingLocale(layoutLanguages: [String]) -> Locale? { layoutLanguages.first.map { Locale(identifier: $0) } }

    /// The language of a line of text, when it is long enough and recognised with confidence; nil otherwise.
    public static func textLocale(_ text: String) -> Locale? {
        guard text.filter(\.isLetter).count >= 12 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(400)))
        guard let (language, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.8 else { return nil }
        return Locale(identifier: language.rawValue)
    }

    /// A capital lowered by its language's rules: in Turkish I is ı and İ is i, where lowercased(), which ignores the
    /// language, makes both i (a tester building PR 123 with JAWS fixes, 28 Oct 2026).
    public static func lowered(_ c: Character, locale: Locale = interfaceLocale) -> String { lowered(String(c), locale: locale) }
    /// Words lowered or raised by the same rules, for words said in the interface's language (an App Store count,
    /// the Keyboard Commander's letters).
    public static func lowered(_ s: String, locale: Locale = interfaceLocale) -> String { s.lowercased(with: locale) }
    public static func raised(_ s: String, locale: Locale = interfaceLocale) -> String { s.uppercased(with: locale) }

    public static func name(of c: Character, sayCap: Bool, locale: Locale? = nil) -> String {
        if let s = table[c] { return s.name }
        switch c {
        case " ": return String(localized: "symbol.space", defaultValue: "space", comment: "The space character")
        case "\u{a0}": return String(localized: "symbol.space", defaultValue: "space", comment: "The space character")   // a non-breaking space: to the listener, a space
        case "\r", "\n", "\u{2029}", "\r\n": return String(localized: "new line", comment: "A line ending, spoken as a character")
        case "\u{b}", "\u{2028}": return String(localized: "line break", comment: "A line break inside a paragraph, spoken as a character")
        case "\u{c}": return String(localized: "page break", comment: "A page break, spoken as a character")
        case "\t": return String(localized: "symbol.tab", defaultValue: "tab", comment: "The tab character")
        case "\u{8}": return String(localized: "key.backspace", defaultValue: "backspace", comment: "A key's name")
        default:
            if c.isUppercase, sayCap { return String(localized: "cap \(lowered(c, locale: locale ?? interfaceLocale))", comment: "A capital letter: %@ is the letter") }
            if let n = unicodeName(c) { return n }
            return String(c)
        }
    }

    /// A symbol's Unicode name ("→" is "rightwards arrow"), for the symbols a voice passes over in silence: arrows,
    /// maths, shapes, box drawing and the like (NVDA's "Unicode Consortium data"; a tester asked, 14 Nov 2026). Not
    /// for emoji, which the Mac's voices name themselves, in their own language ("grinning face"), nor letters,
    /// digits or ordinary punctuation.
    nonisolated public static func unicodeName(_ c: Character) -> String? {
        guard let u = c.unicodeScalars.first else { return nil }
        if c.unicodeScalars.count > 1 || u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value > 0x2000 && c.unicodeScalars.contains { $0.value == 0xFE0F }) { return nil }
        switch u.properties.generalCategory {
        case .mathSymbol, .otherSymbol, .modifierSymbol: break
        default: return nil
        }
        guard u.value > 0x7F, let raw = String(c).applyingTransform(.toUnicodeName, reverse: false),
              raw.hasPrefix("\\N{"), raw.hasSuffix("}") else { return nil }
        return String(raw.dropFirst(3).dropLast()).lowercased()
    }

    /// Symbols worth naming inside text at every level: arrows, mathematical operators, letterlike symbols.
    nonisolated static func namedInText(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x2190...0x21FF).contains(v) || (0x27F0...0x27FF).contains(v) || (0x2900...0x297F).contains(v)
            || (0x2200...0x22FF).contains(v) || (0x2A00...0x2AFF).contains(v) || (0x2100...0x214F).contains(v)
    }

    /// Emoticons said by name (":-)" is "smiley"), standing alone between spaces: off with Settings, Speech.
    nonisolated static let emoticons: [(String, String)] = [
        (":-)", "smiley"), (":)", "smiley"), ("(:", "smiley"), (";-)", "winking smiley"), (";)", "winking smiley"),
        (":-(", "sad smiley"), (":(", "sad smiley"), (":-D", "laughing smiley"), (":D", "laughing smiley"), ("XD", "laughing smiley"),
        (":-P", "smiley with tongue out"), (":P", "smiley with tongue out"), (":-p", "smiley with tongue out"), (":p", "smiley with tongue out"),
        (":-O", "surprised smiley"), (":O", "surprised smiley"), (":'(", "crying smiley"), (":-|", "straight face"), (":|", "straight face"),
        (":-/", "unsure smiley"), (":/", "unsure smiley"), ("<3", "heart"), ("</3", "broken heart"), ("^_^", "happy face"), ("o_O", "confused face"),
        ("¯\\_(ツ)_/¯", "shrug"), (":-*", "kiss"), (":*", "kiss"), ("B-)", "cool smiley"), ("8-)", "cool smiley"),
    ]
    /// The text with its emoticons named. Only whole ones, with a space, the line's edge or punctuation either side:
    /// "http://" and "(:x)" in code are left alone where they run into letters.
    nonisolated public static func namingEmoticons(_ text: String) -> String {
        guard text.contains(where: { ":;<^(¯8BXo".contains($0) }) else { return text }
        var out = text
        for (e, name) in emoticons.sorted(by: { $0.0.count > $1.0.count }) where out.contains(e) {
            let pattern = "(?<![\\p{L}\\p{N}:/])" + NSRegularExpression.escapedPattern(for: e) + "(?![\\p{L}\\p{N}/])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " " + NSRegularExpression.escapedTemplate(for: name) + " ")
        }
        guard out != text else { return text }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        // Only the spaces this added at the edges go; the text's own are kept.
        if !text.hasPrefix(" "), out.hasPrefix(" ") { out.removeFirst() }
        if !text.hasSuffix(" "), out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Text for reading: symbols at or below `level` are replaced by their names.
    /// VoiceOver's "Read numbers as digits": a run of digits said one by one ("1234" → "1 2 3 4").
    /// Every digit of a run of two or more stands apart, from punctuation too, so "12:30" is "1 2 : 3 0", never "2:3",
    /// which a voice reads as a ratio (a review).
    nonisolated public static func digitsApart(_ text: String) -> String {
        let chars = Array(text)
        func isDigit(_ i: Int) -> Bool { chars.indices.contains(i) && chars[i].isASCII && chars[i].isNumber }
        var out = ""
        for (i, c) in chars.enumerated() {
            let inRun = isDigit(i) && (isDigit(i - 1) || isDigit(i + 1))
            if inRun { if let l = out.last, l != " " { out.append(" ") }; out.append(c); if i + 1 < chars.count, chars[i + 1] != " " { out.append(" ") } }
            else { out.append(c) }
        }
        return out
    }

    /// `countRepeats`: VoiceOver's "Repeated punctuation spoken with count": four or more of the same symbol said as
    /// "7 dash", not "dash dash dash…".
    public static func process(_ text: String, level: SymbolLevel, countRepeats: Bool = false) -> String {
        guard level != .none else { return text }
        // A dot between words is a separator, said as a pause, not "bullet": Byword's status line, "Markdown • 61
        // words • 356 characters" (Day 2, 10 Oct 2026). A bullet at the start of a line, or alone, keeps its name.
        if level != .all, text.contains(" • ") || text.contains(" · ") {
            return process(text.replacingOccurrences(of: " • ", with: ", ").replacingOccurrences(of: " · ", with: ", "), level: level, countRepeats: countRepeats)
        }
        var out = ""
        out.reserveCapacity(text.count + 16)
        var lastWasName = false
        let chars = Array(text)
        var skip = 0
        for (i, c) in chars.enumerated() {
            if skip > 0 { skip -= 1; continue }
            if countRepeats, let s = table[c], s.level.rawValue <= level.rawValue {
                var run = 1
                while i + run < chars.count, chars[i + run] == c { run += 1 }
                if run >= 4 {
                    if !out.isEmpty, out.last != " " { out.append(" ") }
                    out.append("\(run) \(s.name)")
                    lastWasName = true; skip = run - 1; continue
                }
            }
            // A tick between two letters is an apostrophe (I’m, don't): a word's part, named only at "all".
            let isApostrophe = (c == "’" || c == "'") && i > 0 && i + 1 < chars.count && chars[i - 1].isLetter && chars[i + 1].isLetter
            let effective = isApostrophe ? SymbolLevel.all : (table[c]?.level ?? .all)
            if let s = table[c], effective.rawValue <= level.rawValue {
                if !out.isEmpty, out.last != " " { out.append(" ") }
                out.append(s.name)
                lastWasName = true
            } else if table[c] == nil, level == .all || namedInText(c), let n = unicodeName(c) {
                // A symbol the voice would pass over ("→"): its Unicode name. In running text only arrows, maths and
                // letterlike symbols below level All: box drawing and technical signs (Claude Code's ⎿ and ⏺ in
                // Terminal) made every line a list of names (14 Nov 2026). Moving by character names them all.
                if !out.isEmpty, out.last != " " { out.append(" ") }
                out.append(n)
                lastWasName = true
            } else {
                if lastWasName, c != " " { out.append(" ") }
                out.append(c)
                lastWasName = false
            }
        }
        return out
    }

    /// True when the text has nothing but symbols and whitespace: spoken by name whatever the level.
    public static func isAllSymbols(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }

    /// Spelled out: every character by name.
    @MainActor public static func spelled(_ text: String, locale: Locale? = nil) -> String {
        // Repeated punctuation with a count: "-----" as "5 dash" (VoiceOver), when chosen.
        guard config.speech.repeatedSymbols == "count" else { return text.map { name(of: $0, locale: locale) }.joined(separator: ", ") }
        var parts: [String] = [], chars = Array(text), i = 0
        while i < chars.count {
            var run = 1
            while i + run < chars.count, chars[i + run] == chars[i] { run += 1 }
            if run >= 4, chars[i].isPunctuation || chars[i].isSymbol { parts.append("\(run) \(name(of: chars[i], locale: locale))") }
            else { for _ in 0..<run { parts.append(name(of: chars[i], locale: locale)) } }
            i += run
        }
        return parts.joined(separator: ", ")
    }
}
