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
import ApplicationServices

extension SettingsPanePlugin {
    /// Windows where Tab has been seen to loop short (main thread).
    static var loopWindows: [AXUIElement] = []
    /// Where each Tab landed lately in the window it was pressed in, latest last.
    static var tabLandings: (window: AXUIElement, landed: [AXUIElement])?

    /// Whether `e` is in a window where Tab is TurnOver's.
    static func inLoopWindow(_ e: AXUIElement) -> Bool {
        guard !loopWindows.isEmpty, let w = windowOf(e) else { return false }
        loopWindows.removeAll { $0.role == "?" }   // closed windows
        return loopWindows.contains { $0.isSame(w) }
    }

    /// A Tab or Shift Tab the app had: where it landed, and whether the landings show a short loop.
    static func watchTabLoop(_ g: KeyboardGesture) {
        guard g.keyName == "tab", g.modifiers.subtracting(.shift).isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard let f = API.focusObject, let window = windowOf(f.element), !inLoopWindow(f.element) else { return }
            var landed = tabLandings.flatMap { $0.window.isSame(window) ? $0.landed : nil } ?? []
            landed.append(f.element)
            if landed.count > 12 { landed.removeFirst(landed.count - 12) }
            tabLandings = (window, landed)
            guard let period = shortLoop(landed.map(Hashed.init)) else { return }
            let all = controls(in: window, toolbars: true)
            guard all.count >= period + 3 else { return }
            Log.io("tab loop: Tab goes round \(period) controls of \(all.count) in this window; Tab here is TurnOver's from now")
            loopWindows.append(window)
            if loopWindows.count > 20 { loopWindows.removeFirst() }
            tabLandings = nil
            setTrapState(for: f.element)
        }
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
