// SPDX-License-Identifier: GPL-3.0-or-later
// The voice list, tidied (the public roadmap, "Soon": "Voices. A tidy list: the voices for your languages, best
// quality first"). One order for every place a list of the Mac's voices is shown: Settings' Voice list, the rotor's
// list beneath it, and the speech settings ring (VO-Command-Shift with the arrows; NVDA's ring). A target of its own,
// with nothing but Foundation and AVFoundation, because Settings is a separate app that links only small targets.
//
// What was untidy, on a Mac with English, German and Russian (10 Nov 2026, macOS 27.2):
// - Daniel listed twice, a compact and a super-compact copy with the same name, language and quality.
// - "Daniel (Enhanced)" said its quality twice once the list added ", enhanced".
// - Siri's voices are named "Voice 1" and "Voice 2" by the system, which says nothing about what they are.
// - Premium and enhanced voices sorted in among the rest by name.
import Foundation
import AVFoundation

/// A voice as the list needs it: what AVSpeechSynthesisVoice says, as plain values a test can make.
public struct VoiceEntry: Sendable, Equatable {
    public let id: String
    public let name: String
    /// BCP 47, as the voice gives it ("en-GB").
    public let language: String
    /// AVSpeechSynthesisVoiceQuality's raw value: 1 default, 2 enhanced, 3 premium.
    public let quality: Int
    /// Apple's novelty voices (Bells, Bubbles, Zarvox and the rest).
    public let novelty: Bool
    public init(id: String, name: String, language: String, quality: Int, novelty: Bool) {
        self.id = id; self.name = name; self.language = language; self.quality = quality; self.novelty = novelty
    }
    public init(_ v: AVSpeechSynthesisVoice) {
        self.init(id: v.identifier, name: v.name, language: v.language, quality: v.quality.rawValue,
                  novelty: v.voiceTraits.contains(.isNoveltyVoice))
    }
}

public enum VoiceOrder {
    /// A language's base ("en" for "en-GB").
    public static func base(_ language: String) -> String {
        String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(language)).lowercased()
    }

    /// The voices worth offering, in order: your languages in the order you put them (System Settings, Language and
    /// Region), English after them if it isn't one; inside a language, your own region first; then premium before
    /// enhanced before the rest; Eloquence before Apple's other plain voices; then by name. Novelty voices are left out,
    /// and a copy of a voice already listed (same name, language, quality) is left out too. `keep` stays in whatever
    /// it is: the voice in use is never taken away from its own list.
    public static func tidy(_ voices: [VoiceEntry], preferred: [String], keep: String? = nil) -> [VoiceEntry] {
        let bases = rankedBases(preferred)
        let wanted = voices.filter { v in
            v.id == keep || (!v.novelty && bases.contains(base(v.language)))
        }
        var seen: [String: VoiceEntry] = [:]
        var order: [String] = []
        for v in wanted {
            let key = "\(base(v.language))|\(v.language.lowercased())|\(displayName(v).lowercased())|\(v.quality)"
            if let earlier = seen[key] {
                // The same voice twice: keep the one in use, else the fuller copy (compact over super-compact).
                if earlier.id == keep { continue }
                if v.id == keep || (earlier.id.contains("super-compact") && !v.id.contains("super-compact")) { seen[key] = v }
                continue
            }
            seen[key] = v
            order.append(key)
        }
        let kept = order.compactMap { seen[$0] }
        return kept.sorted { a, b in
            let la = languageRank(a.language, preferred: preferred, bases: bases), lb = languageRank(b.language, preferred: preferred, bases: bases)
            if la != lb { return la < lb }
            if a.quality != b.quality { return a.quality > b.quality }
            let ea = a.id.contains("eloquence"), eb = b.id.contains("eloquence")
            if ea != eb { return ea }
            let na = displayName(a), nb = displayName(b)
            if na != nb { return na.localizedStandardCompare(nb) == .orderedAscending }
            return a.id < b.id
        }
    }

    /// Your languages' bases in order, English last if you didn't list it.
    static func rankedBases(_ preferred: [String]) -> [String] {
        var out: [String] = []
        for p in preferred.map(base) + ["en"] where !out.contains(p) { out.append(p) }
        return out
    }

    /// Where a voice's language sits: its base's place among yours, then your exact region before the others of that
    /// base (English (UK) before English (US) for someone in the UK), then the others by their code.
    static func languageRank(_ language: String, preferred: [String], bases: [String]) -> String {
        let b = base(language)
        let bi = bases.firstIndex(of: b) ?? bases.count
        // A preferred entry may carry a script or region the voice doesn't ("de-GB" for German read in the UK): only an
        // exact match of the voice's own language counts as yours.
        let exact = preferred.contains { $0.caseInsensitiveCompare(language) == .orderedSame } ? "0" : "1"
        return String(format: "%03d", bi) + exact + language.lowercased()
    }

    /// The voice's name without the quality the system puts in it ("Daniel (Enhanced)" is Daniel; the list says
    /// "enhanced" itself), and Siri's numbered voices named as Siri's.
    public static func displayName(_ v: VoiceEntry) -> String {
        var name = v.name
        for suffix in [" (Enhanced)", " (Premium)"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        if isSiri(v), name.range(of: #"^Voice \d+$"#, options: .regularExpression) != nil { name = "Siri " + name }
        return name
    }

    /// Siri's voices: the "siri" voices and the "gryphon" bundles they ship in.
    public static func isSiri(_ v: VoiceEntry) -> Bool {
        v.id.contains(".siri.") || v.id.contains("gryphon")
    }
}
