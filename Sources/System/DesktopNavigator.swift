// SPDX-License-Identifier: GPL-3.0-or-later
// The desktop as you lay it out (a tester's design, 12 Nov 2026): the arrows go left, right, up and down through its
// icons and widgets by where they sit; Tab and Shift Tab go through them in reading order; Return opens an icon, and on
// a widget goes into it, where Up and Down read it line by line and Escape comes back out. Option D (Windows+D) goes
// to the desktop; landing on the desktop by any other way (all windows closed, a click) does too.
//
// Measured 12 Nov 2026, macOS 27.2: Finder's application element holds an AXScrollArea (subrole AXDesktop) with one
// AXGroup (AXDesktop): the icons are AXImage children (AXOpen, AXShowMenu) and each widget an AXGroup holding an
// AXHostingView holding the widget's group (identifier widget-local:…, description its name: Weather, Clock), whose
// parts keep their words in AXUnknown descriptions, some in named groups (Hourly Forecast, Daily Forecast).
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

final class DesktopNavigatorPlugin: GlobalPlugin {
    required init() {
        super.init()
        let cat = "Desktop"
        let keys: [(String, String, [String], () -> Void)] = [
            ("desktop_right", String(localized: "On the desktop: the item to the right (in a widget: nothing)", comment: "A command, as the key list and keyboard help say it"), ["rightArrow"], { DesktopNavigator.move(.right) }),
            ("desktop_left", String(localized: "On the desktop: the item to the left", comment: "A command, as the key list and keyboard help say it"), ["leftArrow"], { DesktopNavigator.move(.left) }),
            ("desktop_down", String(localized: "On the desktop: the item below; in a widget, its next line", comment: "A command, as the key list and keyboard help say it"), ["downArrow"], { DesktopNavigator.move(.down) }),
            ("desktop_up", String(localized: "On the desktop: the item above; in a widget, its previous line", comment: "A command, as the key list and keyboard help say it"), ["upArrow"], { DesktopNavigator.move(.up) }),
            ("desktop_next", String(localized: "On the desktop: the next item in reading order", comment: "A command, as the key list and keyboard help say it"), ["tab"], { DesktopNavigator.step(1) }),
            ("desktop_previous", String(localized: "On the desktop: the previous item in reading order", comment: "A command, as the key list and keyboard help say it"), ["shift+tab"], { DesktopNavigator.step(-1) }),
            ("desktop_first", String(localized: "On the desktop: the first item", comment: "A command, as the key list and keyboard help say it"), ["home"], { DesktopNavigator.edge(last: false) }),
            ("desktop_last", String(localized: "On the desktop: the last item", comment: "A command, as the key list and keyboard help say it"), ["end"], { DesktopNavigator.edge(last: true) }),
            ("desktop_open", String(localized: "On the desktop: opens the icon, or goes into the widget; in a widget, opens its app at the line", comment: "A command, as the key list and keyboard help say it"), ["enter", "space"], { DesktopNavigator.open() }),
            ("desktop_out", String(localized: "On the desktop: out of the widget; at the desktop, back to the application", comment: "A command, as the key list and keyboard help say it"), ["escape"], { DesktopNavigator.out() }),
        ]
        for (name, desc, gestures, run) in keys {
            script(name, desc, gestures: gestures.map { "kb:" + $0 }, category: cat) { _ in DesktopNavigator.ownKey(); run() }.isAvailable = { DesktopNavigator.stillActive }
        }
    }
}

package enum DesktopNavigator {
    enum Direction { case left, right, up, down }
    struct Item { let element: AXUIElement; let frame: CGRect; let name: String; let isWidget: Bool }
    struct Line { let element: AXUIElement; let words: String; let heading: Bool }

    static var active = false
    /// The app in front when the desktop was entered (Option D works from any app).
    private static var enteredOver: pid_t?
    /// Active, and the app in front then still in front: another app come forward ends it. Left on, Tab in System
    /// Settings went round the desktop's widgets (13 Nov 2026).
    static var stillActive: Bool {
        guard active, !AXHandler.shared.isMenuOpen else { return false }   // (a menu open over it has its keys)
        if let p = enteredOver, NSWorkspace.shared.frontmostApplication?.processIdentifier != p {
            active = false; lines = nil; Log.io("desktop: another app in front; left"); return false
        }
        // A key since the navigator's last that wasn't the navigator's (typing in the app in front, Command-Tab
        // within it, a click's keys): the user is back in the app, and Space and Return there opened a desktop item
        // instead (a review, 13 Nov 2026). The key being asked about now is the one after the navigator's last.
        if !keysOnlyOwn(arrived: ScriptHandler.keysArrivedCount, own: ownKeys) {
            active = false; lines = nil; Log.io("desktop: another key in between; left"); return false
        }
        return true
    }
    /// The count of keys that had arrived when the navigator (or Option D) last took one.
    private static var ownKeys = 0
    static func ownKey() { ownKeys = ScriptHandler.keysArrivedCount }
    /// No key between the navigator's last and the one being asked about (pure, for the tests).
    package nonisolated static func keysOnlyOwn(arrived: Int, own: Int) -> Bool { arrived &- own <= 1 }
    private static var current: AXUIElement?
    /// Inside a widget: its lines and where TurnOver is among them.
    private static var lines: [Line]?
    private static var lineIndex = 0

    static var finder: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first }

    /// Finder's desktop group: the icons and widgets are its children.
    static func desktopGroup() -> AXUIElement? {
        guard let f = finder else { return nil }
        let app = AXUIElementCreateApplication(f.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let area = app.elements(kAXChildrenAttribute).first(where: { $0.string(kAXSubroleAttribute) == "AXDesktop" }) else { return nil }
        return area.elements(kAXChildrenAttribute).first
    }

    /// The desktop's items in reading order (rows top to bottom, then left to right).
    static func items() -> [Item] {
        guard let desk = desktopGroup() else { return [] }
        var out: [Item] = []
        for c in desk.elements(kAXChildrenAttribute) {
            guard let f = TurnOverObject.frame(c), f.width > 0 else { continue }
            if c.role == "AXGroup" {
                // A widget: its own group, two levels in, is named and holds the words.
                let widget = c.elements(kAXChildrenAttribute).first?.elements(kAXChildrenAttribute).first ?? c
                let name = widget.string(kAXDescriptionAttribute) ?? ""
                out.append(Item(element: widget, frame: f, name: name.isEmpty ? String(localized: "widget", comment: "A desktop widget with no name") : name, isWidget: true))
            } else {
                let name = c.string(kAXTitleAttribute) ?? c.string(kAXDescriptionAttribute) ?? ""
                guard !name.isEmpty else { continue }
                out.append(Item(element: c, frame: f, name: name, isWidget: false))
            }
        }
        return out.sorted { a, b in
            let ra = Int(a.frame.minY / 40), rb = Int(b.frame.minY / 40)
            return ra != rb ? ra < rb : a.frame.minX < b.frame.minX
        }
    }

    /// To the desktop: TurnOver's cursor on its first item (or the one it was on), said with how many there are.
    static func enter() {
        let all = items()
        guard !all.isEmpty else { Speech.speakMessage(String(localized: "Desktop, empty", comment: "Spoken message")); return }
        active = true; lines = nil
        ownKey()
        enteredOver = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let i = current.flatMap { c in all.firstIndex { $0.element.isSame(c) } } ?? 0
        Log.io("desktop: in, \(all.count) items")
        Speech.cancel()
        Speech.speakMessage(String(localized: "Desktop, \(Phrases.items(all.count))", comment: "The desktop reached: how many icons and widgets"))
        land(all, i, interrupt: false)
    }

    static func leave() {
        guard active else { return }
        active = false; lines = nil
        Log.io("desktop: out")
    }

    static func move(_ d: Direction) {
        if var ls = lines {
            switch d {
            case .down, .up:
                let n = lineIndex + (d == .down ? 1 : -1)
                // A widget whose parts were rebuilt meanwhile: read afresh.
                if let w = current, ls.isEmpty || ls[0].element.role == "?" { ls = widgetLines(w); lines = ls }
                guard ls.indices.contains(n) else { Tones.edge(); return }
                lineIndex = n
                sayLine(ls[n], index: n, count: ls.count)
            case .left, .right: Tones.edge()
            }
            return
        }
        let all = items()
        guard !all.isEmpty else { return }
        guard let here = current.flatMap({ c in all.firstIndex { $0.element.isSame(c) } }) else { land(all, 0); return }
        let from = all[here].frame
        let c = CGPoint(x: from.midX, y: from.midY)
        // The nearest item that way, preferring one in line (overlapping across the move) over one off to the side.
        let candidates = all.indices.filter { $0 != here }.filter { j in
            let f = all[j].frame
            switch d {
            case .right: return f.midX > from.maxX - 4
            case .left: return f.midX < from.minX + 4
            case .down: return f.midY > from.maxY - 4
            case .up: return f.midY < from.minY + 4
            }
        }
        // Only an item in line that way (overlapping across the move), as on a grid: none, and it's an edge (Down from
        // the last icon in a column went to a widget across the screen, 12 Nov 2026). Among them the nearest, then
        // the one lined up best: its top with this one's for Left and Right, its left edge for Up and Down.
        func inLine(_ j: Int) -> Bool {
            let f = all[j].frame
            switch d {
            case .left, .right: return f.minY < from.maxY && f.maxY > from.minY
            case .up, .down: return f.minX < from.maxX && f.maxX > from.minX
            }
        }
        func score(_ j: Int) -> CGFloat {
            let f = all[j].frame
            let along = d == .left || d == .right ? abs(f.midX - c.x) : abs(f.midY - c.y)
            let aligned = d == .left || d == .right ? abs(f.minY - from.minY) : abs(f.minX - from.minX)
            return along + aligned * 1.5
        }
        let lined = candidates.filter(inLine)
        guard let best = lined.min(by: { score($0) < score($1) }) else { Tones.edge(); return }
        land(all, best)
    }

    static func step(_ delta: Int) {
        if lines != nil { move(delta > 0 ? .down : .up); return }
        let all = items()
        guard !all.isEmpty else { return }
        let here = current.flatMap { c in all.firstIndex { $0.element.isSame(c) } } ?? -1
        let n = here + delta
        guard all.indices.contains(n) else { Tones.edge(); return }
        land(all, n)
    }

    static func edge(last: Bool) {
        if let ls = lines, !ls.isEmpty { lineIndex = last ? ls.count - 1 : 0; sayLine(ls[lineIndex], index: lineIndex, count: ls.count); return }
        let all = items()
        guard !all.isEmpty else { return }
        land(all, last ? all.count - 1 : 0)
    }

    /// Return or Space: an icon opens (Finder's own Open); a widget is gone into.
    static func open() {
        guard let c = current else { return }
        // In a widget: the line pressed, which opens the widget's app there (a tester, 13 Nov 2026: "click on an item in
        // the widget to open its app").
        if let ls = lines, ls.indices.contains(lineIndex) {
            if Self.pressLine(ls[lineIndex].element) { lines = nil; leave() } else { Tones.edge() }
            return
        }
        let all = items()
        guard let item = all.first(where: { $0.element.isSame(c) }) else { return }
        if item.isWidget {
            let ls = widgetLines(item.element)
            guard !ls.isEmpty else { Speech.speakMessage(String(localized: "nothing to read in it", comment: "A desktop widget with no words")); return }
            lines = ls; lineIndex = 0
            Tones.press()
            Log.io("desktop: into the \(item.name) widget, \(ls.count) lines")
            Speech.cancel()
            Speech.speakMessage(String(localized: "in \(item.name)", comment: "Gone into a desktop widget: its name"))
            sayLine(ls[0], index: 0, count: ls.count, interrupt: false)
            return
        }
        let r = AXUIElementPerformAction(item.element, "AXOpen" as CFString)
        Log.io("desktop: opened \(Log.words(item.name)) → \(describeError(r))")
        if r == .success { Tones.press(); leave() }
    }

    /// A widget's line pressed: its own press, or its nearest pressable parent's, else a click on it (widgets draw
    /// their items as text and pictures that open the app where they are clicked).
    static func pressLine(_ e: AXUIElement) -> Bool {
        var x: AXUIElement? = e, hops = 0
        while let y = x, hops < 4 {
            var names: CFArray?
            AXUIElementCopyActionNames(y, &names)
            if ((names as? [String]) ?? []).contains(kAXPressAction as String) {
                let r = AXUIElementPerformAction(y, kAXPressAction as CFString)
                Log.io("widget: pressed \(y.role) → \(describeError(r))")
                if r == .success { Tones.press(); return true }
                break
            }
            x = y.element(kAXParentAttribute); hops += 1
        }
        guard let f = TurnOverObject.frame(e), f.width > 0, f.height > 0 else { return false }
        Log.io("widget: clicked a line (\(e.role))")
        Tones.press()
        Mouse.click(at: CGPoint(x: f.midX, y: f.midY), button: .left, count: 1)
        return true
    }

    /// Escape: out of the widget; at the desktop itself, back to the application's focus.
    static func out() {
        if lines != nil {
            lines = nil
            let all = items()
            if let c = current, let i = all.firstIndex(where: { $0.element.isSame(c) }) { land(all, i) }
            return
        }
        leave()
        ObjectNavigator.shared.toFocus()
    }

    /// A widget's lines: each part's words, in order, with its named groups (Hourly Forecast) as headings.
    static func widgetLines(_ w: AXUIElement) -> [Line] {
        var out: [Line] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 8, out.count < 200 else { return }
            for c in e.elements(kAXChildrenAttribute) {
                let words = [c.string(kAXDescriptionAttribute), c.string(kAXTitleAttribute), c.string(kAXValueAttribute)]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
                let kids = c.elements(kAXChildrenAttribute)
                if !kids.isEmpty {
                    if !words.isEmpty { out.append(Line(element: c, words: words, heading: true)) }
                    walk(c, depth + 1)
                } else if !words.isEmpty {
                    out.append(Line(element: c, words: words, heading: false))
                }
            }
        }
        walk(w, 0)
        return out
    }

    private static func sayLine(_ l: Line, index: Int, count: Int, interrupt: Bool = true) {
        ObjectNavigator.shared.place(l.element)
        Tones.focusTick()
        if interrupt { Speech.cancel() }
        var words = l.words
        if l.heading { words += ", " + String(localized: "heading", comment: "A role: a heading") }
        Speech.speakItem(words + ", " + Phrases.position(index + 1, of: count))
    }

    /// On an item: TurnOver's cursor there (the context menu key opens its menu), said with its kind and place.
    private static func land(_ all: [Item], _ i: Int, interrupt: Bool = true) {
        let item = all[i]
        current = item.element
        ObjectNavigator.shared.place(item.element)
        Tones.focusTick()
        if interrupt { Speech.cancel() }
        var parts = [item.name]
        if item.isWidget {
            parts.append(String(localized: "widget", comment: "A role: a desktop widget"))
            // Its first words, so the weather or the time is heard without going in.
            if let first = widgetLines(item.element).first(where: { !$0.heading }) { parts.append(first.words) }
        } else {
            parts.append(kind(of: item.element) ?? String(localized: "icon", comment: "A role: a desktop icon"))
        }
        parts.append(Phrases.position(i + 1, of: all.count))
        Speech.speakItem(parts.joined(separator: ", "))
    }

    /// What an icon is, as Finder's Get Info says it ("volume", "folder", "PDF document"): every icon was "icon" (a
    /// tester, 12 Nov 2026). The icon's AXURL is its file.
    static func kind(of icon: AXUIElement) -> String? {
        guard let url = icon.attr(kAXURLAttribute) as? URL ?? (icon.attr(kAXURLAttribute) as? NSURL).map({ $0 as URL }),
              let k = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription, !k.isEmpty else { return nil }
        // "Volume", "Folder": said as a role, in lower case, but not a name in capitals ("PDF document" stays).
        return k.prefix(2).allSatisfy(\.isUppercase) ? k : k.prefix(1).lowercased() + k.dropFirst()
    }

    /// A real focus change: on Finder's desktop itself, TurnOver goes to the desktop; anywhere else, out of it.
    static func focusChanged(_ target: AXUIElement, pid: pid_t) {
        let onDesktop = pid == finder?.processIdentifier && (target.string(kAXSubroleAttribute) == "AXDesktop"
            || target.element(kAXParentAttribute)?.string(kAXSubroleAttribute) == "AXDesktop")
        if onDesktop { if !active { DispatchQueue.main.async { enter() } } }
        else if active { leave() }
    }
}
