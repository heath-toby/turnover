// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's Commanders and Navigation options, NVDA's General extras (14 Nov 2026): the pure parts.
import Foundation
import CoreGraphics
import TurnOverCore

func commanderTests() {
    test("commander: right Option alone or with Shift is the default Commander, left Option and both Options are not") {
        expect(Commander.holds(.rightOption, modifiers: [.option], flags: 0x80040), true)
        expect(Commander.holds(.rightOption, modifiers: [.option, .shift], flags: 0x80042), true)
        expect(Commander.holds(.rightOption, modifiers: [.option], flags: 0x80020), false, "left Option")
        expect(Commander.holds(.rightOption, modifiers: [.option], flags: 0x80060), false, "both Options")
        expect(Commander.holds(.rightOption, modifiers: [.option, .command], flags: 0x180050), false, "Command too")
    }
    test("commander: each chosen key by its own side") {
        expect(Commander.holds(.rightCommand, modifiers: [.command], flags: 0x100010), true)
        expect(Commander.holds(.rightCommand, modifiers: [.command], flags: 0x100008), false)
        expect(Commander.holds(.leftCommand, modifiers: [.command], flags: 0x100008), true)
        expect(Commander.holds(.leftOption, modifiers: [.option], flags: 0x80020), true)
        expect(Commander.holds(.rightControl, modifiers: [.control], flags: 0x42000), true)
        expect(Commander.holds(.rightControl, modifiers: [.control], flags: 0x40001), false, "left Control")
        expect(Commander.key("nonsense"), .rightOption)
    }
    test("commander: the chosen key's letters keep the right Option identifiers") {
        let saved = config.keyboard.commanderKey
        defer { config.keyboard.commanderKey = saved }
        let cmdS = KeyboardGesture(keyCode: 1, modifiers: [.command], characters: "s", timestamp: 0, isRepeat: false, flags: CGEventFlags(rawValue: 0x100010))
        config.keyboard.commanderKey = "rightOption"
        check(!UserGestures.identifiers(of: cmdS).contains("kb:rightoption+s"), "right Command is not the Commander by default")
        config.keyboard.commanderKey = "rightCommand"
        check(UserGestures.identifiers(of: cmdS).contains("kb:rightoption+s"), "right Command chosen")
        expect(UserGestures.spoken("kb:rightoption+s"), "right command s")
        let optS = KeyboardGesture(keyCode: 1, modifiers: [.option], characters: "ß", timestamp: 0, isRepeat: false, flags: CGEventFlags(rawValue: 0x80040))
        check(!UserGestures.identifiers(of: optS).contains("kb:rightoption+s"), "right Option no longer the Commander")
    }
    test("commander: settings keep the Commander key, and an unknown one is right Option") {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"keyboard": {"commanderKey": "leftCommand"}}"#.utf8))
        expect(c.keyboard.commanderKey, "leftCommand")
        let bad = try JSONDecoder().decode(Config.self, from: Data(#"{"keyboard": {"commanderKey": "fn"}}"#.utf8))
        expect(bad.keyboard.commanderKey, "rightOption")
        let none = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        expect(none.keyboard.commanderKey, "rightOption")
        expect(none.general.cursorStart, "focus"); expect(none.general.interactOnTab, true); expect(none.general.fastSearching, false)
        expect(none.general.logLevel, "io"); expect(none.general.loginGreeting, "")
        let round = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(round.keyboard.commanderKey, "leftCommand")
    }
    test("trackpad: gestures given commands are named as said") {
        expect(Trackpad.gestureName("G flick-right 1"), "flick right")
        expect(Trackpad.gestureName("G flick-down 2"), "two-finger flick down")
        expect(Trackpad.gestureName("G triple-tap 3"), "three-finger triple-tap")
        expect(Trackpad.gestureName("G scrub"), "two-finger scrub")
        expect(UserGestures.spoken("tp:G tap 2"), "two-finger tap")
        check(Trackpad.assignable.allSatisfy { !Trackpad.gestureName($0).hasPrefix("G ") }, "every assignable gesture has a name")
    }
    test("fast searching: Right Command and a letter only, round from after the cursor") {
        expect(FastSearch.letter(keyName: "d", modifiers: [.command], flags: 0x100010), "d")
        expect(FastSearch.letter(keyName: "d", modifiers: [.command], flags: 0x100008), nil, "left Command")
        expect(FastSearch.letter(keyName: "d", modifiers: [.command, .shift], flags: 0x120010), nil, "with Shift")
        expect(FastSearch.letter(keyName: "tab", modifiers: [.command], flags: 0x100010), nil, "not a letter")
        expect(FastSearch.order(count: 4, after: 1), [2, 3, 0, 1])
        expect(FastSearch.order(count: 3, after: nil), [0, 1, 2])
        expect(FastSearch.order(count: 0, after: nil), [])
        check(FastSearch.matches("  Élan", "e"), "accents and spaces")
        check(!FastSearch.matches("Banana", "a"), "the start only")
    }
    test("log level: by name, and only the known names") {
        expect(Log.level(named: "warning"), .warning)
        expect(Log.level(named: "io"), .io)
        expect(Log.level(named: "loud"), nil)
    }
    test("login greeting: at login by the launch event or a session just begun; empty says nothing") {
        let now = Date()
        check(LoginGreeting.atLogin(launchedAsLoginItem: true, sessionStarted: nil, processStarted: now), "the launch event")
        check(LoginGreeting.atLogin(launchedAsLoginItem: false, sessionStarted: now.addingTimeInterval(-30), processStarted: now), "30 s after login")
        check(!LoginGreeting.atLogin(launchedAsLoginItem: false, sessionStarted: now.addingTimeInterval(-3600), processStarted: now), "an hour after")
        check(!LoginGreeting.atLogin(launchedAsLoginItem: false, sessionStarted: nil, processStarted: now), "no session known")
        expect(LoginGreeting.words("  "), nil)
        expect(LoginGreeting.words(" Good morning "), "Good morning")
    }
    test("portable preferences: an import must be TurnOver's settings") {
        @MainActor func refused(_ s: String) -> Bool { if case .failure = SettingsBridge.portableSettings(from: Data(s.utf8)) { return true } else { return false } }
        check(refused(""), "empty")
        check(refused("not json"), "not JSON")
        check(refused("[1, 2]"), "not an object")
        check(refused(#"{"name": "something else"}"#), "none of the sections")
        guard case .success(let c) = SettingsBridge.portableSettings(from: Data(#"{"speech": {"rate": 0.7}, "general": {"keyboardStyle": "windows"}}"#.utf8)) else { check(false, "a real file"); return }
        expect(c.config.speech.rate, 0.7); expect(c.config.general.keyboardStyle, "windows")
    }
    test("portable preferences: an import merges over the settings, keeps speech audible and leaves out keys that run things") {
        var base = Config()
        base.speech.volume = 150; base.speech.pitch = 0.3
        base.braille.verbosity = "low"
        base.keyboard.userGestures = ["kb:rightoption+a": "app:com.example.mine", "kb:rightoption+b": "script:dateTime"]
        let file = #"{"speech": {"rate": 0.7}, "keyboard": {"userGestures": {"kb:rightoption+s": "file:/tmp/x.scpt", "kb:rightoption+c": "shortcut:ABC", "kb:rightoption+d": "script:sayAll", "kb:rightoption+e": "app:com.other"}}}"#
        guard case .success(let r) = SettingsBridge.portableSettings(from: Data(file.utf8), over: base) else { check(false, "a real file"); return }
        expect(r.config.speech.rate, 0.7); expect(r.config.speech.volume, 150, "a key the file lacks keeps its value")
        expect(r.config.speech.pitch, 0.3); expect(r.config.braille.verbosity, "low", "a section the file lacks is left alone")
        expect(r.droppedKeys, 3)
        expect(r.config.keyboard.userGestures["kb:rightoption+d"], "script:sayAll")
        expect(r.config.keyboard.userGestures["kb:rightoption+s"], nil); expect(r.config.keyboard.userGestures["kb:rightoption+e"], nil)
        expect(r.config.keyboard.userGestures["kb:rightoption+a"], "app:com.example.mine", "this Mac's own app key stays")
        guard case .success(let quiet) = SettingsBridge.portableSettings(from: Data(#"{"speech": {"volume": 0, "rate": 5, "pitch": -1, "languageVolumes": {"fr": 0}}}"#.utf8), over: base) else { check(false, "speech"); return }
        expect(quiet.config.speech.volume, 10); expect(quiet.config.speech.rate, 1); expect(quiet.config.speech.pitch, 0)
        expect(quiet.config.speech.languageVolumes["fr"], 10)
        guard case .success(let v) = SettingsBridge.portableSettings(from: Data(#"{"vision": {}, "sounds": {}}"#.utf8), over: base) else { check(false, "vision and sounds only"); return }
        expect(v.config.speech.volume, 150)
    }
    test("commander: off turns off a Command Commander's letters, an Option one's set by the user stay") {
        check(UserGestures.commanderApplies(key: .rightOption, on: true, userSet: false), "on")
        check(!UserGestures.commanderApplies(key: .rightOption, on: false, userSet: false), "TurnOver's own letters off")
        check(UserGestures.commanderApplies(key: .leftOption, on: false, userSet: true), "an Option letter the user set")
        check(!UserGestures.commanderApplies(key: .leftCommand, on: false, userSet: true), "a Command letter is the app's")
        check(!UserGestures.commanderApplies(key: .rightControl, on: false, userSet: true), "Control")
        check(Commander.Key.rightOption.typesCharacters, "Option"); check(!Commander.Key.leftCommand.typesCharacters, "Command")
    }
    test("commander: T tells the time only with an Option Commander") {
        let saved = (config.keyboard.commanderKey, config.keyboard.userGestures, config.keyboard.optionCommander)
        defer { config.keyboard.commanderKey = saved.0; config.keyboard.userGestures = saved.1; config.keyboard.optionCommander = saved.2 }
        config.keyboard.userGestures = [:]; config.keyboard.optionCommander = true
        config.keyboard.commanderKey = "leftCommand"
        let cmdT = KeyboardGesture(keyCode: 17, modifiers: [.command], characters: "t", timestamp: 0, isRepeat: false, flags: CGEventFlags(rawValue: 0x100008))
        check(UserGestures.target(for: cmdT) == nil, "Left Command T stays the apps'")
        config.keyboard.userGestures = ["kb:rightoption+t": "script:sayAll"]
        check(UserGestures.target(for: cmdT) == .script("sayAll"), "unless the user gives it a command")
        config.keyboard.optionCommander = false
        check(UserGestures.target(for: cmdT) == nil, "and the Commander off gives it back")
        config.keyboard.userGestures = [:]; config.keyboard.optionCommander = true
        config.keyboard.commanderKey = "rightOption"
        let optT = KeyboardGesture(keyCode: 17, modifiers: [.option], characters: "t", timestamp: 0, isRepeat: false, flags: CGEventFlags(rawValue: 0x80040))
        check(UserGestures.target(for: optT) == .script("dateTime"), "right Option T, the time")
    }
    test("login greeting: once a login session") {
        let s = Date(timeIntervalSince1970: 1_000_000)
        expect(LoginGreeting.sessionKey(sessionStarted: s, bootedAt: nil), "login 1000000")
        expect(LoginGreeting.sessionKey(sessionStarted: nil, bootedAt: s), "boot 1000000")
        expect(LoginGreeting.sessionKey(sessionStarted: nil, bootedAt: nil), nil)
        check(LoginGreeting.due(atLogin: true, session: "login 1", lastGreeted: nil), "first")
        check(!LoginGreeting.due(atLogin: true, session: "login 1", lastGreeted: "login 1"), "a restart in the same session")
        check(LoginGreeting.due(atLogin: true, session: "login 2", lastGreeted: "login 1"), "a new login")
        check(!LoginGreeting.due(atLogin: false, session: "login 2", lastGreeted: nil), "not at login")
    }
    test("trackpad: the one-finger double-tap stays TurnOver's") {
        check(!Trackpad.assignable.contains("G double-tap 1"), "activates")
    }
}
