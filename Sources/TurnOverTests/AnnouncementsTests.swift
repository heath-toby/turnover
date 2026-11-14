// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's announcement settings and NVDA's keyboard options (Announcements.swift): their pure rules and settings.
import Foundation
import TurnOverCore

func announcementsTests() {
    test("announcements: the settings keep what TurnOver did before") {
        let k = Config.Keyboard()
        check(!k.announceModifierKeys, "modifier names off")
        check(k.interruptSpeechForTypedCharacters && k.interruptSpeechForEnter, "every key cuts speech")
        check(!k.spellingErrorSoundWhileTyping, "no typing sounds")
        check(k.allowSkimReading, "skim reading in say all")
        let p = Config.Presentation()
        expect(p.statusTextChanges, "off"); expect(p.rowCountChanges, "off"); check(!p.dialogSound, "no dialog sound")
        check(p.skipRedundantLabels, "redundant labels skipped")
    }
    test("announcements: an old settings file gets the defaults, a saved one keeps its values, a bad mode falls back") {
        let oldK = try! JSONDecoder().decode(Config.Keyboard.self, from: Data(#"{"speakNewLine": false}"#.utf8))
        check(!oldK.speakNewLine && oldK.allowSkimReading && !oldK.announceModifierKeys, "old keyboard file")
        var k = Config.Keyboard(); k.announceModifierKeys = true; k.interruptSpeechForEnter = false; k.allowSkimReading = false
        k.spellingErrorSoundWhileTyping = true; k.interruptSpeechForTypedCharacters = false
        let k2 = try! JSONDecoder().decode(Config.Keyboard.self, from: JSONEncoder().encode(k))
        check(k2.announceModifierKeys && !k2.interruptSpeechForEnter && !k2.allowSkimReading
              && k2.spellingErrorSoundWhileTyping && !k2.interruptSpeechForTypedCharacters, "keyboard round trip")
        var p = Config.Presentation(); p.statusTextChanges = "speak"; p.rowCountChanges = "tone"; p.dialogSound = true; p.skipRedundantLabels = false
        let p2 = try! JSONDecoder().decode(Config.Presentation.self, from: JSONEncoder().encode(p))
        expect(p2.statusTextChanges, "speak"); expect(p2.rowCountChanges, "tone"); check(p2.dialogSound, "dialog sound kept")
        check(!p2.skipRedundantLabels, "presentation round trip")
        let bad = try! JSONDecoder().decode(Config.Presentation.self, from: Data(#"{"statusTextChanges": "loud", "rowCountChanges": "beep"}"#.utf8))
        expect(bad.statusTextChanges, "off"); expect(bad.rowCountChanges, "off")
    }
    test("announcements: what counts as status text") {
        check(Announcements.isStatusText(role: "AXStaticText", subrole: nil), "static text")
        check(Announcements.isStatusText(role: "AXGroup", subrole: "AXApplicationStatus"), "a page's status region")
        check(Announcements.isStatusText(role: "AXGroup", subrole: "AXApplicationTimer"), "a timer")
        check(!Announcements.isStatusText(role: "AXProgressIndicator", subrole: nil), "a progress bar is ProgressWatch's")
        check(!Announcements.isStatusText(role: "AXButton", subrole: nil), "a button")
    }
    test("announcements: the spelling checker is always given a language") {
        let have = ["en", "en_GB", "tr", "de"]
        expect(Announcements.spellingLanguage(typing: nil, available: have, checkers: "en_GB"), "en_GB", "no layout language: the checker's")
        expect(Announcements.spellingLanguage(typing: "en", available: have, checkers: "en_GB"), "en_GB", "same language: the checker's own variety")
        expect(Announcements.spellingLanguage(typing: "tr", available: have, checkers: "en_GB"), "tr", "a Turkish layout")
        expect(Announcements.spellingLanguage(typing: "pt", available: ["en", "pt_BR"], checkers: "en"), "pt_BR", "the layout's language in a variety")
        expect(Announcements.spellingLanguage(typing: "ja", available: have, checkers: "en_GB"), "en_GB", "a language the checker hasn't")
        check(Announcements.checksSpelling(of: "seemless"), "a word")
        check(!Announcements.checksSpelling(of: "a"), "one letter")
        check(!Announcements.checksSpelling(of: "mp3"), "digits")
    }
    test("announcements: which keys cut speech") {
        let both = { (k: String, plain: Bool, typed: Bool) in Announcements.keyInterruptsSpeech(keyName: k, plain: plain, typesCharacter: typed, forCharacters: false, forEnter: false) }
        check(!both("a", true, true), "a letter, characters switch off")
        check(!both("enter", true, true), "Return, its switch off")
        check(both("enter", false, false), "Command Return is a command")
        check(both("backspace", true, true), "Backspace always cuts")
        check(both("downArrow", true, false), "an arrow always cuts")
        check(Announcements.keyInterruptsSpeech(keyName: "a", plain: true, typesCharacter: true, forCharacters: true, forEnter: false), "a letter, characters switch on")
        check(Announcements.keyInterruptsSpeech(keyName: "enter", plain: true, typesCharacter: true, forCharacters: false, forEnter: true), "Return, its switch on")
        check(!Announcements.keyInterruptsSpeech(keyName: "numpadEnter", plain: true, typesCharacter: true, forCharacters: true, forEnter: false), "keypad Enter follows Return")
    }
    test("announcements: rows said") {
        expect(Announcements.rows(0), "no rows"); expect(Announcements.rows(1), "1 row"); expect(Announcements.rows(5), "5 rows")
    }
}
