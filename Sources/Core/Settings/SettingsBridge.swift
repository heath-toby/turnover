// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver Settings (18 Oct 2026: "why not a settings app now?"): a small app of its own inside TurnOver.app,
// read by TurnOver like any other app. (TurnOver can't read a window of its own process: its accessibility calls to
// itself would wait on its own main thread.) The app never writes the settings file: it sends each change here as a
// patch, part of the settings file's JSON ({"speech": {"rate": 0.6}}), TurnOver merges it into its settings, saves,
// puts it into effect, and answers with the whole settings so the app shows what is really set.
// A few settings live outside the file (the say all voice, CoExist): their patches start with "_".
// The talk goes through TurnOver's control channel (TurnOverControl), which only programs signed by TurnOver's own
// developer may use: before a code review on 18 Oct 2026 it was distributed notifications, which any program could
// post (and change TurnOver's settings with) or hear (and read them all).
import Foundation
import AppKit
import TurnOverControl
import TurnOverSpeech
import AVFoundation

public enum SettingsBridge {
    /// A section of the Settings window by its name there, as the window says it in the reader's language.
    nonisolated public static func sectionName(_ section: String) -> String {
        switch section {
        case "Speech": return String(localized: "Speech", comment: "A section of the Settings window")
        case "Sounds": return String(localized: "Sounds", comment: "A section of the Settings window")
        case "Keyboard": return String(localized: "Keyboard", comment: "A section of the Settings window")
        case "Mouse": return String(localized: "Mouse", comment: "A section of the Settings window")
        case "Item details": return String(localized: "Item details", comment: "A section of the Settings window")
        case "Web pages": return String(localized: "Web pages", comment: "A section of the Settings window")
        case "Documents": return String(localized: "Documents", comment: "A section of the Settings window")
        case "Braille": return String(localized: "Braille", comment: "A section of the Settings window")
        case "Vision": return String(localized: "Vision", comment: "A section of the Settings window")
        case "General": return String(localized: "General", comment: "A section of the Settings window")
        case "Screen recognition": return String(localized: "Screen recognition", comment: "A section of the Settings window")
        case "Other apps' speech": return String(localized: "Other apps' speech", comment: "A section of the Settings window")
        case "Screen reader behaviour": return String(localized: "Screen reader behaviour", comment: "A section of the Settings window")
        case dictionarySection: return String(localized: "Speech dictionary", comment: "A section of the Settings window")
        default: return section
        }
    }
    /// The Speech dictionary section (one list since 14 Nov 2026; before, "Speech dictionaries|voice-…" chose a file).
    nonisolated public static let dictionarySection = "Speech dictionary"
    /// An EQ slider's name, as a change announces it: from a list in the window, so the catalog has the three
    /// spelled out (a tester heard "Treble" under a Russian interface, 8 Nov 2026).
    nonisolated public static func eqName(_ name: String) -> String {
        switch name {
        case "Bass": return String(localized: "Bass", comment: "An equalizer slider: the low frequencies")
        case "Middle": return String(localized: "Middle", comment: "An equalizer slider: the middle frequencies")
        case "Treble": return String(localized: "Treble", comment: "An equalizer slider: the high frequencies")
        default: return name
        }
    }
    private static var started = false
    /// Restart TurnOver (set by the app): CoExist changes need it.
    public static var restart: (() -> Void)?

    /// The control channel up, and the settings' ops on it: "subscribe" (Settings opening: the settings now, and
    /// every change after), "ask" (the settings now), "patch" (a change).
    /// Set by the app: the swap setting changed in the window (on or off).
    public static var onSwapChanged: ((Bool) -> Void)?

    /// The last ordinary app in front, apart from TurnOver and its Settings: what the window's per-app verbosity
    /// list is for (27 Oct 2026).
    private static var frontApp: (bundle: String, name: String)?
    private static var frontObserver: NSObjectProtocol?

    public static func start() {
        guard !started else { return }
        started = true
        frontObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.activationPolicy == .regular,
                  let b = app.bundleIdentifier, !b.hasPrefix("com.turnover.") else { return }
            let name = app.localizedName ?? b
            // Only while the Settings window is running is the state sent: encoding it all on every app switch was
            // too much for nothing (a code review, 27 Oct 2026).
            let windowOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.turnover.settings").isEmpty
            MainActor.assumeIsolated {
                frontApp = (b, name)
                if windowOpen { sendState() }   // the window shows the app's name in its "For" list
            }
        }
        let server = ControlServer.shared
        server.log = { Log.info($0) }
        server.start(path: AppPaths.file("control.sock").path)
        // A window connecting, or asking (it does as it comes to the front), gets the voices as they are now; a change
        // made in the window is answered from the list kept since.
        server.handlers["subscribe"] = { _, reply in Log.info("settings app: connected"); languagesState = nil; sendState(to: reply) }
        server.handlers["ask"] = { _, reply in languagesState = nil; sendState(to: reply) }
        server.handlers["patch"] = { message, _ in if let json = message["json"] as? String { apply(json) } }
        // Export: the settings file's JSON to the window, which writes it where its save panel said (exportSettings).
        server.handlers["exportSettings"] = { _, reply in reply(["op": "exportSettings", "json": exportJSON()]) }
    }

    /// The voices for other languages, as the window shows them: kept, not made again for every change. Made again
    /// it asked the system for every voice once per language, about 1.6 s on the main thread after each switch was
    /// pressed, so the switch's new state was said late and the next key waited (25 Oct 2026). Cleared when a window
    /// connects or asks, and when a voice changes.
    private static var languagesState: [[String: Any]]?
    private static func otherLanguagesState() -> [[String: Any]] {
        if let languagesState { return languagesState }
        let all = AVSpeechSynthesisVoice.speechVoices()
        let made: [[String: Any]] = Languages.otherLanguages(from: all).map { language in
            let voices = Languages.voices(for: language.code, from: all).map { ["id": $0.identifier, "name": $0.name, "language": $0.language] }
            return ["code": language.code, "name": language.name, "voices": voices]
        }
        languagesState = made
        return made
    }

    /// The settings as they are now, and the ones kept outside the file, for the app to show: to the one that asked,
    /// or to every open Settings window.
    static func sendState(to reply: (@Sendable ([String: Any]) -> Void)? = nil) {
        guard let data = try? JSONEncoder().encode(config),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let section = pendingSection, reply != nil {
            dict["_showSection"] = section
            pendingSection = nil
        }
        dict["_effectiveSounds"] = config.general.effectiveSounds
        dict["_kokoroAvailable"] = KokoroVoice.available
        dict["_naturalDownloaded"] = KokoroVoice.downloaded
        dict["_naturalDownloading"] = KokoroVoice.downloading
        dict["_naturalRemovable"] = KokoroVoice.removable
        dict["_kokoroMode"] = KokoroVoice.mode
        dict["_kokoroVoice"] = KokoroVoice.voice
        dict["_kokoroVoices"] = KokoroVoice.voices.map { ["id": $0, "name": KokoroVoice.displayName($0)] }
        dict["_speechVoice"] = KokoroVoice.speechVoiceID
        dict["_naturalVoiceEntries"] = KokoroVoice.voiceEntries.map { ["id": $0.id, "name": $0.name] }
        dict["_coexist"] = Coexist.wouldBeOn
        dict["_outputDevices"] = SpeechPlayer.outputDevices().map { ["uid": $0.uid, "name": $0.name] }
        dict["_speechPortApps"] = SpeechPort.shared.appDecisions.map { ["id": $0.id, "name": $0.name, "allowed": $0.allowed] }
        dict["_otherLanguages"] = otherLanguagesState()
        dict["_soundList"] = SoundChoices.all.map { ["id": $0.id, "name": $0.title] }
        // Braille: the kinds of display macOS has drivers for, the one connected, and every table by language.
        dict["_brailleDrivers"] = BrailleSettingsLists.drivers
        dict["_brailleDisplay"] = Braille.display.map { "\($0.name), \($0.cellCount) cells" } ?? ""
        dict["_brailleTables"] = BrailleSettingsLists.tables
        dict["_brailleOutputTable"] = BrailleOutput.outputTable ?? ""
        dict["_brailleLanguages"] = BrailleSettingsLists.languages
        if let auto = autoUpdateChecks?.get() { dict["_autoUpdateChecks"] = auto }
        if let m = portableMessage { dict["_portableMessage"] = m }
        // The app the window's "For this app" means: the last ordinary app in front that isn't TurnOver's own.
        if let f = frontApp { dict["_frontApp"] = ["bundle": f.bundle, "name": f.name] }
        guard let out = try? JSONSerialization.data(withJSONObject: dict), let s = String(data: out, encoding: .utf8) else { return }
        if let reply { reply(["op": "state", "json": s]) } else { ControlServer.shared.broadcast(["op": "state", "json": s]) }
    }

    /// A sample once a slider has stopped: one at each step of a drag was a run of cut-off pieces (a review, 2 Nov 2026).
    private static var previewGeneration = 0
    private static func previewSoon(_ text: String) {
        previewGeneration += 1
        let g = previewGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if g == previewGeneration { Speech.speakMessage(text) } }
    }

    static func apply(_ json: String) {
        guard let data = json.data(using: .utf8), let patch = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // Outside the file.
        if let m = patch["_kokoroMode"] as? String { KokoroVoice.mode = ["off", "everything"].contains(m) ? m : "reading" }
        // The Voice list, Mac voices and natural ones alike: each voice with its own rate, volume and EQ.
        if let v = patch["_speechVoice"] as? String {
            VoiceTunings.switchTo(v)
            if v.hasPrefix("external:") { KokoroVoice.preview(KokoroVoice.voice) }
        }
        if let v = patch["_kokoroVoice"] as? String, KokoroVoice.voices.contains(v) {
            KokoroVoice.voice = v
            if KokoroVoice.mode == "off" { KokoroVoice.mode = "reading" }
            KokoroVoice.preview(v)
        }

        if patch["_downloadNaturalVoices"] as? Bool == true { KokoroVoice.download(); sendState() }
        if patch["_removeNaturalVoices"] as? Bool == true { KokoroVoice.remove() }
        if patch["_restartSteam"] as? Bool == true { Games.restartSteam() }
        // Sounds one by one (SoundChoices): hear one, give it a file of your own, or go back to TurnOver's.
        if let id = patch["_soundPreview"] as? String { SoundChoices.preview(id) }
        if let c = patch["_soundCustom"] as? [String: Any], let id = c["id"] as? String, let path = c["path"] as? String {
            if SoundChoices.setCustom(id, from: path) { SoundChoices.preview(id) }
            else { Speech.speakMessage(String(localized: "That file isn't a sound TurnOver can play", comment: "Spoken message: a file chosen for a sound in Settings won't play")) }
        }
        if let id = patch["_soundClear"] as? String { SoundChoices.clearCustom(id); SoundChoices.preview(id) }
        if let a = patch["_speechPortAllowed"] as? [String: Any], let id = a["id"] as? String, let on = a["allowed"] as? Bool { SpeechPort.shared.setAllowed(id, on) }
        if let on = patch["_autoUpdateChecks"] as? Bool { autoUpdateChecks?.set(on) }
        if let done = patch["_settingsExported"] as? [String: Any] { exported(done); sendState(); return }
        if let file = patch["_importSettings"] as? [String: Any] {
            importSettings(json: file["json"] as? String ?? "", name: file["name"] as? String ?? ""); sendState(); return
        }
        if let on = patch["_coexist"] as? Bool, on != Coexist.wouldBeOn {
            UserDefaults.standard.set(on, forKey: "coexist")
            Speech.speakMessage(on ? String(localized: "CoExist on. TurnOver restarts.", comment: "Spoken message") : String(localized: "CoExist off. TurnOver restarts.", comment: "Spoken message"))
            Log.info("settings app: CoExist \(on ? "on" : "off"); restarting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { (restart ?? TurnOverMenu.shared.relaunch)?() }
            return
        }
        // The file's settings: merged section by section, then read back through Config, so a value of the wrong kind
        // is simply left as it was.
        let filePatch = patch.filter { !$0.key.hasPrefix("_") }
        if !filePatch.isEmpty {
            guard let next = merged(filePatch, over: config) else {
                Log.warning("settings app: a change TurnOver couldn't read; nothing changed"); sendState(); return
            }
            adopt(next, what: filePatch.keys.sorted().joined(separator: ", "))
        }
        sendState()
    }

    /// Settings with a patch's sections merged over them, key by key within each section, then read back through
    /// Config, so a value of the wrong kind is left as it was. Nil when that fails. Pure.
    /// A window's change and an imported file both come through here: an import replaced every setting, and the
    /// sections a file lacked went back to their defaults (a review, 14 Nov 2026).
    public static func merged(_ patch: [String: Any], over base: Config) -> Config? {
        guard let current = try? JSONEncoder().encode(base),
              var dict = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] else { return nil }
        for (section, value) in patch {
            if var existing = dict[section] as? [String: Any], let changes = value as? [String: Any] {
                for (k, v) in changes { existing[k] = v }
                dict[section] = existing
            } else { dict[section] = value }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    /// New settings in effect and saved, with the hooks the menu's own items run: a change from the window, or a
    /// whole file imported (14 Nov 2026; the body was apply's own until then, hence its indent).
    private static func adopt(_ next: Config, what: String) {
        do {
            let before = config
            config = next
            config.save()
            SettingsProfiles.applyLive()
            KeySettings.refresh()
            TurnOverMenu.shared.onGeneralChanged?()
            // The hooks the menu's own items run (the Settings window is the menu's equal since 21 Oct 2026).
            if before.general.screenCurtain != next.general.screenCurtain { TurnOverMenu.shared.onScreenCurtainChanged?() }
            if before.speech.outputDevice != next.speech.outputDevice {
                Speech.player.outputDeviceUID = next.speech.outputDevice.isEmpty ? nil : next.speech.outputDevice
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Speech.speakMessage(String(localized: "Speech on \(Speech.player.outputDescription)", comment: "Speech moved to an audio device: %@ is the device")) }
            }
            if before.general.keyboardStyle != next.general.keyboardStyle { GlobalCommands.setKeyboardStyle(next.general.style) }
            if before.braille.bluetooth != next.braille.bluetooth, next.braille.bluetooth { BrailleDisplays.shared.lookNow() }
            if before.braille.display != next.braille.display { BrailleDisplays.shared.displayChoiceChanged() }
            if before.braille.languages != next.braille.languages || before.braille.languageTables != next.braille.languageTables
                || before.braille.autoLanguageSwitching != next.braille.autoLanguageSwitching { BrailleLanguages.forget() }
            if before.speech.detectLanguages != next.speech.detectLanguages { Languages.lastRecognised = nil }
            Braille.settingsChanged()
            if before.applications.perAppReaders != next.applications.perAppReaders { TurnOverMenu.shared.leadModeChanged?() }
            if before.applications.swapWithVoiceOver != next.applications.swapWithVoiceOver { onSwapChanged?(next.applications.swapWithVoiceOver) }
            // Steam's switches from the window do what the menu's do.
            if before.games.readBigPicture != next.games.readBigPicture { Games.restartBigPicture() }
            MouseTracking.refresh()   // the pointer watched while a mouse setting is on, and only then
            if before.vision != next.vision { VisionAids.apply() }
            // Pictures in or out of the page's copy: read again at the next key (VoiceOver's "Navigate images").
            if before.virtualBuffers.navigateImages != next.virtualBuffers.navigateImages { API.focusTreeInterceptor?.buffer.isDirty = true }
            // The EQ heard as it is set: a short sample once the slider stops.
            for (name, was, now) in [("Bass", before.speech.bass, next.speech.bass), ("Middle", before.speech.middle, next.speech.middle), ("Treble", before.speech.treble, next.speech.treble)] where was != now {
                previewSoon(String(localized: "\(Self.eqName(name)) \(String(Int(now))). The harbour opens at nine.", comment: "The EQ changed: %1$@ is bass, middle or treble, %2$@ the decibels"))
            }
            // A language's voice, rate, pitch or volume heard as it is set, in that language (the languages table).
            let changedLanguages = Set([(before.speech.languageVoices, next.speech.languageVoices)].flatMap { a, b in Set(a.keys).union(b.keys).filter { a[$0] != b[$0] } })
                .union(Set(before.speech.languageRates.keys).union(next.speech.languageRates.keys).filter { before.speech.languageRates[$0] != next.speech.languageRates[$0] })
                .union(Set(before.speech.languagePitches.keys).union(next.speech.languagePitches.keys).filter { before.speech.languagePitches[$0] != next.speech.languagePitches[$0] })
                .union(Set(before.speech.languageVolumes.keys).union(next.speech.languageVolumes.keys).filter { before.speech.languageVolumes[$0] != next.speech.languageVolumes[$0] })
            if changedLanguages.count == 1, let code = changedLanguages.first {
                Languages.forget()
                previewGeneration += 1
                let g = previewGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard g == previewGeneration else { return }
                    Speech.cancel(); Speech.enqueue(Languages.sample(code), language: code)
                }
            }
            let voiceChanged = before.speech.voice != next.speech.voice
            let languageVoicesChanged = before.speech.languageVoices != next.speech.languageVoices
            if voiceChanged || languageVoicesChanged { Languages.forget(); languagesState = nil }
            // The key layer where VoiceOver reads follows its own setting too (the style's change starts or stops it above).
            if before.general.keysWhereVoiceOverReads != next.general.keysWhereVoiceOverReads { GlobalCommands.onKeyboardStyleChanged?() }
            if before.general.logLevel != next.general.logLevel { applyLogLevel() }
            Log.info("settings app: \(what) changed")
        }
    }

    // NVDA's General settings and VoiceOver's portable preferences (14 Nov 2026).
    /// The log's level from the settings. (Log.level is read unlocked on every thread, as it always has been: a
    /// one-word enum written here on main; a line logged at the old level during the switch does no harm.)
    public static func applyLogLevel() {
        Log.level = Log.level(named: config.general.logLevel) ?? .io
    }

    /// Sparkle's daily check, which lives in the app's updater, not the settings file: set by the app.
    public static var autoUpdateChecks: (get: () -> Bool, set: (Bool) -> Void)?

    /// What the last export or import came to, for the window to show (and said as it happens).
    private static var portableMessage: String?
    private static func tell(_ message: String) {
        portableMessage = message
        Speech.speakMessage(message)
    }

    // Portable preferences (14 Nov 2026). The Settings window reads and writes the file: it chose it, and macOS gave it
    // access. TurnOver reading it on main could wait on a Files and Folders prompt (Documents, Desktop, Downloads), and
    // the reader froze with it (a review, 14 Nov 2026). TurnOver only hands over its JSON, or checks and adopts some.

    /// settings.json as it is on disk now (the normal settings, with a profile on), for the window to write.
    static func exportJSON() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = (try? Data(contentsOf: Config.url)) ?? (try? encoder.encode(config)) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The window wrote the export, or could not.
    static func exported(_ result: [String: Any]) {
        let name = result["name"] as? String ?? ""
        if let error = result["error"] as? String {
            Log.warning("settings: export failed: \(error)")
            tell(String(localized: "Settings could not be exported: \(error)", comment: "Export failed: %@ is why"))
        } else {
            Log.info("settings: exported to \(name)")
            tell(String(localized: "Settings exported to \(name)", comment: "Settings exported: %@ is the file's name"))
        }
    }

    /// Settings from a file someone exported, as the window read it, checked first: they must be TurnOver's settings
    /// (a JSON object with at least one of its sections) that decode. Anything else leaves the settings as they are and
    /// says why. A settings profile that is on is switched off first, so the import goes into the normal settings, not
    /// into the profile (a review, 14 Nov 2026).
    static func importSettings(json: String, name: String) {
        let data = Data(json.utf8)
        // Checked first, so a file refused leaves a profile on; then merged over the normal settings.
        var result = Self.portableSettings(from: data, over: config)
        if case .success = result { SettingsProfiles.deactivate(); result = Self.portableSettings(from: data, over: config) }
        switch result {
        case .success(let imported):
            adopt(imported.config, what: "settings imported from \(name),")
            var message = String(localized: "Settings imported from \(name)", comment: "Settings imported: %@ is the file's name")
            if imported.droppedKeys > 0 {
                Log.info("settings: \(imported.droppedKeys) imported keys that open apps, scripts or Shortcuts left out")
                message += ". " + String(localized: "Keys that open an app, a script or a Shortcut were left out: give them again in the TurnOver menu, Settings, Keyboard shortcuts, My own keys.", comment: "Settings imported without the keys that run things on this Mac")
            }
            tell(message)
        case .failure(let why):
            Log.warning("settings: import of \(name) refused: \(why.message)")
            tell(String(localized: "Settings not imported: \(why.message)", comment: "Import refused: %@ is why"))
        }
    }

    public struct ImportError: Error, Equatable { public let message: String }
    /// The sections an imported file may hold (Config's).
    nonisolated static let portableSections: Set<String> = ["general", "speech", "keyboard", "editableText", "presentation", "virtualBuffers", "applications", "documentFormatting", "braille", "recognition", "games", "sounds", "mouse", "apps", "vision", "signal"]
    /// The keys that would run something on this Mac: a file, a Shortcut or an app, by path or identifier.
    nonisolated static let localTargetPrefixes = ["file:", "shortcut:", "app:"]

    /// The checks an imported file must pass, and the settings it comes to over `base`: its sections merged over the
    /// current ones (a file with only some sections changes only those), speech kept audible, and the user's keys that
    /// would run a file, a Shortcut or an app left out (a file from someone else could otherwise run a script of its
    /// choosing at a key press; the ones set here are kept). Pure.
    public static func portableSettings(from data: Data, over base: Config = Config()) -> Result<(config: Config, droppedKeys: Int), ImportError> {
        guard !data.isEmpty, var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(ImportError(message: String(localized: "the file is not a TurnOver settings file", comment: "Why settings were not imported")))
        }
        guard !portableSections.isDisjoint(with: object.keys) else {
            return .failure(ImportError(message: String(localized: "the file has none of TurnOver's settings in it", comment: "Why settings were not imported")))
        }
        object = object.filter { portableSections.contains($0.key) }
        var dropped = 0
        if var keyboard = object["keyboard"] as? [String: Any], let keys = keyboard["userGestures"] as? [String: Any] {
            var kept: [String: Any] = [:]
            for (id, target) in keys {
                if let t = target as? String, localTargetPrefixes.contains(where: { t.hasPrefix($0) }) { dropped += 1 } else { kept[id] = target }
            }
            // This Mac's own keys all stay, unless the file gives a key something else (a review: the user's own
            // remappings were replaced wholesale).
            for (id, target) in base.keyboard.userGestures where kept[id] == nil { kept[id] = target }
            keyboard["userGestures"] = kept
            object["keyboard"] = keyboard
        }
        guard var config = merged(object, over: base) else {
            return .failure(ImportError(message: String(localized: "the file could not be read as TurnOver's settings", comment: "Why settings were not imported")))
        }
        config.speech.keepAudible()
        // What belongs to this Mac, not to the reader's preferences, stays as it is: the braille display chosen and
        // Bluetooth (a file from another Mac with "none" or another driver closed a braille-only user's display), the
        // speech output device, and which reader leads where (an import could leave TurnOver quiet for a VoiceOver
        // that isn't on). A review, 14 Nov 2026.
        config.braille.display = base.braille.display; config.braille.bluetooth = base.braille.bluetooth
        config.speech.outputDevice = base.speech.outputDevice
        config.applications.perAppReaders = base.applications.perAppReaders; config.applications.leadMode = base.applications.leadMode
        config.applications.swapWithVoiceOver = base.applications.swapWithVoiceOver; config.applications.automaticHandOver = base.applications.automaticHandOver
        config.applications.leadBundles = base.applications.leadBundles; config.applications.voiceOverBundles = base.applications.voiceOverBundles
        config.applications.leadEverywhereElse = base.applications.leadEverywhereElse; config.applications.directApps = base.applications.directApps
        return .success((config, dropped))
    }

    /// The section the Settings window is asked to show when it next connects: set by `open(section:)`, sent once
    /// with the state, and forgotten after five seconds if no window asked.
    private static var pendingSection: String?

    /// Opens TurnOver Settings (inside TurnOver.app), at a section by its sidebar title when one is given. A window
    /// already open is told the section over the control channel; a new one is told with its first state.
    public static func open(section: String? = nil) {
        if let section {
            pendingSection = section
            ControlServer.shared.broadcast(["op": "show", "section": section])
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if pendingSection == section { pendingSection = nil } }
        }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/TurnOver Settings.app")
        guard FileManager.default.fileExists(atPath: url.path) else { Speech.speakMessage(String(localized: "TurnOver Settings isn't in this build", comment: "Spoken message")); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.warning("settings app: couldn't open: \(error)") }
        }
    }
}
