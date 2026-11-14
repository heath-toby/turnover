// SPDX-License-Identifier: GPL-3.0-or-later
// Line indentation (NVDA's Document formatting, "Line indentation reporting"; VoiceOver's Text, "Line indentation"),
// which the settings audit found missing (14 Nov 2026): as the caret moves by line, a change in a line's leading
// spaces and tabs is said ("4 space", "tab", "no indent"), sounded (a tone a quarter tone higher for each column,
// as NVDA's tones and the tester's IndentBeeper), or both. Blank lines are passed over, as NVDA does by default.
import Foundation

nonisolated public enum Indentation {
    /// The line's leading tabs and spaces, and its width in columns (a tab is four).
    public static func leading(_ line: String) -> (tabs: Int, spaces: Int, columns: Int)? {
        var tabs = 0, spaces = 0
        for c in line {
            if c == "\t" { tabs += 1 } else if c == " " || c == "\u{00A0}" { spaces += 1 } else { break }
        }
        // A blank line says nothing about indentation.
        guard line.contains(where: { !$0.isWhitespace }) else { return nil }
        return (tabs, spaces, tabs * 4 + spaces)
    }

    /// "2 tab 4 space", "tab", "no indent".
    public static func words(tabs: Int, spaces: Int) -> String {
        var parts: [String] = []
        if tabs > 0 { parts.append(tabs == 1 ? String(localized: "tab", comment: "Line indentation: one tab") : String(localized: "\(String(tabs)) tab", comment: "Line indentation: tabs, as NVDA says it")) }
        if spaces > 0 { parts.append(spaces == 1 ? String(localized: "space", comment: "Line indentation: one space") : String(localized: "\(String(spaces)) space", comment: "Line indentation: spaces, as NVDA says it")) }
        return parts.isEmpty ? String(localized: "no indent", comment: "Line indentation: none") : parts.joined(separator: " ")
    }

    /// The tone's frequency for a width: 220 Hz, a quarter tone higher for each column, round again past 72.
    public static func frequency(columns: Int) -> Double { 220 * pow(2, Double(columns % 72) / 24) }
}
