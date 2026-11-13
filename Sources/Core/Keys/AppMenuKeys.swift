// SPDX-License-Identifier: GPL-3.0-or-later
// The keys an application's own menus use. The Windows style's Option keys (Option B, Option D, Option Shift D) were TurnOver's in every app, and REAPER's Option B (Virtual MIDI Keyboard) and Option D (Duplicate
// Tracks) never reached it (found by reading the tester's apps' menus, 13 Nov 2026). Such a key goes to an app whose
// menus have it. The menus are read off the main thread as the app comes to the front, and again after two minutes.
import Foundation
import AppKit
import ApplicationServices

enum AppMenuKeys {
    private static var keys: [pid_t: (at: Date, set: Set<String>)] = [:]
    private static var scanning: Set<pid_t> = []

    /// The app's menus have this key ("kb:option+b"). False while they are still being read.
    static func owns(_ gesture: String, pid: pid_t) -> Bool {
        guard let k = keys[pid] else { scan(pid); return false }
        if Date().timeIntervalSince(k.at) > 120 { scan(pid) }
        return k.set.contains(normalizeGestureIdentifier(gesture))
    }

    /// Read the app's menu keys in the background (an app with a large menu bar takes a moment).
    static func scan(_ pid: pid_t, delay: TimeInterval = 0) {
        // Only for the Windows style, the only one whose keys ask (GlobalCommands.leftToApp): the walk asked the app
        // thousands of questions just as it came to the front, in every style (a review, 13 Nov 2026).
        guard KeySettings.current.windowsKeys else { return }
        // Read once in two minutes at most: every Command Tab walked the whole menu bar again (a review, 13 Nov 2026).
        if let k = keys[pid], Date().timeIntervalSince(k.at) < 120 { return }
        guard !scanning.contains(pid), pid != getpid() else { return }
        scanning.insert(pid)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            let set = read(pid)
            DispatchQueue.main.async {
                scanning.remove(pid)
                keys[pid] = (Date(), set)
                if keys.count > 40 { keys = keys.filter { NSRunningApplication(processIdentifier: $0.key) != nil } }
                Log.debug("menu keys: pid \(pid), \(set.count)")
            }
        }
    }

    /// The keys `owns` is asked about (GlobalCommands.leftToApp): the walk stops once the menus are found to have them
    /// all (a review, 13 Nov 2026). A new question about another key must add it here, or it is never found.
    nonisolated static let asked: Set<String> = Set(["kb:option+d", "kb:option+shift+d", "kb:option+b"].map(normalizeGestureIdentifier))

    /// Keys of the menu items under the app's menu bar, as gesture identifiers. Bounded: 4,000 elements, seven deep,
    /// and done once all the keys asked about are found.
    nonisolated static func read(_ pid: pid_t) -> Set<String> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
        guard let barRef = attr(app, kAXMenuBarAttribute), CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return [] }
        let named: [Int: String] = [48: "tab", 53: "escape", 49: "space", 36: "enter", 51: "backspace", 123: "leftArrow", 124: "rightArrow",
                                    125: "downArrow", 126: "upArrow", 115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
                                    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
        var out: Set<String> = []
        var stack: [(AXUIElement, Int)] = [(barRef as! AXUIElement, 0)]
        var visited = 0, failures = 0
        let started = Date()
        // Each element's role, key, modifiers and children in one question, not up to six (the walk competes with the
        // app as it comes to the front: a review, 13 Nov 2026). A failed or missing one comes back as an error value.
        let names = [kAXRoleAttribute, "AXMenuItemCmdVirtualKey", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", kAXChildrenAttribute] as CFArray
        func value(_ v: AnyObject) -> AnyObject? {
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
        while let (e, depth) = stack.popLast(), visited < 4000, failures < 3, Date().timeIntervalSince(started) < 5, !out.isSuperset(of: asked) {
            visited += 1
            // An app that stops answering: given up on after three timeouts or five seconds, not held for minutes.
            AXUIElementSetMessagingTimeout(e, 0.5)
            var raw: CFArray?
            let err = AXUIElementCopyMultipleAttributeValues(e, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
            if err == .cannotComplete { failures += 1; continue }
            guard err == .success, let a = raw as? [AnyObject], a.count == 5 else { continue }
            if (value(a[0]) as? String) == "AXMenuItem" {
                var key = ""
                if let code = value(a[1]) as? Int, let n = named[code] { key = n }
                else if let c = value(a[2]) as? String, let s = c.unicodeScalars.first, s.value > 32, s.value < 0xF700 { key = c.lowercased() }
                if !key.isEmpty {
                    // AX's modifiers: 1 Shift, 2 Option, 4 Control, 8 no Command.
                    let m = (value(a[3]) as? Int) ?? 0
                    var mods: [String] = []
                    if m & 4 != 0 { mods.append("control") }
                    if m & 2 != 0 { mods.append("option") }
                    if m & 1 != 0 { mods.append("shift") }
                    if m & 8 == 0 { mods.append("command") }
                    out.insert(normalizeGestureIdentifier("kb:" + (mods + [key]).joined(separator: "+")))
                }
            }
            guard depth < 7 else { continue }
            for c in (value(a[4]) as? [AXUIElement]) ?? [] { stack.append((c, depth + 1)) }
        }
        return out
    }
}
