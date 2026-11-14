// SPDX-License-Identifier: GPL-3.0-or-later
// Sounds one by one (the public roadmap, "Soon": "each of TurnOver's sounds on or off, or your own; positional sound
// with an off switch"). Every sound TurnOver plays has a name here; Tones, TurnOverSounds and VoiceOverSounds ask
// this file first, so a sound turned off stays silent, and one given a file of your own plays that file, whichever
// sound set is chosen. Positional sound places each sound file where its item sits on the screen, as VoiceOver's
// positional audio does: panned across it (Stereo), or across and up or down it (3D, SpatialSoundPlayer; 14 Nov 2026).
//
// A sound turned off is silent, never replaced by a tone. Where the caller has words for it (Quick Nav on and off),
// VoiceOverSounds.play answers false so the words are said instead, as when VoiceOver's file is missing.
import Foundation
import AVFoundation
import ApplicationServices
import AppKit
import TurnOverSpeech

@MainActor
public enum SoundChoices {
    /// One sound: its name in the settings file and as the Settings window shows it.
    public struct Sound: Sendable {
        public let id: String
        public let title: String
    }

    /// Every sound, in the order the Settings window lists them: reading first, then moving, then TurnOver itself.
    public static let all: [Sound] = [
        Sound(id: "heading", title: String(localized: "Headings", comment: "A sound in Settings, Sounds")),
        Sound(id: "link", title: String(localized: "Links", comment: "A sound in Settings, Sounds")),
        Sound(id: "list", title: String(localized: "Lists", comment: "A sound in Settings, Sounds")),
        Sound(id: "landmark", title: String(localized: "Landmarks", comment: "A sound in Settings, Sounds")),
        Sound(id: "table", title: String(localized: "Tables", comment: "A sound in Settings, Sounds")),
        Sound(id: "graphic", title: String(localized: "Graphics", comment: "A sound in Settings, Sounds")),
        Sound(id: "blockquote", title: String(localized: "Block quotes", comment: "A sound in Settings, Sounds")),
        Sound(id: "comment", title: String(localized: "Comments", comment: "A sound in Settings, Sounds")),
        Sound(id: "spelling", title: String(localized: "Spelling errors", comment: "A sound in Settings, Sounds")),
        Sound(id: "marked", title: String(localized: "Marked text", comment: "A sound in Settings, Sounds")),
        Sound(id: "tick", title: String(localized: "Moving the focus", comment: "A sound in Settings, Sounds")),
        Sound(id: "press", title: String(localized: "Pressing an item", comment: "A sound in Settings, Sounds")),
        Sound(id: "edge", title: String(localized: "Edges and boundaries", comment: "A sound in Settings, Sounds")),
        Sound(id: "empty", title: String(localized: "Nothing there", comment: "A sound in Settings, Sounds: empty space")),
        Sound(id: "drill_in", title: String(localized: "Moving in", comment: "A sound in Settings, Sounds: into a group")),
        Sound(id: "drill_out", title: String(localized: "Moving out", comment: "A sound in Settings, Sounds: out of a group")),
        Sound(id: "popup", title: String(localized: "Pop-ups and menus appearing", comment: "A sound in Settings, Sounds")),
        Sound(id: "page_loaded", title: String(localized: "Page loaded", comment: "A sound in Settings, Sounds")),
        Sound(id: "announcement", title: String(localized: "Announcements", comment: "A sound in Settings, Sounds")),
        Sound(id: "secure", title: String(localized: "Typing in a password field", comment: "A sound in Settings, Sounds")),
        Sound(id: "focus_mode", title: String(localized: "Focus mode", comment: "A sound in Settings, Sounds")),
        Sound(id: "browse_mode", title: String(localized: "Browse mode", comment: "A sound in Settings, Sounds")),
        Sound(id: "quicknav_on", title: String(localized: "Quick Nav on", comment: "A sound in Settings, Sounds")),
        Sound(id: "quicknav_off", title: String(localized: "Quick Nav off", comment: "A sound in Settings, Sounds")),
        Sound(id: "tracking_on", title: String(localized: "Trackpad commands on", comment: "A sound in Settings, Sounds")),
        Sound(id: "tracking_off", title: String(localized: "Trackpad commands off", comment: "A sound in Settings, Sounds")),
        Sound(id: "braille_on", title: String(localized: "Braille display connected", comment: "A sound in Settings, Sounds")),
        Sound(id: "braille_off", title: String(localized: "Braille display disconnected", comment: "A sound in Settings, Sounds")),
        Sound(id: "startup", title: String(localized: "TurnOver starting", comment: "A sound in Settings, Sounds")),
        Sound(id: "take_over", title: String(localized: "TurnOver taking over", comment: "A sound in Settings, Sounds")),
        Sound(id: "hand_back", title: String(localized: "Handing back to VoiceOver", comment: "A sound in Settings, Sounds")),
    ]
    nonisolated package static let ids: Set<String> = [
        "heading", "link", "list", "landmark", "table", "graphic", "blockquote", "comment", "spelling", "marked", "tick",
        "press", "edge", "empty", "drill_in", "drill_out", "popup", "page_loaded", "announcement", "secure", "focus_mode",
        "browse_mode", "quicknav_on", "quicknav_off", "tracking_on", "tracking_off", "braille_on", "braille_off",
        "startup", "take_over", "hand_back",
    ]

    /// The sound a file of TurnOver's set belongs to ("heading3" is a heading).
    nonisolated package static func id(forFile name: String) -> String {
        name.hasPrefix("heading") ? "heading" : name
    }

    /// The sound one of VoiceOver's files stands for, by name whatever its ending (QuickNavOn.wav is Quick Nav on).
    nonisolated package static func id(forVoiceOverFile file: String) -> String? {
        switch (file as NSString).deletingPathExtension {
        case "WrapBoundary", "ElementBorderHit": return "edge"
        case "DrillIn": return "drill_in"
        case "DrillOut": return "drill_out"
        case "QuickNavOn", "QuickNavArrowKeyOn": return "quicknav_on"
        case "QuickNavOff", "QuickNavArrowKeyOff": return "quicknav_off"
        case "TrackingOn": return "tracking_on"
        case "TrackingOff": return "tracking_off"
        case "PopupAppeared": return "popup"
        case "WebAreaLoaded": return "page_loaded"
        case "EmptySpace": return "empty"
        case "Announcement": return "announcement"
        case "SecureCharacter": return "secure"
        case "LinkBegin": return "link"
        case "Misspelled": return "spelling"
        case "BrailleDisplayConnected": return "braille_on"
        case "BrailleDisplayDisconnected": return "braille_off"
        default: return nil
        }
    }

    /// Whether a sound plays at all (Settings, Sounds). A name this file doesn't know always plays.
    public static func isOn(_ id: String) -> Bool { !config.sounds.off.contains(id) }

    /// The sound is off, or a file of your own played for it: either way the caller plays nothing more.
    /// False leaves the caller to play its usual sound.
    @discardableResult
    public static func handled(_ id: String, volume: Float = 0.8) -> Bool {
        if !isOn(id) { return true }
        return playCustom(id, volume: volume)
    }

    // MARK: Your own files

    /// Where your own files are kept: copied in when chosen, so moving or deleting the original doesn't silence it.
    static var folder: URL { AppPaths.file("Sounds") }
    private static var customPlayers: [String: (file: String, player: AVAudioPlayer)] = [:]
    /// Your files that wouldn't play: tried once, logged once, not opened again on every sound (a review, 10 Nov 2026).
    private static var failedFiles: Set<String> = []
    /// The file for a sound, as kept in the settings: only ever a name inside the Sounds folder, never a path out of it.
    static func customFile(_ id: String) -> String? {
        guard let f = config.sounds.custom[id], !f.isEmpty else { return nil }
        let name = (f as NSString).lastPathComponent
        return name.isEmpty || name == ".." || name == "." ? nil : name
    }

    /// Plays your own file for the sound, if you chose one; false if none is chosen or it won't play.
    static func playCustom(_ id: String, volume: Float) -> Bool {
        guard let file = customFile(id), !failedFiles.contains(file) else { return false }
        if customPlayers[id]?.file != file {
            guard let p = try? AVAudioPlayer(contentsOf: folder.appendingPathComponent(file)) else {
                failedFiles.insert(file)
                Log.warning("sounds: your file for \(id) won't play; TurnOver's own plays instead")
                return false
            }
            p.prepareToPlay()
            customPlayers[id] = (file, p)
        }
        guard let p = customPlayers[id]?.player else { return false }
        start(p, volume: volume, id: id)
        return true
    }

    /// A file chosen in the Settings window: copied into TurnOver's own Sounds folder, under the sound's name, and
    /// set for it. False, with nothing changed, if it can't be read as sound. Done on main: a short sound file is read
    /// and copied in a few milliseconds, and only when you choose one.
    @discardableResult
    public static func setCustom(_ id: String, from path: String) -> Bool {
        guard ids.contains(id) else { return false }
        let source = URL(fileURLWithPath: path)
        guard (try? AVAudioPlayer(contentsOf: source)) != nil else {
            Log.warning("sounds: the file chosen for \(id) isn't sound TurnOver can play")
            return false
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "sound" : source.pathExtension.lowercased()
        let name = "\(id).\(ext)"
        // An earlier file of a different kind for the same sound goes, so the folder holds one file per sound.
        let target = folder.appendingPathComponent(name)
        // The file already in place, chosen again: nothing to copy (removing the target first would delete it).
        if source.standardizedFileURL.resolvingSymlinksInPath() == target.standardizedFileURL.resolvingSymlinksInPath() {
            config.sounds.custom[id] = name; failedFiles.remove(name); customPlayers[id] = nil; config.save(); return true
        }
        if let old = customFile(id), old != name { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
        try? fm.removeItem(at: target)
        do { try fm.copyItem(at: source, to: target) } catch {
            Log.warning("sounds: couldn't copy the file chosen for \(id): \(error)")
            return false
        }
        customPlayers[id] = nil
        failedFiles.remove(name)
        SpatialSoundPlayer.shared.forget(.file(target))   // the engine's copy of the file it replaced
        config.sounds.custom[id] = name
        config.save()
        return true
    }

    /// Back to TurnOver's own sound: your file for it is removed.
    public static func clearCustom(_ id: String) {
        let file = customFile(id)
        guard config.sounds.custom.removeValue(forKey: id) != nil else { return }
        if let file {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)); failedFiles.remove(file)
            SpatialSoundPlayer.shared.forget(.file(folder.appendingPathComponent(file)))
        }
        customPlayers[id] = nil
        config.save()
    }

    /// The sound as it plays now, for the Settings window's Play button: your file, the set's file, or the tone.
    /// Played even while the sound is off, so you can hear what you are turning on.
    public static func preview(_ id: String) {
        let saved = placement
        placement = .middle   // a preview plays in the middle
        defer { placement = saved }
        if playCustom(id, volume: 0.8) { return }
        let wasOff = config.sounds.off.contains(id)
        if wasOff { config.sounds.off.removeAll { $0 == id } }
        defer { if wasOff { config.sounds.off.append(id) } }
        switch id {
        case "heading": Tones.heading(level: 1)
        case "link": Tones.link()
        case "list": Tones.list()
        case "landmark": Tones.landmark()
        case "table": Tones.table()
        case "graphic": Tones.graphic()
        case "blockquote": Tones.blockQuote()
        case "comment": Tones.comment()
        case "spelling": Tones.spellingError()
        case "edge": playEdgePreview()
        case "focus_mode": Tones.focusMode()
        case "browse_mode": Tones.browseMode()
        case "startup": playOwn("startup")
        case "take_over": playOwn("take_over")
        case "hand_back": playOwn("hand_back")
        // VoiceOver's files straight: Tones' own are silent while VoiceOver runs beside TurnOver with its set chosen.
        case "braille_on": if !VoiceOverSounds.play("BrailleDisplayConnected.aiff") { Tones.beep(660, 40) }
        case "braille_off": if !VoiceOverSounds.play("BrailleDisplayDisconnected.aiff") { Tones.beep(523, 40) }
        case "tick", "press", "marked": playOwn(id)
        default:
            // The VoiceOver-named ones (moving in and out, Quick Nav, pop-ups and the rest).
            if let file = voiceOverFile[id] { VoiceOverSounds.play(file) }
        }
    }
    private static func playOwn(_ name: String) { if !TurnOverSounds.play(name) { Tones.beep(660, 40) } }
    private static func playEdgePreview() { if !VoiceOverSounds.play("WrapBoundary.aiff") { Tones.beep(220, 50, volume: 0.2) } }
    private static let voiceOverFile: [String: String] = [
        "drill_in": "DrillIn.aiff", "drill_out": "DrillOut.aiff", "quicknav_on": "QuickNavOn.wav", "quicknav_off": "QuickNavOff.wav",
        "tracking_on": "TrackingOn.aiff", "tracking_off": "TrackingOff.aiff", "popup": "PopupAppeared.aiff",
        "page_loaded": "WebAreaLoaded.aiff", "empty": "EmptySpace.aiff", "announcement": "Announcement.aiff", "secure": "SecureCharacter.aiff",
    ]

    // MARK: Positional sound

    /// Where an item sits on its screen: x from -1 (left edge) to 1 (right edge), y from -1 (bottom) to 1 (top).
    nonisolated public struct Placement: Equatable, Sendable {
        public var x: Float
        public var y: Float
        public init(x: Float, y: Float) { self.x = x; self.y = y }
        public static let middle = Placement(x: 0, y: 0)
        /// The stereo pan: across alone, kept within ±0.8 so nothing is heard in one ear only.
        public var pan: Float { max(-0.8, min(0.8, x * 0.8)) }
    }

    /// Where the next sound comes from; set as TurnOver moves onto an item (the focus, the review cursor, a line read
    /// in browse mode).
    private static var placement = Placement.middle

    /// TurnOver is now on this element: later sounds come from its middle on its screen. Its frame is read here, once
    /// per move, rather than as each sound plays (a sound may play off a timer, after the focus has gone). Reading
    /// position and size is the same cost as reading the item to speak it; a hung app answers within the one-second
    /// messaging timeout every observed process has. Nothing is read while positional sound is off.
    public static func place(at element: AXUIElement?) {
        placement = self.placement(of: element) ?? .middle
    }

    /// Where an element sits, or nil when positional sound is off or the element gives no frame.
    public static func placement(of element: AXUIElement?) -> Placement? {
        guard config.sounds.positional, let element, let frame = TurnOverObject.frame(element) else { return nil }
        return placement(for: frame, screens: NSScreen.screens.map(accessibilityFrame))
    }

    /// Runs `body` with sounds at this placement, then puts the placement back: a sound queued while a line is read
    /// belongs to its own piece of the line. Nil keeps the placement there is.
    public static func at(_ where: Placement?, _ body: () -> Void) {
        guard let `where` else { body(); return }
        let saved = placement
        placement = `where`
        body()
        placement = saved
    }

    /// A screen's frame in accessibility points (origin at the top left of the main display, y down).
    static func accessibilityFrame(_ screen: NSScreen) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        return CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
    }

    /// Where an item's middle sits on the screen it is on (frames in accessibility points, y down). On no known
    /// screen, the middle.
    nonisolated package static func placement(for frame: CGRect, screens: [CGRect]) -> Placement {
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = screens.first(where: { $0.contains(mid) }) ?? screens.first(where: { $0.intersects(frame) }),
              screen.width > 0, screen.height > 0 else { return .middle }
        let across = (mid.x - screen.minX) / screen.width   // 0 at the left edge, 1 at the right
        let down = (mid.y - screen.minY) / screen.height    // 0 at the top, 1 at the bottom
        func clamp(_ v: CGFloat) -> Float { Float(max(-1, min(1, v))) }
        return Placement(x: clamp(across * 2 - 1), y: clamp(1 - down * 2))
    }

    /// The stereo pan for an item: where its middle sits across the screen, within ±0.8.
    nonisolated package static func pan(for frame: CGRect, screens: [CGRect]) -> Float {
        placement(for: frame, screens: screens).pan
    }

    /// Sounds that belong to no item on screen (TurnOver itself, a display, a notification, a mode): always in the
    /// middle, never where the focus last was (a review, 10 Nov 2026).
    nonisolated static let unplaced: Set<String> = [
        "startup", "take_over", "hand_back", "braille_on", "braille_off", "announcement", "page_loaded",
        "quicknav_on", "quicknav_off", "tracking_on", "tracking_off", "marked", "focus_mode", "browse_mode",
    ]

    /// How a sound file plays, from Settings, Sounds: through SpatialSoundPlayer for 3D or with reverb, otherwise
    /// through its AVAudioPlayer as before (Off and Stereo without reverb are unchanged).
    nonisolated package static func route(placement: String, reverb: Bool, at where: Placement, placed: Bool)
        -> SpatialSoundPlayer.Placement? {
        let p = placed && placement != "off" ? `where` : .middle
        if placement == "3d" { return .threeD(x: p.x, y: p.y) }
        if reverb { return .stereo(pan: p.pan) }
        return nil
    }

    /// The engine didn't play a sound (no output, an unreadable file): AVAudioPlayer plays them for a while instead,
    /// rather than trying the engine on every sound.
    private static var engineRestingUntil = Date.distantPast
    private static var engineUsed = false

    /// Starts a player at TurnOver's volume and the placement: the one place a sound file starts. `key` names a
    /// player made from data in memory (VoiceOver's levelled files), so the engine can keep its sound.
    static func start(_ p: AVAudioPlayer, volume: Float, id: String?, key: String? = nil) {
        let level = volume * min(1.5, max(0.2, Float(config.speech.volume) / 100))   // with TurnOver's own volume
        let placed = !(id.map(unplaced.contains) ?? false)
        let source: SpatialSoundPlayer.Source? = p.url.map { .file($0) } ?? key.flatMap { k in p.data.map { .wav(key: k, data: $0) } }
        if let source, Date() >= engineRestingUntil,
           let route = route(placement: config.sounds.placement, reverb: config.sounds.reverb, at: placement, placed: placed) {
            engineUsed = true
            SpatialSoundPlayer.shared.play(source, placement: route, volume: level, reverb: config.sounds.reverb) {
                engineRestingUntil = Date().addingTimeInterval(30)
                playPlainly(p, level: level, pan: route.pan)
            }
            return
        }
        // Back to Off or Stereo without reverb: the engine has nothing more to play, so it stops.
        if engineUsed { engineUsed = false; SpatialSoundPlayer.shared.stop() }
        playPlainly(p, level: level, pan: config.sounds.positional && placed ? placement.pan : 0)
    }

    private static func playPlainly(_ p: AVAudioPlayer, level: Float, pan: Float) {
        p.volume = level
        p.pan = pan
        p.currentTime = 0
        p.play()
    }
}

extension SpatialSoundPlayer.Placement {
    /// The pan to fall back to when AVAudioPlayer plays it instead.
    var pan: Float {
        switch self {
        case .threeD(let x, _): return max(-0.8, min(0.8, x * 0.8))
        case .stereo(let pan): return pan
        }
    }
}
