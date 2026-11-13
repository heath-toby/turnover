// SPDX-License-Identifier: GPL-3.0-or-later
// Tab that only goes round a few controls (11 Nov 2026). With VoiceOver off, some windows keep Tab in a short loop
// and never let it reach the rest: System Settings went sidebar, search field, sidebar (its pane never); TextEdit's
// Open dialog went list, sidebar, search field and never reached Open, Cancel or New Document (measured with a key
// driver and TurnOver's log, macOS 27.2). With VoiceOver running, both reach everything: they shape their Tab order
// for VoiceOver, and TurnOver turns VoiceOver off.
//
// So: where Tab is seen to come back to the same two to four controls, twice round, in a window holding at least
// three controls more, the window is remembered as one where Tab is TurnOver's. From then on Tab and Shift Tab there go
// through every control in screen order (the tab trap's move: the keyboard focus where the app takes it, the place
// held where it doesn't, so Space and Return press it). A window is forgotten when it closes.
import Foundation
import AppKit
import ApplicationServices

extension SettingsPanePlugin {
    /// Windows where Tab has been seen to loop short (main thread).
    static var loopWindows: [AXUIElement] = []
    /// Where each Tab landed lately in the window it was pressed in, latest last: Tabs in one direction, one after
    /// another, each within 3 s of the last. Tab and Shift Tab between two fields land B, A, B, A, which is no loop
    /// (a review, 11 Nov 2026).
    static var tabLandings: (window: AXUIElement, landed: [AXUIElement], forward: Bool, at: Date)?

    /// Fields and web content keep their own Tab: a text field commits on Tab (Mail's To), a page's Tab goes from link
    /// to link in browse mode, a document's Tab types (a review, 11 Nov 2026).
    static func keepsOwnTab(_ e: AXUIElement) -> Bool {
        // (From the focus's chain, read once per focus move: the same element and twenty parents. A review, 13 Nov 2026.)
        if let c = FocusChain.of(e) {
            return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"].contains(c.roles[0]) || c.has("AXWebArea", from: 1, to: 21)
        }
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"].contains(e.role) { return true }
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 20 { if x.role == "AXWebArea" { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    /// Whether `e` is in a window where Tab is TurnOver's.
    static func inLoopWindow(_ e: AXUIElement) -> Bool {
        // A Save sheet is one too (TextEdit's "keep this new document?": Tab went name, tags, name, 12 Nov 2026). Not
        // remembered: the window stays when the sheet goes.
        if let sheet = scopeOf(e), sheet.role == "AXSheet", let id = sheet.string(kAXIdentifierAttribute), ["open-panel", "save-panel"].contains(id) { return true }
        guard let w = windowOf(e) else { return false }
        loopWindows.removeAll { $0.role == "?" }   // closed windows
        if loopWindows.contains(where: { $0.isSame(w) }) { return true }
        // Open and Save panels, in every app: their Tab goes list, sidebar, search field and never reaches New
        // Document, Open or Cancel, and before this it took seven Tabs in each new app to see (TextEdit, 12 Nov 2026).
        // macOS names them.
        if let id = w.string(kAXIdentifierAttribute), ["open-panel", "save-panel"].contains(id) { loopWindows.append(w); return true }
        // The same kind of window seen looping before (each Save sheet is a new window: four Tabs each time before
        // TurnOver took over): the app and the window's title.
        if let k = loopKind(w), loopKinds.contains(k) { loopWindows.append(w); return true }
        return false
    }
    /// Kinds of window seen to loop: "bundle|title" (main thread; this run only).
    static var loopKinds: Set<String> = []
    static func loopKind(_ w: AXUIElement) -> String? {
        let title = w.string(kAXTitleAttribute) ?? ""
        guard !title.isEmpty, let id = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier else { return nil }
        return id + "|" + title
    }

    /// A Tab or Shift Tab the app had: where it landed, and whether the landings show a short loop.
    static func watchTabLoop(_ g: KeyboardGesture) {
        guard g.keyName == "tab", g.modifiers.subtracting(.shift).isEmpty else { tabLandings = nil; return }
        let forward = !g.modifiers.contains(.shift), pressed = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard let f = API.focusObject else { return }
            noteLanding(f.element, forward: forward, pressed: pressed)
        }
    }

    /// Where a Tab or Shift Tab landed, the app's or TurnOver's own: both count towards a loop. Grapher's Tab went
    /// from its list to Cancel by TurnOver and back to the list by Grapher, round and round, never seen as a loop
    /// while only the app's landings were counted (11 Nov 2026).
    static func noteLanding(_ e: AXUIElement, forward: Bool, pressed: Date = Date()) {
        do {
            let f = ObjectFactory.make(e)
            guard let window = windowOf(f.element), !inLoopWindow(f.element) else { return }
            // Web content and fields are never counted: Safari's address field and page search with "Tab highlights
            // each item" off are a real loop of two, and the page's Tab is browse mode's.
            // A single-line field is a landing like any other (System Settings' loop went through its search field); Tab
            // is still the field's own while it has the focus (keepsOwnTab in setTrapState).
            if isInWeb(f.element) || (keepsOwnTab(f.element) && !["AXTextField", "AXSearchField"].contains(f.element.role)) { tabLandings = nil; return }
            var landed: [AXUIElement] = []
            if let t = tabLandings, t.window.isSame(window), t.forward == forward, pressed.timeIntervalSince(t.at) < 3 { landed = t.landed }
            landed.append(f.element)
            if landed.count > 12 { landed.removeFirst(landed.count - 12) }
            tabLandings = (window, landed, forward, pressed)
            guard let period = shortLoop(landed.map(Hashed.init)) else { return }
            let all = controls(in: window, toolbars: true)
            guard all.count >= period + 3 else { return }
            Log.io("tab loop: Tab goes round \(period) controls of \(all.count) in this window; Tab here is TurnOver's from now")
            loopWindows.append(window)
            if let k = loopKind(window) { loopKinds.insert(k) }
            if loopWindows.count > 20 { loopWindows.removeFirst() }
            tabLandings = nil
            setTrapState(for: f.element)
        }
    }

    static func isInWeb(_ e: AXUIElement) -> Bool {
        if let c = FocusChain.of(e) { return c.has("AXWebArea", to: 20) }   // the element and nineteen parents, as below
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 20 { if x.role == "AXWebArea" { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    /// An element compared as the accessibility API compares them.
    struct Hashed: Equatable {
        let e: AXUIElement
        static func == (a: Hashed, b: Hashed) -> Bool { CFEqual(a.e, b.e) }
    }

    /// The loop's length when the last landings repeat with a period of 2 to 4, seen twice round; nil otherwise. A
    /// period of 1 (Tab ignored) is the tab trap's own case.
    package static func shortLoop<T: Equatable>(_ landed: [T]) -> Int? {
        for p in 2...4 where landed.count >= 2 * p {
            let tail = Array(landed.suffix(2 * p))
            let first = Array(tail.prefix(p)), second = Array(tail.suffix(p))
            // Twice round the same p different places.
            guard first == second else { continue }
            var distinct: [T] = []
            for x in first where !distinct.contains(x) { distinct.append(x) }
            if distinct.count == p { return p }
        }
        return nil
    }
}
