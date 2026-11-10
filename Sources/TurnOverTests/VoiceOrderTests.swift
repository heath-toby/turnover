// SPDX-License-Identifier: GPL-3.0-or-later
// The tidy voice list (VoiceOrder, 10 Nov 2026): the voices of a Mac with English (UK), German and Russian as
// macOS 27.2 listed them, reduced to the cases that matter.
import Foundation
import TurnOverVoices

func voiceOrderTests() {
    func v(_ id: String, _ name: String, _ language: String, _ quality: Int = 1, novelty: Bool = false) -> VoiceEntry {
        VoiceEntry(id: id, name: name, language: language, quality: quality, novelty: novelty)
    }
    let mac = [
        v("com.apple.voice.super-compact.en-US.Samantha", "Samantha", "en-US"),
        v("com.apple.voice.compact.en-GB.Daniel", "Daniel", "en-GB"),
        v("com.apple.voice.super-compact.en-GB.Daniel", "Daniel", "en-GB"),
        v("com.apple.voice.enhanced.en-GB.Daniel", "Daniel (Enhanced)", "en-GB", 2),
        v("com.apple.eloquence.en-GB.Reed", "Reed", "en-GB"),
        v("com.apple.siri.natural.Arthur", "Voice 2", "en-GB", 2),
        v("com.apple.speech.synthesis.voice.Bubbles", "Bubbles", "en-US", novelty: true),
        v("com.apple.voice.super-compact.de-DE.Anna", "Anna", "de-DE"),
        v("com.apple.ttsbundle.gryphon_Martin_de-DE_premium", "Voice 1", "de-DE", 3),
        v("com.apple.voice.super-compact.ru-RU.Milena", "Milena", "ru-RU"),
        v("com.apple.voice.compact.fr-FR.Thomas", "Thomas", "fr-FR"),
    ]
    let preferred = ["en-GB", "de-GB", "ru-GB"]

    test("voice list: your languages in your order, your region first, best quality first, Eloquence before plain") {
        let ids = VoiceOrder.tidy(mac, preferred: preferred).map(\.id)
        expect(ids, [
            "com.apple.voice.enhanced.en-GB.Daniel", "com.apple.siri.natural.Arthur",
            "com.apple.eloquence.en-GB.Reed", "com.apple.voice.compact.en-GB.Daniel",
            "com.apple.voice.super-compact.en-US.Samantha",
            "com.apple.ttsbundle.gryphon_Martin_de-DE_premium", "com.apple.voice.super-compact.de-DE.Anna",
            "com.apple.voice.super-compact.ru-RU.Milena",
        ])
    }
    test("voice list: a copy of the same voice once, the fuller copy kept; the voice in use always kept") {
        let ids = VoiceOrder.tidy(mac, preferred: preferred).map(\.id)
        check(!ids.contains("com.apple.voice.super-compact.en-GB.Daniel"), "the super-compact copy of Daniel left out")
        check(!ids.contains("com.apple.speech.synthesis.voice.Bubbles"), "novelty voices left out")
        check(!ids.contains("com.apple.voice.compact.fr-FR.Thomas"), "a language you don't use left out")
        let keeping = VoiceOrder.tidy(mac, preferred: preferred, keep: "com.apple.voice.super-compact.en-GB.Daniel").map(\.id)
        check(keeping.contains("com.apple.voice.super-compact.en-GB.Daniel"), "the copy in use stays")
        check(!keeping.contains("com.apple.voice.compact.en-GB.Daniel"), "and only one Daniel is listed")
        let bubbles = VoiceOrder.tidy(mac, preferred: preferred, keep: "com.apple.speech.synthesis.voice.Bubbles").map(\.id)
        check(bubbles.contains("com.apple.speech.synthesis.voice.Bubbles"), "a novelty voice in use stays")
        let french = VoiceOrder.tidy(mac, preferred: preferred, keep: "com.apple.voice.compact.fr-FR.Thomas").map(\.id)
        expect(french.last, "com.apple.voice.compact.fr-FR.Thomas", "a voice in use from another language, at the end")
    }
    test("voice list: names without their quality, Siri's numbered voices named as Siri's") {
        expect(VoiceOrder.displayName(mac[3]), "Daniel")
        expect(VoiceOrder.displayName(mac[5]), "Siri Voice 2")
        expect(VoiceOrder.displayName(mac[8]), "Siri Voice 1")
        expect(VoiceOrder.displayName(v("x", "Voice 3", "en-US")), "Voice 3", "only Siri's are renamed")
    }
    test("voice list: English is offered when it isn't one of your languages") {
        let ids = VoiceOrder.tidy(mac, preferred: ["de-DE"]).map(\.id)
        expect(ids.first, "com.apple.ttsbundle.gryphon_Martin_de-DE_premium", "your language first")
        check(ids.contains("com.apple.voice.compact.en-GB.Daniel"), "English after it")
        check(!ids.contains("com.apple.voice.super-compact.ru-RU.Milena"), "not Russian")
    }
}
