// SPDX-License-Identifier: GPL-3.0-or-later
// The mouse (14 Nov 2026): NVDA's Mouse settings and VoiceOver's pointer options, for a user who moves the mouse.
// - Mouse tracking (NVDA's "Enable mouse tracking", VoiceOver's "Speak text under mouse after delay"): what is under
//   the pointer is said as it moves; over text, the character, word, line or paragraph there (NVDA's "Text unit
//   resolution"), elsewhere the item.
// - Report role when the mouse enters an item (NVDA).
// - Audio coordinates (NVDA's "Play audio coordinates when mouse moves", mouseHandler.playAudioCoordinates): a 40 ms
//   beep at each move, its pitch from 220 Hz at the bottom of the desktop to 880 Hz at the top, its left and right
//   volumes by where the pointer is across. NVDA's "Brightness controls audio coordinates volume" is left out: it
//   reads the screen's pixels under the pointer, which on the Mac needs Screen Recording permission.
// - The mouse pointer (VoiceOver's Navigation > Mouse pointer): ignores the cursor (as before), follows it, or moves it.
// - Announce when the mouse enters a window (VoiceOver's Verbosity > Announcements).
// The pointer is watched by an AppKit global monitor (listen only; it can't hold anything back), installed only while
// one of these is on. The item under the pointer is asked for at most every 80 ms, after the pointer rests for the
// delay when one is set.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

/// The pure parts, for tests: NVDA's audio coordinates and the text units.
nonisolated public enum MouseMath {
    /// NVDA's playAudioCoordinates (source/mouseHandler.py), with its defaults: audioCoordinates_minPitch 220,
    /// maxPitch 880, maxVolume 1 (brightness off). The pitch is NVDA's own linear scale from the bottom of the desktop
    /// to its top; the left and right volumes, 0 to 85, share 85 by where the pointer is across.
    public static func audioCoordinates(_ p: CGPoint, desktop d: CGRect, minPitch: Double = 220, maxPitch: Double = 880) -> (frequency: Double, left: Double, right: Double) {
        guard d.width > 0, d.height > 0 else { return (minPitch, 42.5, 42.5) }
        let x = min(max(p.x - d.minX, 0), d.width), y = min(max(p.y - d.minY, 0), d.height)
        let pitch = minPitch + (maxPitch - minPitch) * Double((d.height - y) / d.height)
        let left = 85 * Double((d.width - x) / d.width), right = 85 * Double(x / d.width)
        return (pitch, left, right)
    }
    /// NVDA's left and right volumes (0 to 100 each) as TurnOver's beep takes them: a volume and a pan. Tones.nvdaBeep's
    /// 0.21 is NVDA's ordinary beep, 50 left and 50 right; so the volume is 0.21 for every 100 of the two together.
    public static func volumeAndPan(left: Double, right: Double) -> (volume: Float, pan: Float) {
        let sum = left + right
        guard sum > 0 else { return (0, 0) }
        return (Float(0.21 * sum / 100), Float((right - left) / sum))
    }
    /// The range of a unit around a UTF-16 offset in `text`: "character", "word" or "paragraph" (a line where the app
    /// gives no lines). A word is the system's word there; between words, nothing (an empty range).
    public static func unitRange(_ text: NSString, at offset: Int, unit: String) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let o = min(max(0, offset), text.length - 1)
        switch unit {
        case "character": return text.rangeOfComposedCharacterSequence(at: o)
        case "word":
            var found = NSRange(location: o, length: 0)
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byWords, .substringNotRequired]) { _, r, _, stop in
                if NSLocationInRange(o, r) { found = r; stop.pointee = true } else if r.location > o { stop.pointee = true }
            }
            return found
        default: return text.paragraphRange(for: NSRange(location: o, length: 0))
        }
    }
}

public enum MouseTracking {
    private static var monitor: Any?
    /// The item last under the pointer, its window, and the text last said there (NVDA's _lastMouseTextInfoObject).
    private static var lastElement: AXUIElement?
    private static var lastWindow: AXUIElement?
    private static var lastTextKey: String?
    private static var lastBeep = Date.distantPast
    private static var probeScheduled = false
    private static var restGeneration = 0
    private static var lastProbePoint: CGPoint?

    private static var anyOn: Bool {
        let m = config.mouse
        return m.tracking || m.audioCoordinates || m.pointer == "moves" || m.announceWindow
    }

    /// The monitor on while any of the mouse settings needs it, off otherwise. At the start and after each settings change.
    public static func refresh() {
        if anyOn, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { event in
                // Global monitors are called on the main thread.
                let pid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0
                MainActor.assumeIsolated { moved(fromSelf: pid == Int64(getpid())) }
            }
            Log.info("mouse: watching the pointer")
        } else if !anyOn, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            lastElement = nil; lastWindow = nil; lastTextKey = nil
            Log.info("mouse: no longer watching the pointer")
        }
    }

    private static func moved(fromSelf: Bool) {
        // TurnOver's own clicks (VO-Shift-Space puts the pointer on the item and back) are not the user's moves.
        guard Core.active, !fromSelf, !Trackpad.controlOn else { return }
        let m = config.mouse
        let p = VoiceOverKeysPlugin.mouseLocation()
        if m.audioCoordinates { beep(at: p) }
        guard m.tracking || m.pointer == "moves" || m.announceWindow else { return }
        if m.delayMs > 0 {
            // VoiceOver's delay: said once the pointer has rested.
            restGeneration += 1
            let g = restGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(min(m.delayMs, 3000))) { if g == restGeneration { probe() } }
        } else if !probeScheduled {
            probeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { probeScheduled = false; probe() }
        }
    }

    /// NVDA's audio coordinates. NVDA beeps at every move; here at most once per beep's length (40 ms): TurnOver's
    /// tones queue rather than cut each other off, so beeps closer together would fall further and further behind
    /// the pointer.
    private static func beep(at p: CGPoint) {
        guard Date().timeIntervalSince(lastBeep) >= 0.04 else { return }
        lastBeep = Date()
        let c = MouseMath.audioCoordinates(p, desktop: desktop())
        let v = MouseMath.volumeAndPan(left: c.left, right: c.right)
        Tones.nvdaBeep(c.frequency, 40, volume: v.volume, pan: v.pan)
    }

    /// Every display together, in accessibility coordinates (from the top left of the main display), as NVDA takes the
    /// whole desktop.
    private static func desktop() -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { CGRect(x: $0.frame.minX, y: h - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
            .reduce(CGRect.null) { $0.union($1) }
    }

    private static func probe() {
        guard Core.active, anyOn else { return }
        let p = VoiceOverKeysPlugin.mouseLocation()
        if let last = lastProbePoint, last == p { return }
        lastProbePoint = p
        // Over a window of TurnOver's own, asking it would wait on this very thread (SettingsBridge's note).
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        if number > 0, NSApp?.window(withWindowNumber: number) != nil { return }
        guard let hit = VoiceOverKeysPlugin.element(at: p) else { lastElement = nil; lastTextKey = nil; return }
        let m = config.mouse
        let entered = lastElement.map { !CFEqual($0, hit) } ?? true
        lastElement = hit
        if entered { lastTextKey = nil }   // another item's text is new, whatever its offsets
        var said: [String] = []
        // VoiceOver's "Announce when mouse cursor enters a window".
        let window = hit.element(kAXWindowAttribute)
        if let w = window, lastWindow.map({ !CFEqual($0, w) }) ?? true {
            lastWindow = w
            if m.announceWindow {
                let title = (w.string(kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                said.append(title.isEmpty ? (NSRunningApplication(processIdentifier: hit.pid)?.localizedName ?? String(localized: "window", comment: "Spoken message")) : title)
            }
        }
        // VoiceOver's "Moves VoiceOver cursor": the cursor goes where the pointer is, without the keyboard following.
        if m.pointer == "moves", entered { ObjectNavigator.shared.place(hit) }
        let speaks = m.tracking || m.pointer == "moves"
        if speaks {
            let obj = ObjectFactory.make(hit)
            if let t = textAt(p, in: hit, unit: m.textUnit) {
                // Text: the role on entering, when asked for, then the unit, each time it is a different piece.
                if entered, m.reportRole { said.append(obj.roleText ?? obj.role.displayString) }
                if t.key != lastTextKey {
                    lastTextKey = t.key
                    if t.text.contains(where: { !$0.isWhitespace }) { said.append(t.text) }
                }
            } else if entered {
                lastTextKey = nil
                said.append(contentsOf: Speech.objectPropertiesSpeech(obj, reason: .mouse))
            }
        }
        guard !said.isEmpty else { return }
        Speech.cancel()
        Speech.speakText(said.joined(separator: ", "))
    }

    /// The unit of text under the pointer, and a key that tells one piece from another: through WebKit's text markers
    /// in a page, through the standard text calls elsewhere. Nil where the item has no text to point into.
    private static func textAt(_ p: CGPoint, in e: AXUIElement, unit: String) -> (text: String, key: String)? {
        var pt = p
        guard let point = AXValueCreate(.cgPoint, &pt) else { return nil }
        if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading"].contains(e.role), let web = webArea(of: e) {
            return webText(point, web: web, unit: unit)
        }
        var r = CFRange()
        guard axValue(e.param(kAXRangeForPositionParameterizedAttribute, point), .cfRange, &r), r.location >= 0 else { return nil }
        let n = (e.attr(kAXNumberOfCharactersAttribute) as? Int) ?? 0
        guard n > 0 else { return nil }
        let i = min(r.location, n - 1)
        if unit == "line", let line = e.param(kAXLineForIndexParameterizedAttribute, i as CFNumber) as? Int {
            var lr = CFRange()
            if axValue(e.param(kAXRangeForLineParameterizedAttribute, line as CFNumber), .cfRange, &lr), let s = string(e, lr) {
                return (s, "\(lr.location):\(lr.length)")
            }
        }
        // A stretch around the point (a long document is never read whole), the unit found in it.
        let start = max(0, i - 4000), end = min(n, i + 4000)
        guard let window = string(e, CFRange(location: start, length: end - start)) else { return nil }
        let ns = window as NSString
        let u = MouseMath.unitRange(ns, at: i - start, unit: unit)
        guard u.length > 0, NSMaxRange(u) <= ns.length else { return ("", "\(start + u.location):0") }
        return (ns.substring(with: u), "\(start + u.location):\(u.length)")
    }

    private static func string(_ e: AXUIElement, _ r: CFRange) -> String? {
        var range = r
        guard let v = AXValueCreate(.cfRange, &range) else { return nil }
        if let s = e.param(kAXStringForRangeParameterizedAttribute, v) as? String { return s }
        // Some apps answer only the whole value.
        guard let all = e.string(kAXValueAttribute) as NSString?, r.location + r.length <= all.length else { return nil }
        return all.substring(with: NSRange(location: r.location, length: r.length))
    }

    private static func webArea(of e: AXUIElement) -> AXUIElement? {
        var x: AXUIElement? = e; var hops = 0
        while let y = x, hops < 30 {
            let role = y.role
            if role == "AXWebArea" { return y }
            if role == "AXWindow" || role == "AXApplication" { return nil }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    private static func webText(_ point: AXValue, web: AXUIElement, unit: String) -> (text: String, key: String)? {
        guard let mv = web.param("AXTextMarkerForPosition", point), CFGetTypeID(mv) == AXTextMarkerGetTypeID() else { return nil }
        let marker = mv as! AXTextMarker   // checked: a text marker
        let bridge = WebDocumentBridge(webArea: web)
        func range(_ attribute: String) -> AXTextMarkerRange? {
            guard let v = web.param(attribute, marker), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
            return (v as! AXTextMarkerRange)   // checked: a text marker range
        }
        var found: AXTextMarkerRange?
        switch unit {
        case "character":
            if let nv = web.param("AXNextTextMarkerForTextMarker", marker), CFGetTypeID(nv) == AXTextMarkerGetTypeID() {
                found = AXTextMarkerRangeCreate(kCFAllocatorDefault, marker, nv as! AXTextMarker)   // checked above
            }
        case "word":
            found = range("AXRightWordTextMarkerRangeForTextMarker")
            if let f = found, bridge.string(f).allSatisfy(\.isWhitespace) { found = range("AXLeftWordTextMarkerRangeForTextMarker") }
        case "line": found = range("AXLineTextMarkerRangeForTextMarker")
        default: found = range("AXParagraphTextMarkerRangeForTextMarker")
        }
        guard let f = found else { return nil }
        let key = bridge.indices(of: f).map { "web \($0.0):\($0.1)" } ?? "web \(bridge.string(f).hashValue)"
        return (bridge.string(f), key)
    }

    // MARK: VoiceOver's "Follows VoiceOver cursor"

    private static var followPending: AXUIElement?

    /// The review cursor moved (ObjectNavigator): with the pointer following it, the pointer goes to the item's
    /// middle. Once per turn of the main thread, however many moves the turn made.
    public static func cursorMoved(_ e: AXUIElement?) {
        guard let e, config.mouse.pointer == "follows" else { return }
        let first = followPending == nil
        followPending = e
        guard first else { return }
        DispatchQueue.main.async {
            guard let e = followPending else { return }
            followPending = nil
            guard Core.active, !Trackpad.controlOn, let r = TurnOverObject.frame(e), r.width > 0, r.height > 0 else { return }
            let p = CGPoint(x: r.midX, y: r.midY)
            let now = VoiceOverKeysPlugin.mouseLocation()
            guard desktop().contains(p), abs(now.x - p.x) > 1 || abs(now.y - p.y) > 1 else { return }
            // A warp makes no mouse event, so mouse tracking doesn't hear the cursor's own move back.
            CGWarpMouseCursorPosition(p)
        }
    }
}
