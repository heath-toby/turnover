// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver Settings (18 Oct 2026): TurnOver's settings in an ordinary window, sections down the side, ordinary
// controls. It lives inside TurnOver.app and is read by TurnOver like any app. It never writes the settings file:
// each change goes to TurnOver as a patch (SettingsBridge), and TurnOver answers with the settings as they now are.
// Through TurnOver's control channel, which only programs signed by TurnOver's developer may use (TurnOverControl).
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import TurnOverControl
import TurnOverVoices

@MainActor
final class Model: ObservableObject {
    @Published var state: [String: Any] = [:]
    @Published var connected = false
    /// TurnOver closed the connection at once, five times running: this window is an old build's, left open across an
    /// install, and TurnOver turns it away (issue 77: it knocked every two seconds until it was quit by hand).
    @Published var turnedAway = false
    private var refusals = 0
    private var opened = Date()
    /// A section TurnOver asked the window to show (a settings key pressed): with the first state, or on its own
    /// while the window is open. The sidebar follows it and then clears it.
    @Published var requestedSection: Pane?
    private var connection: ControlClient.Connection?

    init() {
        connect()
    }

    /// Connected to TurnOver and listening for its settings; tried again every two seconds until TurnOver is there,
    /// and again if TurnOver restarts.
    private func connect() {
        opened = Date()
        connection = ControlClient.Connection(received: { [weak self] message in
            self?.refusals = 0
            if message["op"] as? String == "show", let name = message["section"] as? String {
                self?.requestedSection = Pane(rawValue: name)
                return
            }
            guard message["op"] as? String == "state", let json = message["json"] as? String, let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            self?.state = dict; self?.connected = true
            if let name = dict["_showSection"] as? String { self?.requestedSection = Pane(rawValue: name) }
        }, ended: { [weak self] in
            guard let self else { return }
            if !connected, Date().timeIntervalSince(opened) < 1 { refusals += 1 }
            connected = false; connection = nil
            retry()
        })
        if let connection { connection.send(["op": "subscribe"]) } else { retry() }
    }

    private func retry() {
        guard refusals < 5 else { turnedAway = true; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.connection == nil else { return }
            self.connect()
        }
    }

    func ask() { connection?.send(["op": "ask"]) }

    func get(_ section: String, _ key: String) -> Any? { (state[section] as? [String: Any])?[key] }
    func special(_ key: String) -> Any? { state[key] }

    func set(_ section: String, _ key: String, _ value: Any) {
        var s = state[section] as? [String: Any] ?? [:]; s[key] = value; state[section] = s   // shown at once; TurnOver confirms
        send([section: [key: value]])
    }
    func setSpecial(_ key: String, _ value: Any) { state[key] = value; send([key: value]) }

    private func send(_ patch: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: patch), let s = String(data: data, encoding: .utf8) else { return }
        connection?.send(["op": "patch", "json": s])
    }

    // Bindings onto the settings.
    func bool(_ section: String, _ key: String) -> Binding<Bool> {
        Binding(get: { self.get(section, key) as? Bool ?? false }, set: { self.set(section, key, $0) })
    }
    func string(_ section: String, _ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { self.get(section, key) as? String ?? fallback }, set: { self.set(section, key, $0) })
    }
    func int(_ section: String, _ key: String) -> Binding<Int> {
        Binding(get: { (self.get(section, key) as? NSNumber)?.intValue ?? 0 }, set: { self.set(section, key, $0) })
    }
    /// A 0–1 value shown as 0–100 (rate, pitch).
    func percent(_ section: String, _ key: String) -> Binding<Double> {
        Binding(get: { ((self.get(section, key) as? NSNumber)?.doubleValue ?? 0.5) * 100 }, set: { self.set(section, key, ($0 / 100 * 100).rounded() / 100) })
    }
    func number(_ section: String, _ key: String) -> Binding<Double> {
        Binding(get: { (self.get(section, key) as? NSNumber)?.doubleValue ?? 0 }, set: { self.set(section, key, Int($0.rounded())) })
    }
}

enum Pane: String, CaseIterable, Identifiable {
    // NVDA's order, with TurnOver's own at the end: every setting the menu offered lives here since 21 Oct 2026.
    case general = "General", speech = "Speech", sounds = "Sounds", braille = "Braille", vision = "Vision", keyboard = "Keyboard", mouse = "Mouse", items = "Item details", webPages = "Web pages", documents = "Documents",
         recognition = "Screen recognition", otherApps = "Other apps' speech", readers = "Screen reader behaviour"
    var id: String { rawValue }
    /// As the sidebar shows it. (The raw value stays English: TurnOver asks for a section by it.)
    var title: String {
        switch self {
        case .general: return String(localized: "General", comment: "A section of the Settings window")
        case .speech: return String(localized: "Speech", comment: "A section of the Settings window")
        case .sounds: return String(localized: "Sounds", comment: "A section of the Settings window")
        case .braille: return String(localized: "Braille", comment: "A section of the Settings window")
        case .vision: return String(localized: "Vision", comment: "A section of the Settings window")
        case .keyboard: return String(localized: "Keyboard", comment: "A section of the Settings window")
        case .mouse: return String(localized: "Mouse", comment: "A section of the Settings window")
        case .items: return String(localized: "Item details", comment: "A section of the Settings window")
        case .webPages: return String(localized: "Web pages", comment: "A section of the Settings window")
        case .documents: return String(localized: "Documents", comment: "A section of the Settings window")
        case .recognition: return String(localized: "Screen recognition", comment: "A section of the Settings window")
        case .otherApps: return String(localized: "Other apps' speech", comment: "A section of the Settings window")
        case .readers: return String(localized: "Screen reader behaviour", comment: "A section of the Settings window")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var section: Pane? = .general
    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $section) { s in Text(s.title).tag(s) }
                .navigationSplitViewColumnWidth(190)
                .accessibilityLabel("Settings sections")
        } detail: {
            if model.turnedAway {
                Text("TurnOver turned this window away: it was probably updated while the window was open. Quit Settings and open it again from the TurnOver menu.").padding()
            } else if !model.connected {
                Text("Waiting for TurnOver. Start it with Command Control Period.").padding()
            } else {
                switch section ?? .general {
                case .general: GeneralView()
                case .speech: SpeechView()
                case .sounds: SoundsView()
                case .braille: BrailleView()
                case .vision: VisionView()
                case .keyboard: KeyboardView()
                case .mouse: MouseView()
                case .items: ItemsView()
                case .webPages: WebPagesView()
                case .documents: DocumentsView()
                case .recognition: RecognitionView()
                case .otherApps: OtherAppsView()
                case .readers: ReadersView()
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onReceive(model.$requestedSection) { requested in
            guard let requested else { return }
            section = requested
            model.requestedSection = nil
        }
    }
}

/// The voices on the Mac, listed once and again each time the window comes to the front: listing and sorting them on
/// every redraw made the window slow to answer accessibility questions, and the arrow keys in the sidebar waited half
/// a second (22 Oct 2026). A voice installed or a language added while the window is open shows up on the next return.
@MainActor
final class VoiceLists: ObservableObject {
    static let shared = VoiceLists()
    @Published private(set) var all: [AVSpeechSynthesisVoice] = []
    @Published private(set) var offered: [AVSpeechSynthesisVoice] = []
    @Published private(set) var rotorCandidates: [AVSpeechSynthesisVoice] = []
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// A voice's label in the picker, made once per refresh rather than on every redraw.
    private var labels: [String: String] = [:]
    func label(for voice: AVSpeechSynthesisVoice) -> String { labels[voice.identifier] ?? voice.name }

    /// The tidy list's languages, in its order, each with its voices: the Voice list's sections.
    @Published private(set) var byLanguage: [(name: String, voices: [AVSpeechSynthesisVoice])] = []

    func refresh() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        all = voices
        let byID = Dictionary(voices.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        // The tidy list (TurnOverVoices, the order TurnOver's speech settings ring uses too): your languages in your
        // order, best quality first, without Apple's novelty voices (Oliver, 2 Nov 2026: "a big list of shit nonsense
        // voices that apple like to ship") or a second copy of the same voice. A voice already chosen from outside
        // the list stays selectable (SpeechView.voices).
        let tidy = VoiceOrder.tidy(voices.map(VoiceEntry.init), preferred: Locale.preferredLanguages)
        offered = tidy.compactMap { byID[$0.id] }
        rotorCandidates = offered
        var sections: [(name: String, voices: [AVSpeechSynthesisVoice])] = []
        for v in offered {
            let language = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
            if sections.last?.name == language { sections[sections.count - 1].voices.append(v) } else { sections.append((language, [v])) }
        }
        byLanguage = sections
        var made: [String: String] = [:]
        for v in voices {
            let name = VoiceOrder.displayName(VoiceEntry(v))
            let language = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
            made[v.identifier] = v.quality == .premium ? String(localized: "\(name), \(language), premium", comment: "A voice: its name, language and quality")
                : v.quality == .enhanced ? String(localized: "\(name), \(language), enhanced", comment: "A voice: its name, language and quality") : "\(name), \(language)"
        }
        labels = made
    }
}

struct SpeechView: View {
    @EnvironmentObject var model: Model
    @ObservedObject private var voiceLists = VoiceLists.shared
    /// The voices offered, listed once (VoiceLists); a voice set earlier from outside the list stays selectable.
    private var voices: [AVSpeechSynthesisVoice] {
        let current = model.get("speech", "voice") as? String ?? ""
        if voiceLists.offered.contains(where: { $0.identifier == current }) || current.isEmpty { return voiceLists.offered }
        let extra = voiceLists.all.filter { $0.identifier == current }
        return voiceLists.offered + extra
    }
    @State private var showRotor = false
    /// One voice's tick in the rotor's list, named outright: SwiftUI left such switches nameless here (2 Nov 2026).
    private func rotorToggle(_ id: String, _ name: String) -> some View {
        Toggle(name, isOn: Binding(
            get: { rotorChosen.contains(id) },
            set: { on in
                var list = rotorChosen.filter { $0 != id }
                if on { list.append(id) }
                model.set("speech", "rotorVoices", list)
            }))
        .accessibilityLabel(name)
    }
    /// The voice chosen above, in the rotor or not, without Tabbing through every voice's switch (Oliver, 2 Nov 2026:
    /// "the menu and selection isn't great"). None ticked is every voice: so switching one off when none or only it is
    /// ticked ticks all the others, and all of them ticked is none.
    private func inRotor(_ id: String) -> some View {
        let title = String(localized: "In the rotor", comment: "A switch in Speech settings, under Voice: the voice chosen there is one VO-Command-Shift steps through")
        return Toggle(title, isOn: Binding(
            get: { rotorChosen.isEmpty || rotorChosen.contains(id) },
            set: { on in
                let all = rotorAll
                var list = rotorChosen.isEmpty ? all : rotorChosen
                list.removeAll { $0 == id }
                if on { list.append(id) }
                if list.isEmpty { list = all.filter { $0 != id } }
                if !all.isEmpty, Set(all).isSubset(of: list) { list = [] }
                model.set("speech", "rotorVoices", list)
            }))
        .accessibilityLabel(title)
    }
    /// The natural voices as entries of the Voice list and the rotor ("external:…"), named by TurnOver.
    private var naturalEntries: [(id: String, name: String)] {
        ((model.special("_naturalVoiceEntries") as? [[String: Any]]) ?? []).compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id, name)
        }
    }
    /// The natural voices this Mac has (Phonon's), named by TurnOver.
    private var natural: [(id: String, name: String)] {
        ((model.special("_kokoroVoices") as? [[String: Any]]) ?? []).compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id, name)
        }
    }
    /// An EQ slider's name: the labels come from a list, so SwiftUI does not put them in the catalog by itself
    /// (a tester heard "Treble" under a Russian interface, 8 Nov 2026).
    private func eqName(_ name: String) -> String {
        switch name {
        case "Bass": return String(localized: "Bass", comment: "An equalizer slider: the low frequencies")
        case "Middle": return String(localized: "Middle", comment: "An equalizer slider: the middle frequencies")
        case "Treble": return String(localized: "Treble", comment: "An equalizer slider: the high frequencies")
        default: return name
        }
    }
    private var rotorChosen: [String] { (model.state["speech"] as? [String: Any])?["rotorVoices"] as? [String] ?? [] }
    private var rotorCandidates: [AVSpeechSynthesisVoice] { voiceLists.rotorCandidates }
    /// Every voice the rotor's list offers, the natural ones first.
    private var rotorAll: [String] { naturalEntries.map(\.id) + rotorCandidates.map(\.identifier) }
    private var outputDevices: [(uid: String, name: String)] {
        ((model.special("_outputDevices") as? [[String: Any]]) ?? []).compactMap { d in
            guard let uid = d["uid"] as? String, let name = d["name"] as? String else { return nil }
            return (uid, name)
        }
    }
    /// The languages with an installed voice other than the main voice's, each with its voices (from the bridge).
    private var otherLanguages: [OtherLanguage] {
        let raw = (model.special("_otherLanguages") as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let code = entry["code"] as? String, let name = entry["name"] as? String else { return nil }
            let voices = ((entry["voices"] as? [[String: Any]]) ?? []).compactMap { voice -> OtherLanguage.Voice? in
                guard let id = voice["id"] as? String, let voiceName = voice["name"] as? String else { return nil }
                return OtherLanguage.Voice(id: id, name: voiceName, language: voice["language"] as? String ?? "")
            }
            return OtherLanguage(code: code, name: name, voices: voices)
        }
    }
    var body: some View {
        Form {
            // The natural voices are in the same list (2 Nov 2026): one chosen speaks everything, and the Mac voice
            // chosen before it stays underneath for other languages and raised capitals.
            Picker("Voice", selection: Binding(
                get: { model.special("_speechVoice") as? String ?? (model.get("speech", "voice") as? String ?? "") },
                set: { v in model.setSpecial("_speechVoice", v) })) {
                // Natural voices and the Mac's apart (2 Nov 2026).
                if !naturalEntries.isEmpty {
                    Section("Natural voices") { ForEach(naturalEntries, id: \.id) { Text($0.name).tag($0.id) } }
                }
                // The Mac's voices by language, yours first, best quality first in each (VoiceOrder); a voice in use
                // from outside the list at the end.
                ForEach(voiceLists.byLanguage, id: \.name) { section in
                    Section(section.name) { ForEach(section.voices, id: \.identifier) { v in Text(voiceLists.label(for: v)).tag(v.identifier) } }
                }
                let others = voices.filter { v in !voiceLists.offered.contains { $0.identifier == v.identifier } }
                if !others.isEmpty {
                    Section("Other voices") { ForEach(others, id: \.identifier) { v in Text(voiceLists.label(for: v)).tag(v.identifier) } }
                }
            }
            // Downloading and removing the natural voices, beside the Voice list they add to (Oliver, 6 Nov 2026: "an
            // option, like in windows, to download natural voices"; "next to voice selection"; "a choice to remove").
            // All 25 at once: the engine they share is most of the size.
            if model.special("_kokoroAvailable") as? Bool == true {
                if model.special("_naturalDownloaded") as? Bool == false {
                    if model.special("_naturalDownloading") as? Bool == true {
                        Text("Downloading the natural voices…")
                    } else {
                        Button("Download natural voices, about 170 MB") { model.setSpecial("_downloadNaturalVoices", true) }
                            .accessibilityHint("25 English voices made on your Mac. They download once, from Hugging Face; nothing you read or type leaves your Mac.")
                    }
                } else if model.special("_naturalRemovable") as? Bool == true {
                    Button("Remove natural voices") { model.setSpecial("_removeNaturalVoices", true) }
                        .accessibilityHint("Deletes the downloaded natural voices, about 170 MB, and goes back to your Mac voice.")
                }
            }
            let chosenVoice = model.special("_speechVoice") as? String ?? (model.get("speech", "voice") as? String ?? "")
            // Not for a voice the list doesn't offer (another language's): it couldn't be switched off.
            if rotorAll.contains(chosenVoice) { inRotor(chosenVoice) }
            Slider(value: model.percent("speech", "rate"), in: 10...100, step: 5) { Text("Rate") }
                .accessibilityValue("\(Int(model.percent("speech", "rate").wrappedValue)) percent")
            Slider(value: model.percent("speech", "pitch"), in: 0...100, step: 5) { Text("Pitch") }
                .accessibilityValue("\(Int(model.percent("speech", "pitch").wrappedValue)) percent")
            Slider(value: model.number("speech", "volume"), in: 10...200, step: 10) { Text("Volume") }
                .accessibilityValue("\(Int(model.number("speech", "volume").wrappedValue)) percent")
            // The EQ, for every voice (2 Nov 2026); each voice keeps its own, with its rate and volume.
            ForEach([("Bass", "bass"), ("Middle", "middle"), ("Treble", "treble")], id: \.1) { name, key in
                let db = model.number("speech", key).wrappedValue
                Slider(value: model.number("speech", key), in: -12...12, step: 1) { Text(eqName(name)) }
                    .accessibilityValue(db == 0 ? "0" : String(localized: "\(String(format: "%+.0f", db)) decibels", comment: "An EQ slider's value"))
            }
            Picker("Punctuation", selection: model.int("speech", "symbolLevel")) {
                Text("None").tag(0); Text("Some").tag(1); Text("Most").tag(2); Text("All").tag(3)
            }
            // VoiceOver's Verbosity, Text options (the settings audit, 14 Nov 2026).
            Picker("Read numbers as", selection: model.string("speech", "readNumbers", "words")) {
                Text("Words").tag("words"); Text("Digits").tag("digits")
            }
            Picker("Repeated punctuation", selection: model.string("speech", "repeatedSymbols", "always")) {
                Text("Each one").tag("always"); Text("With a count, such as 5 dash").tag("count")
            }
            Toggle("Say emoticons such as :-) by name", isOn: model.bool("speech", "nameEmoticons"))
            Picker("When deleting text", selection: model.string("speech", "deletionFeedback", "speak")) {
                Text("Speak it").tag("speak"); Text("Speak it in a lower pitch").tag("pitch"); Text("Play a tone").tag("tone"); Text("Do nothing").tag("nothing")
            }
            Picker("Where speech plays", selection: model.string("speech", "outputDevice", "")) {
                Text("The Mac's default output").tag("")
                ForEach(outputDevices, id: \.uid) { d in Text(d.name).tag(d.uid) }
            }
            // Sections and switches, not fold-outs: SwiftUI's DisclosureGroup offers accessibility no action to open it
            // (measured 2 Nov 2026: pressed, it stayed shut), so its contents couldn't be reached by keyboard at all.
            Section("Capitals") {
                Toggle("Say cap before a capital", isOn: model.bool("speech", "sayCapForCapitals"))
                    .accessibilityLabel("Say cap before a capital")
                Toggle("Play a tone before a capital", isOn: model.bool("speech", "capitalTone"))
                Slider(value: model.number("speech", "capitalPitch"), in: 0...100, step: 10) { Text("Raise the pitch for a capital") }
                    .accessibilityValue(model.number("speech", "capitalPitch").wrappedValue == 0 ? String(localized: "off", comment: "A setting that is off")
                        : String(localized: "\(Int(model.number("speech", "capitalPitch").wrappedValue)) percent", comment: "A slider's value"))
            }
            // The languages table (a tester, 14 Nov 2026): Up and Down go through the languages, Tab goes on to the
            // chosen one's voice, rate, pitch and volume, and whether it is recognised in text. Replaces a picker and a
            // rate per language, every one drawn at once.
            Section(String(localized: "Languages", comment: "A group in Speech settings")) {
                Toggle("Automatic language switching", isOn: model.bool("speech", "autoLanguageSwitching"))
                    .accessibilityHint(String(localized: "Text in another language is read in that language's voice: text marked as one, text in another alphabet, and text recognised as one of the languages ticked below.", comment: "Speech settings"))
                if otherLanguages.isEmpty {
                    Text("No voices for other languages are installed.").font(.caption)
                } else {
                    LanguagesTable(languages: otherLanguages)
                }
            }
            // VoiceOver's Pronunciation tab, NVDA's speech dictionary (the settings audit, 14 Nov 2026): the file
            // TurnOver already reads, pronunciations.txt, edited here.
            Section(String(localized: "Pronunciations", comment: "A group in Speech settings")) { PronunciationsEditor() }
            // Folded away: the list is long by nature (every voice the rotor could step through).
            let rotorTitle = rotorChosen.isEmpty ? String(localized: "Show the voices in the rotor: every voice", comment: "A switch in Speech settings")
                : String(localized: "Show the voices in the rotor: \(String(rotorChosen.count)) chosen", comment: "A switch in Speech settings")
            Toggle(rotorTitle, isOn: $showRotor).accessibilityLabel(rotorTitle)
            if showRotor {
                Section(String(localized: "Natural voices in the rotor", comment: "A group in Speech settings")) {
                    Text(rotorChosen.isEmpty ? String(localized: "None ticked, VO-Command-Shift steps through every voice. Tick the ones you want.", comment: "Speech settings")
                         : String(localized: "\(String(rotorChosen.count)) ticked for VO-Command-Shift.", comment: "Speech settings")).font(.caption)
                    ForEach(naturalEntries, id: \.id) { v in rotorToggle(v.id, v.name) }
                }
                Section(String(localized: "Mac voices in the rotor", comment: "A group in Speech settings")) {
                    ForEach(rotorCandidates, id: \.identifier) { v in
                        rotorToggle(v.identifier, voiceLists.label(for: v))
                    }
                }
            }
            // The natural voice (2 Nov 2026): chosen in Voice above for all speech, or here for say all only; its speed
            // and EQ.
            if model.special("_kokoroAvailable") as? Bool == true {
                let mode = model.special("_kokoroMode") as? String ?? "off"
                if model.special("_naturalDownloaded") as? Bool != false {
                    Section("Natural voice") {
                        if mode == "everything" {
                            Text("The voice above is a natural voice, so it speaks everything, with the rate, volume and EQ above. Other languages and raised capitals keep the Mac voice chosen before it, which also steps in if the natural voice is slow.").font(.caption)
                        } else {
                            Picker("Say all voice", selection: Binding(
                                get: { mode == "reading" ? (model.special("_kokoroVoice") as? String ?? "") : "same" },
                                set: { v in if v == "same" { model.setSpecial("_kokoroMode", "off") } else { model.setSpecial("_kokoroVoice", v); model.setSpecial("_kokoroMode", "reading") } })) {
                                Text("Same as speech").tag("same")
                                ForEach(natural, id: \.id) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Speech")
    }
}

struct OtherLanguage {
    struct Voice { let id: String; let name: String; let language: String }
    let code: String
    let name: String
    let voices: [Voice]
}

/// Words said your way: a list of them, then the word and what to say, Add or change, and Remove. Written to
/// TurnOver's pronunciations.txt, which TurnOver reads again within a second of a change.
struct PronunciationsEditor: View {
    @State private var entries: [(word: String, say: String)] = []
    @State private var selected: Int?
    @State private var word = ""
    @State private var say = ""
    @State private var unreadable = false
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurnOver", isDirectory: true).appendingPathComponent("pronunciations.txt")
    }
    /// The file's lines, or nil if it is there but can't be read (never then written over: a review).
    private func lines() -> [String]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.components(separatedBy: .newlines)
    }
    private static func entry(_ raw: String) -> (word: String, say: String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let eq = line.range(of: "=") else { return nil }
        let w = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
        return w.isEmpty ? nil : (w, line[eq.upperBound...].trimmingCharacters(in: .whitespaces))
    }
    private func load() {
        guard let l = lines() else { unreadable = true; return }
        unreadable = false
        entries = l.compactMap(Self.entry)
    }
    /// Read the file afresh, change it line by line (comments and order kept), and write it back.
    private func change(_ edit: (inout [String]) -> Void) {
        guard var l = lines() else { unreadable = true; return }
        edit(&l)
        while l.last?.isEmpty == true { l.removeLast() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (l.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        load()
    }
    private func same(_ raw: String, _ w: String) -> Bool { Self.entry(raw)?.word.caseInsensitiveCompare(w) == .orderedSame }
    var body: some View {
        Group {
            if unreadable {
                Text("The pronunciations file can't be read, so it isn't changed here.").font(.caption)
            } else if entries.isEmpty {
                Text("No words yet. Type a word and how to say it, then Add.").font(.caption)
            } else {
                List(entries.indices, id: \.self, selection: $selected) { i in
                    Text(String(localized: "\(entries[i].word), said as \(entries[i].say)", comment: "A pronunciation in Speech settings")).tag(i)
                }
                .frame(minHeight: 80, maxHeight: 160)
                .accessibilityLabel(String(localized: "Pronunciations", comment: "The list of pronunciations"))
                .onChange(of: selected) { _, i in if let i, entries.indices.contains(i) { word = entries[i].word; say = entries[i].say } }
            }
            TextField(String(localized: "Word", comment: "A pronunciation's word"), text: $word)
            TextField(String(localized: "Say it as", comment: "A pronunciation's replacement"), text: $say)
            Button(String(localized: "Add or change", comment: "Adds a pronunciation, or changes the one for that word")) {
                let w = word.trimmingCharacters(in: .whitespaces), sy = say.trimmingCharacters(in: .whitespaces)
                guard !w.isEmpty, !w.contains("="), !w.hasPrefix("#") else { return }
                change { l in
                    // The first line for the word changed where it is; any others for it go.
                    if let i = l.firstIndex(where: { same($0, w) }) {
                        l[i] = "\(w) = \(sy)"
                        l = l.enumerated().filter { $0.offset == i || !same($0.element, w) }.map(\.element)
                    } else { l.append("\(w) = \(sy)") }
                }
                word = ""; say = ""; selected = nil
            }
            Button(String(localized: "Remove", comment: "Removes the chosen pronunciation")) {
                let w = selected.flatMap { entries.indices.contains($0) ? entries[$0].word : nil } ?? word.trimmingCharacters(in: .whitespaces)
                guard !w.isEmpty else { return }
                change { l in l.removeAll { same($0, w) } }
                word = ""; say = ""; selected = nil
            }
        }
        .onAppear { load() }
    }
}

/// The languages, one row each, and the chosen row's own settings after it: its voice (Automatic is the best one
/// installed), rate, pitch and volume (the main voice's until changed), and whether text is recognised as it.
struct LanguagesTable: View {
    @EnvironmentObject var model: Model
    let languages: [OtherLanguage]
    @State private var selected: String?
    /// The order the table opened with: a row doesn't jump away as it is changed (a review).
    @State private var frozen: [String] = []

    private func dict(_ key: String) -> [String: Any] { model.get("speech", key) as? [String: Any] ?? [:] }
    private func number(_ key: String, _ code: String) -> Double? { (dict(key)[code] as? NSNumber)?.doubleValue }
    private func main(_ key: String, _ fallback: Double) -> Double { (model.get("speech", key) as? NSNumber)?.doubleValue ?? fallback }
    /// The languages recognised: the list once chosen, else those given anything of their own (Config's rule).
    private var recognised: Set<String> {
        if let list = model.get("speech", "detectLanguages") as? [String] { return Set(list) }
        return Set(dict("languageVoices").keys)
    }
    /// Ticked and configured languages first, then the rest by name.
    private var ordered: [OtherLanguage] {
        let r = recognised
        return languages.filter { r.contains($0.code) } + languages.filter { !r.contains($0.code) }
    }
    private func summary(_ l: OtherLanguage) -> String {
        var parts = [l.name]
        if recognised.contains(l.code) { parts.append(String(localized: "recognised", comment: "A language in the Speech settings' table: text is recognised as it")) }
        let voice = (dict("languageVoices")[l.code] as? String).flatMap { id in l.voices.first { $0.id == id }?.name } ?? l.voices.first.map { String(localized: "\($0.name), automatic", comment: "A language's voice in the table: the best installed") }
        if let voice { parts.append(voice) }
        if let r = number("languageRates", l.code) { parts.append(String(localized: "rate \(Int((r * 100).rounded()))", comment: "A language's rate in the table")) }
        if let p = number("languagePitches", l.code) { parts.append(String(localized: "pitch \(Int((p * 100).rounded()))", comment: "A language's pitch in the table")) }
        if let v = number("languageVolumes", l.code) { parts.append(String(localized: "volume \(Int(v))", comment: "A language's volume in the table")) }
        return parts.joined(separator: ", ")
    }
    /// A value of the language's own, shown as the main voice's until set; `scale` 100 for 0–1 values.
    private func binding(_ key: String, _ code: String, mainKey: String, mainDefault: Double, scale: Double) -> Binding<Double> {
        Binding(get: { (number(key, code) ?? main(mainKey, mainDefault)) * scale }, set: { v in
            var all = dict(key)
            if scale == 100 { all[code] = (v / 100 * 100).rounded() / 100 } else { all[code] = Int(v.rounded()) }
            model.set("speech", key, all)
        })
    }

    var body: some View {
        let byCode = Dictionary(languages.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        let list = frozen.isEmpty ? ordered : frozen.compactMap { byCode[$0] } + languages.filter { !frozen.contains($0.code) }
        List(list, id: \.code, selection: $selected) { l in
            Text(summary(l)).tag(l.code)
        }
        .frame(minHeight: 160, maxHeight: 220)
        .accessibilityLabel(String(localized: "Languages", comment: "The Speech settings' table of languages"))
        .onAppear { if frozen.isEmpty { frozen = ordered.map(\.code) }; if selected == nil { selected = list.first?.code } }
        if let code = selected, let l = languages.first(where: { $0.code == code }) {
            Picker(String(localized: "\(l.name) voice", comment: "A language's voice"), selection: Binding(
                get: { dict("languageVoices")[code] as? String ?? "" },
                set: { v in var all = dict("languageVoices"); if v.isEmpty { all.removeValue(forKey: code) } else { all[code] = v }; model.set("speech", "languageVoices", all) })) {
                Text("Automatic\(l.voices.first.map { ": \($0.name)" } ?? "")").tag("")
                ForEach(l.voices, id: \.id) { voice in Text("\(voice.name), \(voice.language)").tag(voice.id) }
            }
            let rate = binding("languageRates", code, mainKey: "rate", mainDefault: 0.55, scale: 100)
            Slider(value: rate, in: 10...100, step: 5) { Text("\(l.name) rate") }
                .accessibilityValue(number("languageRates", code) == nil ? String(localized: "\(String(Int(rate.wrappedValue))), same as the main voice", comment: "A language's setting, when it is the main voice's") : "\(Int(rate.wrappedValue))")
            let pitch = binding("languagePitches", code, mainKey: "pitch", mainDefault: 0.5, scale: 100)
            Slider(value: pitch, in: 0...100, step: 5) { Text("\(l.name) pitch") }
                .accessibilityValue(number("languagePitches", code) == nil ? String(localized: "\(String(Int(pitch.wrappedValue))), same as the main voice", comment: "A language's setting, when it is the main voice's") : "\(Int(pitch.wrappedValue))")
            let volume = binding("languageVolumes", code, mainKey: "volume", mainDefault: 100, scale: 1)
            Slider(value: volume, in: 10...200, step: 10) { Text("\(l.name) volume") }
                .accessibilityValue(number("languageVolumes", code) == nil ? String(localized: "\(String(Int(volume.wrappedValue))) percent, same as the main voice", comment: "A language's volume, when it is the main voice's") : String(localized: "\(String(Int(volume.wrappedValue))) percent", comment: "A slider's value"))
            Toggle(String(localized: "Recognise \(l.name) in text", comment: "A language's switch: text is recognised as it"), isOn: Binding(
                get: { recognised.contains(code) },
                set: { on in var r = recognised; if on { r.insert(code) } else { r.remove(code) }; model.set("speech", "detectLanguages", r.sorted()) }))
                .accessibilityHint(String(localized: "Text that doesn't say what language it is in is recognised as this language when it plainly is, as VoiceOver's Detect languages does.", comment: "Speech settings"))
            Button(String(localized: "Use the main voice's rate, pitch and volume for \(l.name)", comment: "A button in Speech settings")) {
                for key in ["languageRates", "languagePitches", "languageVolumes"] { var all = dict(key); all.removeValue(forKey: code); model.set("speech", key, all) }
            }
        }
    }
}

/// Language profiles: the languages braille recognises, each ticked, and the table for each ticked one (its own
/// contracted table until one is chosen). The ticked ones first; Done or Escape closes.
struct BrailleLanguageProfiles: View {
    @EnvironmentObject var model: Model
    let done: () -> Void
    @State private var order: [String] = []
    private var all: [[String: Any]] { model.special("_brailleLanguages") as? [[String: Any]] ?? [] }
    private var ticked: [String] { model.get("braille", "languages") as? [String] ?? [] }
    private var tables: [String: String] { model.get("braille", "languageTables") as? [String: String] ?? [:] }
    var body: some View {
        VStack(alignment: .leading) {
            Text("Language profiles").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Braille recognises the languages ticked here. With automatic language switching on, a line in one of them is shown in its table; every other line in the output table.").font(.caption)
            Form {
                // In the order the sheet opened with, so a language doesn't jump away as it is ticked.
                ForEach(order.isEmpty ? all.compactMap { $0["code"] as? String } : order, id: \.self) { code in
                    if let lang = all.first(where: { $0["code"] as? String == code }) { row(lang, code: code) }
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button(String(localized: "Done", comment: "Closes a sheet")) { done() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 480)
        .onExitCommand { done() }
        .onAppear {
            let t = Set(ticked)
            let codes = all.compactMap { $0["code"] as? String }
            order = codes.filter { t.contains($0) } + codes.filter { !t.contains($0) }
        }
    }
    @ViewBuilder private func row(_ lang: [String: Any], code: String) -> some View {
        let name = lang["name"] as? String ?? code
        Toggle(name, isOn: Binding(get: { ticked.contains(code) }, set: { on in
            var list = ticked.filter { $0 != code }
            if on { list.append(code) }
            model.set("braille", "languages", list)
        }))
        if ticked.contains(code) {
            let list = (lang["tables"] as? [[String: String]]) ?? []
            let defaultID = lang["default"] as? String ?? ""
            let defaultName = list.first { $0["id"] == defaultID }?["name"] ?? defaultID
            Picker(String(localized: "\(name) table", comment: "A language's braille table in Language profiles"), selection: Binding(
                get: { tables[code] ?? "" },
                set: { v in var all = tables; if v.isEmpty { all.removeValue(forKey: code) } else { all[code] = v }; model.set("braille", "languageTables", all) })) {
                Text(String(localized: "Automatic: \(defaultName)", comment: "A language's braille table: its own default")).tag("")
                ForEach(list, id: \.self) { t in Text(t["name"] ?? "").tag(t["id"] ?? "") }
            }
        }
    }
}

/// Braille (NVDA's braille settings, with VoiceOver's formatting marks): the display, the tables, what the display
/// shows, the cursor, and panning and routing. TurnOver drives the display through macOS's own drivers, so any
/// display VoiceOver supports works; choosing one kind only looks for that kind (14 Nov 2026).
struct BrailleView: View {
    @EnvironmentObject var model: Model
    private var drivers: [[String: String]] { model.special("_brailleDrivers") as? [[String: String]] ?? [] }
    /// Each table once (the same one can be listed under several languages), languages that end up empty left out.
    private var tables: [(language: String, tables: [(id: String, name: String)])] {
        var seen = Set<String>()
        return (model.special("_brailleTables") as? [[String: Any]] ?? []).compactMap { lang in
            let list = (lang["tables"] as? [[String: String]] ?? []).map { ($0["id"] ?? "", $0["name"] ?? "") }.filter { seen.insert($0.0).inserted }
            return list.isEmpty ? nil : (lang["language"] as? String ?? "", list)
        }
    }
    private var connected: String { model.special("_brailleDisplay") as? String ?? "" }
    private var outputName: String {
        let id = model.special("_brailleOutputTable") as? String ?? ""
        return tables.lazy.flatMap(\.tables).first { $0.id == id }?.name ?? id
    }
    /// Seconds for auto scroll, kept to halves of a second (the file holds a decimal).
    private var autoScroll: Binding<Double> {
        Binding(get: { (model.get("braille", "autoScrollSeconds") as? NSNumber)?.doubleValue ?? 3 }, set: { model.set("braille", "autoScrollSeconds", ($0 * 2).rounded() / 2) })
    }
    @State private var showProfiles = false
    @ViewBuilder private func tablePicker(_ title: String, key: String, automatic: String) -> some View {
        let current = model.get("braille", key) as? String ?? ""
        let all = tables
        Picker(title, selection: model.string("braille", key, "")) {
            Text(automatic).tag("")
            // A table chosen before that this Mac doesn't list: shown by its identifier, not as a blank choice.
            if !current.isEmpty, !all.contains(where: { $0.tables.contains { $0.id == current } }) { Text(current).tag(current) }
            ForEach(Array(all.enumerated()), id: \.offset) { _, lang in
                Section(lang.language) { ForEach(lang.tables, id: \.id) { t in Text(t.name).tag(t.id) } }
            }
        }
    }
    private func shapes() -> some View {
        Group { Text("Dots 7 and 8").tag("78"); Text("Dot 7").tag("7"); Text("Dot 8").tag("8"); Text("All dots").tag("all") }
    }
    var body: some View {
        Form {
            Section("Display") {
                Picker("Braille display", selection: model.string("braille", "display", "auto")) {
                    Text("Automatic").tag("auto")
                    Text("No braille").tag("none")
                    ForEach(drivers, id: \.self) { d in Text(d["name"] ?? "").tag(d["id"] ?? "") }
                }
                Text(connected.isEmpty ? String(localized: "No display connected. A display of the kind chosen is used as soon as it is connected.", comment: "Braille settings: no display") : String(localized: "Connected: \(connected)", comment: "Braille settings: the display in use"))
                Toggle("Look for displays paired over Bluetooth", isOn: model.bool("braille", "bluetooth"))
                Text("A display on USB is always preferred to the same display over Bluetooth.").font(.caption)
            }
            Section("Tables") {
                tablePicker("Output table", key: "table", automatic: String(localized: "Automatic, contracted for your language", comment: "Braille output table choice"))
                tablePicker("Input table", key: "inputTable", automatic: String(localized: "Same as the output table", comment: "Braille input table choice"))
                // Braille language switching (a tester, 14 Nov 2026), in the order asked for: the tables, the switch, then
                // the profiles, which open whether the switch is on or not.
                Toggle("Automatic language switching", isOn: model.bool("braille", "autoLanguageSwitching"))
                    .accessibilityHint(String(localized: "Each line is shown in the table for the language it is in, among the languages ticked in Language profiles.", comment: "Braille settings"))
                Button(String(localized: "Language profiles…", comment: "A button in Braille settings")) { showProfiles = true }
                    .accessibilityHint(String(localized: "Tick the languages braille recognises, and choose a table for each.", comment: "Braille settings"))
                    .sheet(isPresented: $showProfiles) { BrailleLanguageProfiles(done: { showProfiles = false }).environmentObject(model) }
                if !outputName.isEmpty { Text("In use: \(outputName)").font(.caption) }
                Toggle("Show the word at the cursor uncontracted", isOn: model.bool("braille", "expandAtCursor"))
                Toggle("Type in contracted braille, a word at a time", isOn: model.bool("braille", "contractedInput"))
                Picker("Speak braille typing", selection: model.string("braille", "inputEcho", "words")) {
                    Text("Words").tag("words"); Text("Characters").tag("characters"); Text("Characters and words").tag("both"); Text("Off").tag("off")
                }
                Toggle("Ignore chord duration on the braille keyboard", isOn: model.bool("braille", "ignoreChordDuration"))
                Picker("Show bold, italic and underline", selection: model.string("braille", "formattingMarks", "off")) {
                    Text("Off").tag("off"); Text("With the table's own signs").tag("table"); Text("With dots 7 and 8").tag("dots78")
                }
                Text("The table's own signs are the ones braille books use (UEB, the US and UK codes have them; eight-dot tables don't).").font(.caption)
            }
            Section("What the display shows") {
                Picker("Braille mode", selection: model.string("braille", "mode", "followCursors")) {
                    Text("Follow cursors").tag("followCursors"); Text("Display speech output").tag("speechOutput")
                }
                Picker("Tether braille", selection: model.string("braille", "tether", "auto")) {
                    Text("Automatically").tag("auto"); Text("To focus").tag("focus"); Text("To review").tag("review")
                }
                Picker("Focus context presentation", selection: model.string("braille", "focusContext", "changes")) {
                    Text("Fill display for context changes").tag("changes"); Text("Only when scrolling back").tag("scrolling"); Text("Always fill display").tag("always")
                }
                // VoiceOver's Verbosity, Braille (14 Nov 2026): the display's own level, speech unchanged.
                Picker("Braille verbosity", selection: model.string("braille", "verbosity", "speech")) {
                    Text("Same as speech").tag("speech"); Text("High: everything, with help text and position").tag("high")
                    Text("Medium: name, value, kind and states").tag("medium"); Text("Low: name and value only").tag("low")
                }
                Toggle("Read by paragraph", isOn: model.bool("braille", "readByParagraph"))
                Picker("Paragraph start marker", selection: model.string("braille", "paragraphMarker", "none")) {
                    Text("None").tag("none"); Text("Pilcrow (¶)").tag("pilcrow"); Text("Two blank cells").tag("spaces")
                }
                Toggle("Avoid splitting words", isOn: model.bool("braille", "wordWrap"))
                Picker("Show messages", selection: model.string("braille", "showMessages", "timeout")) {
                    Text("For a time").tag("timeout"); Text("Until a key is pressed").tag("indefinitely"); Text("Off").tag("off")
                }
                Stepper(value: model.int("braille", "messageSeconds"), in: 1...20) { Text("Message time: \(model.int("braille", "messageSeconds").wrappedValue) seconds for each display's width") }
            }
            Section("Cursor") {
                Toggle("Show the cursor", isOn: model.bool("braille", "showCursor"))
                Toggle("Blink the cursor", isOn: model.bool("braille", "blinkCursor"))
                Stepper(value: model.int("braille", "blinkRateMs"), in: 100...2000, step: 50) { Text("Blink rate: \(model.int("braille", "blinkRateMs").wrappedValue) milliseconds") }
                Picker("Cursor shape for focus", selection: model.string("braille", "cursorShape", "78")) { shapes() }
                Picker("Cursor shape for review", selection: model.string("braille", "cursorShapeReview", "8")) { shapes() }
                Toggle("Show selection with dots 7 and 8", isOn: model.bool("braille", "showSelection"))
            }
            Section("Panning and routing") {
                Picker("Panning moves the cursor", selection: model.string("braille", "panMovesCaret", "line")) {
                    Text("Line by line").tag("line"); Text("To the text shown").tag("window"); Text("Off").tag("off")
                }
                Text("Panning on to another line moves the caret there, so the arrows carry on from what was read. Tethered to review, panning moves only the review cursor.").font(.caption)
                Toggle("Speak the line when panning to it", isOn: model.bool("braille", "speakWhenPanning"))
                Toggle("Turn pages when panning (Kindle books)", isOn: model.bool("braille", "turnPagesWhenPanning"))
                Toggle("Stop speech while panning", isOn: model.bool("braille", "interruptSpeechWhileScrolling"))
                Toggle("Speak the character when routing the cursor in text", isOn: model.bool("braille", "speakOnRouting"))
                Picker("Move the caret when routing the review cursor", selection: Binding(get: { model.get("braille", "routingMovesCaret") as? String == "always" ? "always" : "never" }, set: { model.set("braille", "routingMovesCaret", $0) })) {
                    Text("Never").tag("never"); Text("Always").tag("always")
                }
                Stepper(value: autoScroll, in: 0.5...20, step: 0.5) { Text("Auto scroll: a display's width every \(String(format: "%.1f", autoScroll.wrappedValue)) seconds") }
            }
        }.formStyle(.grouped).navigationTitle("Braille")
    }
}

struct KeyboardView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Picker("Keyboard style", selection: model.string("general", "keyboardStyle", "mac")) {
                Text("VoiceOver keys").tag("mac"); Text("NVDA keys").tag("windows"); Text("JAWS keys").tag("jaws")
            }
            Toggle("NVDA and JAWS keys where VoiceOver reads too", isOn: model.bool("general", "keysWhereVoiceOverReads"))
            Text("On, Caps Lock is the NVDA key in every app, whichever reader is speaking. Off, VoiceOver's own Caps Lock keys work in the apps VoiceOver reads.").font(.caption)
            Picker("TurnOver key", selection: model.string("general", "bosunKey", "both")) {
                Text("Caps Lock or Control Option").tag("both"); Text("Caps Lock").tag("caps"); Text("Control Option").tag("controlOption")
            }
            Picker("Keyboard layout", selection: model.string("keyboard", "layout", "laptop")) {
                Text("Laptop").tag("laptop"); Text("Desktop, the number pad has its NVDA keys").tag("desktop")
            }
            Section("Typing echo") {
                Picker("Characters", selection: model.int("keyboard", "speakTypedCharacters")) {
                    Text("Off").tag(0); Text("In edit fields").tag(1); Text("Always").tag(2)
                }
                Picker("Words", selection: model.int("keyboard", "speakTypedWords")) {
                    Text("Off").tag(0); Text("In edit fields").tag(1); Text("Always").tag(2)
                }
                Toggle("New line on Return", isOn: model.bool("keyboard", "speakNewLine"))
                Toggle("Caps Lock on and off", isOn: model.bool("presentation", "announceCapsLock"))
                Toggle("Command keys, as you press them", isOn: model.bool("keyboard", "speakCommandKeys"))
            }
            // VoiceOver's modifier announcement and NVDA's keyboard options (14 Nov 2026).
            Section("Keys and speech") {
                Toggle("Say a modifier key's name when it is pressed and let go on its own", isOn: model.bool("keyboard", "announceModifierKeys"))
                Toggle("Typing a character stops speech", isOn: model.bool("keyboard", "interruptSpeechForTypedCharacters"))
                Toggle("Return stops speech", isOn: model.bool("keyboard", "interruptSpeechForEnter"))
                Toggle("Play a sound when a word just typed is misspelt", isOn: model.bool("keyboard", "spellingErrorSoundWhileTyping"))
                Toggle("Line and paragraph keys skim through say all, which carries on", isOn: model.bool("keyboard", "allowSkimReading"))
            }
            Section("Moving around") {
                // VoiceOver Utility's name and choices for moving by groups (14 Nov 2026).
                Picker("Grouping behaviour", selection: model.bool("general", "navigateByGroups")) {
                    Text("Standard: VoiceOver keys move by groups").tag(true); Text("Ignore groups").tag(false)
                }
                Toggle("NVDA and JAWS keys move by groups too", isOn: model.bool("general", "groupsInWindowsStyle"))
                Toggle("At the end of a group, wrap round to its start", isOn: model.bool("general", "cursorWraps"))
                Picker("Moving the cursor moves the keyboard focus", selection: model.string("general", "focusFollowsCursor", "auto")) {
                    Text("By style: VoiceOver keys only").tag("auto"); Text("Always").tag("on"); Text("Never").tag("off")
                }
                // NVDA's review cursor settings (14 Nov 2026).
                Toggle("Review cursor follows the keyboard focus", isOn: model.bool("keyboard", "reviewFollowsFocus"))
                Toggle("Review cursor follows the caret", isOn: model.bool("keyboard", "reviewFollowsCaret"))
                Toggle("Review cursor follows the mouse", isOn: model.bool("keyboard", "reviewFollowsMouse"))
                Toggle("Simple review mode: NVDA keys skip layout", isOn: model.bool("keyboard", "simpleReviewMode"))
                Picker("Initial position of the cursor in a new window", selection: model.string("general", "cursorStart", "focus")) {
                    Text("Keyboard focused item").tag("focus"); Text("First item in window").tag("firstItem")
                }
                Toggle("Automatically interact when using the Tab key", isOn: model.bool("general", "interactOnTab"))
                Toggle("Fast searching: Right Command and a letter in a list", isOn: model.bool("general", "fastSearching"))
                Text("Fast searching moves to the next item starting with the letter. While it is on, Right Command and a letter does not reach the app in a list; Left Command does.").font(.caption)
            }
            Section("Keyboard Commander") {
                // The Commander's own on and off is under The keypad, below.
                Picker("Commander key", selection: model.string("keyboard", "commanderKey", "rightOption")) {
                    Text("Right Option").tag("rightOption"); Text("Left Option").tag("leftOption")
                    Text("Right Command").tag("rightCommand"); Text("Left Command").tag("leftCommand"); Text("Right Control").tag("rightControl")
                }
                Text("The Commander key and a letter runs the command given to that letter. Give letters, keypad keys and trackpad gestures their commands in the TurnOver menu, Keys, My own keys.").font(.caption)
            }
            Section("The keypad") {
                Toggle("Keypad commands with VoiceOver keys (VO Clear switches)", isOn: model.bool("keyboard", "numpadCommander"))
                Toggle("Keypad commands with NVDA keys (Clear switches)", isOn: model.bool("keyboard", "keypadCommands"))
                // VoiceOver's Keyboard Commander, which only VO-Shift-K could turn on or off (the settings audit, 14 Nov 2026).
                Toggle("The Commander key with a letter runs a command (VoiceOver's Keyboard Commander)", isOn: model.bool("keyboard", "optionCommander"))
            }
            // NVDA's timing settings (its multiple key press timeout, and Advanced's caret move timeout).
            Section("Timing") {
                let press = model.number("keyboard", "multiPressTimeoutMs")
                Stepper(value: press, in: 200...1500, step: 50) { Text("A key pressed again within \(Int(press.wrappedValue)) milliseconds counts as pressed twice") }
                let caret = model.number("editableText", "caretMoveTimeoutMs")
                Stepper(value: caret, in: 50...500, step: 25) { Text("Wait up to \(Int(caret.wrappedValue)) milliseconds for the caret to move after a key") }
            }
        }.formStyle(.grouped).navigationTitle("Keyboard")
    }
}

/// The mouse (14 Nov 2026): NVDA's Mouse settings and VoiceOver's mouse pointer options.
struct MouseView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Speak what is under the mouse pointer as it moves", isOn: model.bool("mouse", "tracking"))
            Picker("Over text, read", selection: model.string("mouse", "textUnit", "paragraph")) {
                Text("A character").tag("character"); Text("A word").tag("word"); Text("A line").tag("line"); Text("A paragraph").tag("paragraph")
            }
            Picker("Speak after the pointer rests for", selection: model.int("mouse", "delayMs")) {
                Text("No delay").tag(0); Text("A quarter of a second").tag(250); Text("Half a second").tag(500); Text("One second").tag(1000)
            }
            Toggle("Say the kind of item, such as button, when the pointer reaches it", isOn: model.bool("mouse", "reportRole"))
            Toggle("Say the window's name when the pointer moves into another window", isOn: model.bool("mouse", "announceWindow"))
            Toggle("Play audio coordinates as the mouse moves", isOn: model.bool("mouse", "audioCoordinates"))
            Text("A short beep at each move: higher towards the top of the screen, lower towards the bottom, and from the left or right speaker by where the pointer is across, as in NVDA.").font(.caption)
            Picker("Mouse pointer and the cursor", selection: model.string("mouse", "pointer", "ignores")) {
                Text("The pointer ignores the cursor").tag("ignores"); Text("The pointer follows the cursor").tag("follows"); Text("Moving the pointer moves the cursor").tag("moves")
            }
            Text("Follows: the pointer goes to each item the cursor reaches. Moves: the cursor goes to the item under the pointer, and it is read.").font(.caption)
        }.formStyle(.grouped).navigationTitle("Mouse")
    }
}

struct ItemsView: View {
    @EnvironmentObject var model: Model
    /// "everywhere", or the bundle identifier of the app the list is for.
    @State private var scope = "everywhere"
    // The verbosity manager (27 Oct 2026): what is said about an item, in order, each piece on or off; one list for
    // everywhere and one for the app last in front, kept apart. The three old switches (help text, shortcut,
    // position) are rows of this list now. The names match Config.Verbosity.titles.
    private static let pieces = ["name", "role", "value", "state", "description", "shortcut", "position", "level"]
    private static var titles: [String: String] {
        ["name": String(localized: "Name", comment: "A piece of an item's announcement, in the reading order"), "role": String(localized: "Kind, such as button or link", comment: "A piece of an item's announcement, in the reading order"),
         "value": String(localized: "Value", comment: "A piece of an item's announcement, in the reading order"), "state": String(localized: "State, such as checked or expanded", comment: "A piece of an item's announcement, in the reading order"),
         "description": String(localized: "Help text", comment: "A piece of an item's announcement, in the reading order"), "shortcut": String(localized: "Keyboard shortcut", comment: "A piece of an item's announcement, in the reading order"),
         "position": String(localized: "Position, such as 3 of 10", comment: "A piece of an item's announcement, in the reading order"), "level": String(localized: "Level, in a tree or outline", comment: "A piece of an item's announcement, in the reading order")]
    }
    private var frontApp: (bundle: String, name: String)? {
        guard let d = model.special("_frontApp") as? [String: Any], let b = d["bundle"] as? String, let n = d["name"] as? String else { return nil }
        return (b, n)
    }
    private var everywhere: [String: Any] { model.get("presentation", "verbosity") as? [String: Any] ?? [:] }
    private var byApp: [String: Any] { model.get("presentation", "verbosityByApp") as? [String: Any] ?? [:] }
    private var ownList: Bool { scope == "everywhere" || byApp[scope] != nil }
    private var current: [String: Any] { scope == "everywhere" ? everywhere : (byApp[scope] as? [String: Any] ?? everywhere) }
    private var order: [String] {
        var o = (current["order"] as? [String] ?? []).filter { Self.pieces.contains($0) }
        for p in Self.pieces where !o.contains(p) { o.append(p) }
        return o
    }
    private var off: [String] { current["off"] as? [String] ?? [] }
    private func save(order: [String], off: [String]) {
        let v: [String: Any] = ["order": order, "off": off]
        if scope == "everywhere" { model.set("presentation", "verbosity", v) } else { var d = byApp; d[scope] = v; model.set("presentation", "verbosityByApp", d) }
    }
    private func move(_ piece: String, by delta: Int) {
        var o = order
        guard let i = o.firstIndex(of: piece), o.indices.contains(i + delta) else { return }
        o.swapAt(i, i + delta)
        save(order: o, off: off)
    }
    var body: some View {
        Form {
            Section("What is said about an item, in order") {
                Picker("For", selection: $scope) {
                    Text("Everywhere").tag("everywhere")
                    if let f = frontApp { Text(f.name).tag(f.bundle) }
                }
                if scope != "everywhere", !ownList {
                    Text("Using the everywhere list. A change here starts a list for this app.")
                }
                ForEach(Array(order.enumerated()), id: \.element) { i, piece in
                    let title = Self.titles[piece] ?? piece
                    HStack {
                        Toggle(title, isOn: Binding(get: { !off.contains(piece) }, set: { on in
                            var o = off.filter { $0 != piece }; if !on { o.append(piece) }; save(order: order, off: o)
                        }))
                        Spacer()
                        Button("Up") { move(piece, by: -1) }.disabled(i == 0).accessibilityLabel("Move \(title) up")
                        Button("Down") { move(piece, by: 1) }.disabled(i == order.count - 1).accessibilityLabel("Move \(title) down")
                    }
                }
                if scope != "everywhere", ownList {
                    Button("Use the everywhere list for this app") { var d = byApp; d[scope] = nil; model.set("presentation", "verbosityByApp", d) }
                }
            }
            // Another app came to the front while the list was for the one before: back to everywhere, so the controls
            // never edit an app the picker no longer names (a code review, 27 Oct 2026).
            .onChange(of: frontApp?.bundle) { _, now in if scope != "everywhere", scope != now { scope = "everywhere" } }
            Toggle("Hints after a pause", isOn: model.bool("presentation", "speakHints"))
            let hint = model.number("presentation", "hintDelayMs")
            Stepper(value: hint, in: 300...5000, step: 100) { Text("Pause before a hint: \(String(format: "%.1f", hint.wrappedValue / 1000)) seconds") }
            Toggle("Read a dialog's text as it opens", isOn: model.bool("presentation", "speakDialogText"))
            Toggle("Say which plugin an app has as it comes to the front", isOn: model.bool("presentation", "announcePlugins"))
            Picker("Heading, link and button: when to say them", selection: model.string("documentFormatting", "roleOrder", "auto")) {
                Text("By keyboard style").tag("auto"); Text("Before the words, as NVDA").tag("before"); Text("After the words, as VoiceOver").tag("after")
            }
            // VoiceOver's Verbosity > Announcements (14 Nov 2026).
            Section("Announcements") {
                Picker("When text under the cursor changes", selection: model.string("presentation", "statusTextChanges", "off")) {
                    Text("Do nothing").tag("off"); Text("Play a sound").tag("tone"); Text("Speak the text").tag("speak")
                }
                Picker("When the number of rows in a table or list changes", selection: model.string("presentation", "rowCountChanges", "off")) {
                    Text("Do nothing").tag("off"); Text("Play a sound").tag("tone"); Text("Say how many rows").tag("speak")
                }
                Toggle("Play a sound when a dialog appears", isOn: model.bool("presentation", "dialogSound"))
                Toggle("Skip a label already said with its item", isOn: model.bool("presentation", "skipRedundantLabels"))
            }
        }.formStyle(.grouped).navigationTitle("Item details")
    }
}

struct DocumentsView: View {
    @EnvironmentObject var model: Model
    private let kinds: [(String, String)] = [
        ("headings", String(localized: "Headings", comment: "A kind of element in Documents settings")), ("links", String(localized: "Links", comment: "A kind of element in Documents settings")),
        ("lists", String(localized: "Lists", comment: "A kind of element in Documents settings")), ("tables", String(localized: "Tables", comment: "A kind of element in Documents settings")),
        ("landmarks", String(localized: "Landmarks", comment: "A kind of element in Documents settings")), ("graphics", String(localized: "Graphics", comment: "A kind of element in Documents settings")),
        ("blockQuotes", String(localized: "Block quotes", comment: "A kind of element in Documents settings")), ("spellingErrors", String(localized: "Spelling errors", comment: "A kind of element in Documents settings"))]
    var body: some View {
        Form {
            ForEach(kinds, id: \.0) { k in
                Picker(k.1, selection: model.string("documentFormatting", k.0, "speech")) {
                    Text("Said").tag("speech"); Text("A sound").tag("tone"); Text("Nothing").tag("off")
                }
            }
            Toggle("Say heading levels", isOn: model.bool("documentFormatting", "reportHeadingLevel"))
            Section("Tables") {
                Toggle("Row and column headers", isOn: model.bool("documentFormatting", "tableHeaders"))
                Toggle("Cell positions", isOn: model.bool("documentFormatting", "tableCellCoordinates"))
            }
            Section("Fonts, said as the caret moves into new formatting") {
                Toggle("Font name", isOn: model.bool("documentFormatting", "reportFontName"))
                Toggle("Font size", isOn: model.bool("documentFormatting", "reportFontSize"))
                Toggle("Bold, italic and underline", isOn: model.bool("documentFormatting", "reportFontAttributes"))
                Toggle("Colour", isOn: model.bool("documentFormatting", "reportColor"))
            }
            Section("Lines") {
                Picker("Line indentation, as the caret moves by line", selection: model.string("documentFormatting", "lineIndentation", "off")) {
                    Text("Off").tag("off"); Text("Spoken, such as 4 space").tag("speech"); Text("Tones, higher for deeper").tag("tones"); Text("Spoken and tones").tag("both")
                }
            }
        }.formStyle(.grouped).navigationTitle("Documents")
    }
}

struct WebPagesView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Type into a field as soon as it has the focus", isOn: model.bool("virtualBuffers", "autoFocusMode"))
            // VoiceOver's Web category and NVDA's lines per page (14 Nov 2026).
            Picker("When a new page opens", selection: model.string("virtualBuffers", "pageLoad", "read")) {
                Text("Read the page through").tag("read")
                Text("Say its title and how many headings, links and tables it has").tag("summary")
                Text("Say its title and first line").tag("line")
                Text("Say nothing").tag("nothing")
            }
            Picker("While a page loads", selection: model.string("virtualBuffers", "loadingFeedback", "nothing")) {
                Text("Say nothing").tag("nothing")
                Text("Say how far it has got").tag("progress")
                Text("Play a soft tone").tag("tone")
            }
            Picker("Pictures on a page", selection: model.string("virtualBuffers", "navigateImages", "always")) {
                Text("Always read").tag("always")
                Text("Read only those with a description").tag("described")
                Text("Skip").tag("never")
            }
            Slider(value: model.number("virtualBuffers", "linesPerPage"), in: 5...100, step: 5) { Text("Lines moved by Page Up and Page Down") }
                .accessibilityValue("\(Int(model.number("virtualBuffers", "linesPerPage").wrappedValue)) lines")
            Toggle("Single-letter keys go round the page", isOn: model.bool("virtualBuffers", "wrapQuickNav"))
            Toggle("Links and buttons in the line, as on screen", isOn: model.bool("virtualBuffers", "screenLayout"))
            Toggle("Name undescribed pictures by their file name", isOn: model.bool("virtualBuffers", "imageFileNames"))
            Slider(value: model.number("virtualBuffers", "maxLineLength"), in: 40...250, step: 10) { Text("Longest line") }
                .accessibilityValue("\(Int(model.number("virtualBuffers", "maxLineLength").wrappedValue)) characters")
        }.formStyle(.grouped).navigationTitle("Web pages")
    }
}

/// NVDA's Vision and VoiceOver's Visuals: for a sighted helper, or someone with low vision (14 Nov 2026).
struct VisionView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Highlight what TurnOver is on", isOn: model.bool("vision", "highlight"))
            Text("A coloured ring on the screen, like VoiceOver's cursor: blue round the focus, pink round the review cursor, yellow round the reading position on a web page.").font(.caption)
            Toggle("Highlight the focus", isOn: model.bool("vision", "highlightFocus"))
            Toggle("Highlight the review cursor", isOn: model.bool("vision", "highlightReview"))
            Toggle("Highlight the reading position in browse mode", isOn: model.bool("vision", "highlightBrowse"))
            Toggle("Show the caption panel", isOn: model.bool("vision", "captionPanel"))
            Text("What TurnOver says, at the bottom of the screen.").font(.caption)
            Toggle("Show the braille panel", isOn: model.bool("vision", "braillePanel"))
            Text("What the braille display shows, as braille and as text, above the caption panel. It works without a display.").font(.caption)
            Picker("Text size in the panels", selection: model.string("vision", "panelFontSize", "medium")) {
                Text("Small").tag("small")
                Text("Medium").tag("medium")
                Text("Large").tag("large")
            }
        }.formStyle(.grouped).navigationTitle("Vision")
    }
}

struct RecognitionView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Recognise again when the screen changes, while a result is open", isOn: model.bool("recognition", "autoRefresh"))
            Text("The window is looked at each second; when it has changed, what is new is read.").font(.caption)
            Toggle("Read the whole result as it opens", isOn: model.bool("recognition", "autoSayAll"))
            // macOS 26 and later only: earlier, recognition reads text alone (ScreenInterface needs Vision's newer readers).
            if #available(macOS 26.0, *) {
                Text("Press the screen recognition key twice (VO-Shift-Y, or TurnOver R) for the window's controls: each row is one, such as \"Save, button\", and Return clicks it. Pressed once, it reads the text.").font(.caption)
            }
            Toggle("After Return clicks something, recognise again", isOn: model.bool("recognition", "refreshAfterClick"))
            Text("The screen that follows a click is read without pressing the key again; off, the result closes after the click.").font(.caption)
        }.formStyle(.grouped).navigationTitle("Screen recognition")
    }
}

struct OtherAppsView: View {
    @EnvironmentObject var model: Model
    private var apps: [(id: String, name: String, allowed: Bool)] {
        ((model.special("_speechPortApps") as? [[String: Any]]) ?? []).compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id, name, d["allowed"] as? Bool ?? false)
        }
    }
    var body: some View {
        Form {
            // Steam's switch: every setting has a place in this window (21 Oct 2026), and Big Picture reading, off
            // since it became a choice on 21 Oct, couldn't be found (the maintainer, 25 Oct 2026). Its Games item in the
            // TurnOver menu's Tools went on 2 Nov 2026: game reading is always on. Saved in the settings file, so it
            // holds across restarts.
            Section("Steam") {
                Toggle("Read Steam's Big Picture", isOn: model.bool("games", "readBigPictureChosen"))
                    .accessibilityLabel("Read Steam's Big Picture")
                    .accessibilityHint("Makes Steam open a debugging port on this Mac while it runs, which other programs here could use too.")
                Text("Big Picture makes Steam open a debugging port on this Mac while it runs, which other programs here could use too. Off removes it. Steam needs restarting after this is turned on.").font(.caption)
                Button("Restart Steam") { model.setSpecial("_restartSteam", true) }
            }
            if apps.isEmpty {
                Text("No app has asked to speak through TurnOver yet. A game or another program can ask; it appears here, and you choose whether it may.").font(.caption)
            } else {
                ForEach(apps, id: \.id) { a in
                    Toggle(a.name, isOn: Binding(get: { a.allowed }, set: { on in model.setSpecial("_speechPortAllowed", ["id": a.id, "allowed": on]) }))
                }
                Text("Allowed: it can make TurnOver speak while it is the app in front.").font(.caption)
            }
        }.formStyle(.grouped).navigationTitle("Other apps' speech")
    }
}

struct GeneralView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Section("Starting") {
                Toggle("Open TurnOver at login", isOn: model.bool("general", "openAtLogin"))
                Toggle("Show TurnOver in the menu bar", isOn: model.bool("general", "showInMenuBar"))
            }
            Section("Alerts") {
                Toggle("Read notifications from other apps", isOn: model.bool("presentation", "reportNotifications"))
                Toggle("Read changes on screen as they happen", isOn: model.bool("presentation", "reportDynamicContentChanges"))
            }
            Picker("Screen Curtain while TurnOver reads", selection: model.string("general", "screenCurtain", "follow")) {
                Text("The same as VoiceOver's").tag("follow"); Text("Always on").tag("on"); Text("Off").tag("off")
            }
            // VoiceOver's and NVDA's other General settings (14 Nov 2026).
            TextField("Speak the following greeting after login", text: model.string("general", "loginGreeting", ""))
            if model.special("_autoUpdateChecks") != nil {
                Toggle("Automatically check for updates", isOn: Binding(get: { model.special("_autoUpdateChecks") as? Bool ?? false }, set: { model.setSpecial("_autoUpdateChecks", $0) }))
            }
            Picker("Logging level", selection: model.string("general", "logLevel", "io")) {
                Text("Debug").tag("debug"); Text("Input and output").tag("io"); Text("Info").tag("info"); Text("Warnings").tag("warning"); Text("Errors only").tag("error")
            }
            Section("Portable preferences") {
                Button("Export settings…") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "TurnOver settings.json"; panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url { model.setSpecial("_exportSettings", url.path) }
                }
                Button("Import settings…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { model.setSpecial("_importSettings", url.path) }
                }
                if let message = model.special("_portableMessage") as? String { Text(message) }
            }
        }.formStyle(.grouped).navigationTitle("General")
    }
}

/// Everything TurnOver plays, in one place (Oliver, 2 Nov 2026), as NVDA's Audio panel: whose sounds, the hand-over,
/// progress bars, and other apps' sound lowered while TurnOver speaks. Audio graphs will join them.
struct SoundsView: View {
    @EnvironmentObject var model: Model
    /// What you hear as TurnOver takes over and hands back: two flags in the file, one choice here.
    private var handOver: Binding<String> {
        Binding(get: {
            if model.get("general", "handOverNothing") as? Bool == true { return "nothing" }
            if model.get("general", "handOverChimes") as? Bool == true { return "sound" }
            return "words"
        }, set: { v in
            model.set("general", "handOverNothing", v == "nothing")
            model.set("general", "handOverChimes", v == "sound")
        })
    }
    /// Whose sounds: the file keeps "" until one is chosen, so the pop-up shows what plays meanwhile, as TurnOver works it
    /// out (Config.General.effectiveSounds; it showed nothing chosen, a review, 2 Nov 2026).
    private var whose: Binding<String> {
        Binding(get: {
            let s = model.get("general", "sounds") as? String ?? ""
            return s.isEmpty ? model.special("_effectiveSounds") as? String ?? "voiceover" : s
        }, set: { model.set("general", "sounds", $0) })
    }
    var body: some View {
        Form {
            Picker("Whose sounds", selection: whose) {
                Text("VoiceOver's").tag("voiceover"); Text("TurnOver's").tag("turnover")
            }
            Text("VoiceOver's: VoiceOver's own sounds where it has one, such as links and boundaries, and TurnOver's set for the rest. TurnOver's: its set throughout.").font(.caption)
            Toggle("Sounds as I move and press", isOn: model.bool("general", "navigationSounds"))
            Picker("When TurnOver takes over from VoiceOver", selection: handOver) {
                Text("Words").tag("words"); Text("A sound").tag("sound"); Text("Nothing").tag("nothing")
            }
            Picker("Progress bars", selection: model.string("presentation", "progressBars", "beep")) {
                Text("Beep").tag("beep"); Text("Speak the percentage").tag("speak"); Text("Beep and speak").tag("both"); Text("Off").tag("off")
            }
            Picker("Lower other sounds while TurnOver speaks", selection: model.string("speech", "ducking", "off")) {
                Text("No").tag("off"); Text("While speaking").tag("speech"); Text("Always").tag("always")
            }
            OneSoundSettings()
        }.formStyle(.grouped).navigationTitle("Sounds")
    }
}

/// Sounds one by one (the roadmap's "each of TurnOver's sounds on or off, or your own; positional sound with an off
/// switch"; SoundChoices.swift in TurnOver). One sound is chosen from the list and its controls follow, rather than
/// thirty rows of switches and buttons: the list says each sound's state, and the controls below are the same for all.
struct OneSoundSettings: View {
    @EnvironmentObject var model: Model
    @State private var chosen = "heading"
    private var sounds: [(id: String, name: String)] {
        (model.special("_soundList") as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id, name)
        }
    }
    private var off: [String] { model.get("sounds", "off") as? [String] ?? [] }
    private var custom: [String: Any] { model.get("sounds", "custom") as? [String: Any] ?? [:] }
    /// The sound's name with what it does now, as the list shows it: "Links, off", "Headings, your own file".
    private func label(_ id: String, _ name: String) -> String {
        if off.contains(id) { return String(localized: "\(name), off", comment: "A sound in the list in Settings, Sounds, turned off") }
        if custom[id] != nil { return String(localized: "\(name), your own file", comment: "A sound in the list in Settings, Sounds, playing a file the user chose") }
        return name
    }
    private var isOn: Binding<Bool> {
        Binding(get: { !off.contains(chosen) }, set: { on in
            var list = off.filter { $0 != chosen }
            if !on { list.append(chosen) }
            model.set("sounds", "off", list)
        })
    }
    var body: some View {
        Section(header: Text("Each sound")) {
            Toggle("Positional sound: each sound comes from where its item is on the screen", isOn: Binding(
                get: { model.get("sounds", "positional") as? Bool ?? true }, set: { model.set("sounds", "positional", $0) }))
            if sounds.isEmpty {
                Text("The list of sounds comes from TurnOver: it shows once TurnOver is running.").font(.caption)
            } else {
                Picker("Sound", selection: $chosen) {
                    ForEach(sounds, id: \.id) { s in Text(label(s.id, s.name)).tag(s.id) }
                }
                Toggle("Play this sound", isOn: isOn)
                Button("Play") { model.setSpecial("_soundPreview", chosen) }
                Button("Choose your own file for this sound…") { chooseFile() }
                if custom[chosen] != nil {
                    Button("Use TurnOver's sound again") { model.setSpecial("_soundClear", chosen) }
                }
                Text("A sound turned off is silent; where TurnOver has words for it, such as Quick Nav on and off, it says them instead. Your own file is copied into TurnOver's folder, so moving the original doesn't silence it. Positional sound pans the sound files; a plain tone played where a file is missing stays in the middle, as do sounds that belong to no item, such as TurnOver starting.").font(.caption)
            }
        }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a sound file", comment: "The file chooser for a sound in Settings, Sounds")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setSpecial("_soundCustom", ["id": chosen, "path": url.path])
    }
}

/// TurnOver is on or off; VoiceOver is on or off. The two things that relate them live here, and the experimental
/// readers per app, folded away (22 Oct 2026; last in the list, the place for the things most people never touch).
struct ReadersView: View {
    @EnvironmentObject var model: Model
    private var coexist: Binding<Bool> {
        Binding(get: { model.special("_coexist") as? Bool ?? false }, set: { model.setSpecial("_coexist", $0) })
    }
    var body: some View {
        Form {
            Section {
                // Named and described for accessibility explicitly: the long label came through empty, read as "switch, on"
                // with nothing said about what it does (25 Oct 2026), while the shorter one below was read.
                // One switch for the two readers swapping (25 Oct 2026: a second, for the quit alone, said the same by halves).
                Toggle("TurnOver and VoiceOver swap: one comes on as the other goes off", isOn: model.bool("applications", "swapWithVoiceOver"))
                    .accessibilityLabel("TurnOver and VoiceOver swap: one comes on as the other goes off")
                    .accessibilityHint("Off: each reader has its own switch and neither turns the other on or off; TurnOver is still quiet while VoiceOver is on.")
                Text("On: TurnOver turns VoiceOver off as it starts and on as it quits, comes on when VoiceOver turns off and steps aside when VoiceOver comes on. Off: each reader has its own switch and neither turns the other on or off, for VoiceOver reading inside a virtual machine such as Parallels. Either way one reader speaks at a time: while VoiceOver is on, TurnOver is quiet.").font(.caption)
            }
            // A plain section, not a disclosure group: the triangle took the focus but neither Return nor VO Space
            // opened it (Oliver, 28 Oct 2026: "I can't get into the experimental part").
            Section(header: Text("Experimental: readers per app, CoExist")) {
                Toggle("CoExist: VoiceOver stays running alongside TurnOver", isOn: coexist)
                Text("VoiceOver is kept quiet by an audio tap where TurnOver reads and keeps passwords and macOS's own prompts. Removed on 24 Oct 2026 and back as an experiment: it can leave a Mac silent if macOS asks for audio permission while VoiceOver is muted. Changing it restarts TurnOver.").font(.caption)
                Toggle("Readers per app", isOn: model.bool("applications", "perAppReaders"))
                Text("A list of apps for each reader, a mode (TurnOver in its apps, everywhere, or VoiceOver everywhere), and switching between the readers as you change apps. The list is under Tools in the TurnOver menu while this is on. Off, TurnOver reads everywhere while it is on.").font(.caption)
            }
        }.formStyle(.grouped).navigationTitle("Screen reader behaviour")
    }
}

/// The window's manners (25 Oct 2026, an AppleVis reader's first evening with the window): Escape closes it, as it
/// closes TurnOver's menu; the app goes with its last window, and with TurnOver, instead of lingering with no window
/// where only a force quit found it.
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    private var escapeMonitor: Any?
    /// Looks at which TurnOver was missing. Main-actor isolated; a static, since the timer's closure
    /// may not carry the delegate itself (Swift 6).
    @MainActor private static var turnOverGoneChecks = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape with no modifier, outside a field being edited (there it cancels the edit) and with no menu open.
            guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let window = NSApp.keyWindow, !(window.firstResponder is NSText), NSApp.mainMenu?.highlightedItem == nil else { return event }
            window.performClose(nil)
            return nil
        }
        // TurnOver gone for four seconds: the window closes with it. An update's restart closes it too, which is wanted:
        // a window left open through an update showed TurnOver as off until reopened (build 22).
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                // Either copy, the published TurnOver or TurnOver Developer (issue 248).
                let running = [ActiveReader.published, ActiveReader.developer].contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
                Self.turnOverGoneChecks = running ? 0 : Self.turnOverGoneChecks + 1
                if Self.turnOverGoneChecks >= 2 { NSApp.terminate(nil) }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TurnOverSettingsApp: App {
    @StateObject private var model = Model()
    @NSApplicationDelegateAdaptor(SettingsAppDelegate.self) private var delegate
    init() {
        // Tab reaches every control, pop-ups and sliders too, whatever the Mac's Keyboard navigation setting says: with
        // it off, a Tab through Speech met only the ducking pop-up (an AppleVis reader, 25 Oct 2026). This app's domain.
        UserDefaults.standard.set(2, forKey: "AppleKeyboardUIMode")
    }
    var body: some Scene {
        WindowGroup("TurnOver Settings") { ContentView().environmentObject(model) }
            .windowResizability(.contentSize)
    }
}
