// SPDX-License-Identifier: GPL-3.0-or-later
// Dialogs that appear without the focus (11 Nov 2026). Two kinds were missed:
// - A sheet over a window, its focus left behind it: Bluetooth's Show Detail in System Settings was announced but Tab,
//   the arrows and object navigation stayed in the pane behind (a tester, 10 Nov 2026).
// - A window that opens beside the one in use and never takes the focus, with a progress bar: Finder's copy window
//   was announced, but its bar was never heard, since a bar is followed only once TurnOver has read it (ProgressWatch),
//   and nothing moved into the window (a tester, 10 Nov 2026).
// So a sheet whose app leaves the focus outside it is read (its text) and TurnOver lands on its safe button; a new
// window of the app in front that holds a progress bar is read and its bar followed. An app module may do its own
// (AppModule.sheetOpened).
import Foundation
import AppKit
import ApplicationServices

enum NewDialogs {
    /// A sheet was created; a moment later, if the focus is still outside it, TurnOver goes in.
    static func sheetAppeared(_ sheet: AXUIElement, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard sheet.role == "AXSheet", NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            if AppModuleHandler.shared.appModule(for: pid).sheetOpened(sheet) { return }
            if let f = API.focusObject?.element, isInside(f, sheet) { return }   // the app moved the focus in itself
            guard let target = landing(in: sheet) else { return }
            let words = text(of: sheet)
            Log.io("dialogs: a sheet opened with the focus outside it (\(words.count) characters of text); onto its \(target.role)")
            if !words.isEmpty { Speech.speakMessage(words) }
            land(on: target, interrupt: words.isEmpty)
        }
    }

    /// A window was created in the app in front; a moment later, one holding a progress bar is read and its bar followed.
    static func windowAppeared(_ window: AXUIElement, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard window.role == "AXWindow", let bar = firstProgressBar(in: window) else { return }
            let title = window.string(kAXTitleAttribute) ?? ""
            let words = [title, text(of: window)].filter { !$0.isEmpty }.joined(separator: ", ")
            Log.io("dialogs: a window with a progress bar appeared (\(words.count) characters); its bar followed")
            if !words.isEmpty { Speech.speakMessage(words) }
            ProgressWatch.watch(ObjectFactory.make(bar))
        }
    }

    /// TurnOver on a control: the keyboard focus asked for, and if the app keeps it elsewhere, the place held (Space
    /// and Return press it), with object navigation from there.
    static func land(on e: AXUIElement, interrupt: Bool) {
        _ = e.set(kAXFocusedAttribute, kCFBooleanTrue)
        let pid = e.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let real = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
            if let real, real.isSame(e) {
                if !interrupt, API.focusObject?.isSameElement(as: e) != true { Speech.speakObject(ObjectFactory.make(e), reason: .focus) }
                return   // the app took it: its own focus news says it
            }
            SettingsPanePlugin.holdVirtual(e, speak: interrupt)
            if !interrupt { Speech.speakObject(ObjectFactory.make(e), reason: .focus) }
            ObjectNavigator.shared.releaseHold()
            ObjectNavigator.shared.place(e)
        }
    }

    /// Where a dialog opens: its default button, else its Done, OK, Close or Cancel, else its first control. Never a
    /// first control like Bluetooth's "Forget This Device…", which Space would press, when a safe one is there.
    static func landing(in root: AXUIElement) -> AXUIElement? {
        if let d = root.element(kAXDefaultButtonAttribute) { return d }
        let controls = SettingsPanePlugin.controlsInOrder(in: root)
        let safe = ["Done", "OK", "Close", "Cancel"]
        return controls.first { c in safe.contains(c.string(kAXDescriptionAttribute) ?? "") || safe.contains(c.string(kAXTitleAttribute) ?? "") } ?? controls.first
    }

    /// A dialog's text as it is read when it opens: its static texts in order, a text inside a text with the same words
    /// said once; at most 400 characters.
    static func text(of root: AXUIElement) -> String {
        var out: [String] = []
        var visited = 0
        func walk(_ e: AXUIElement) {
            guard visited < 300 else { return }
            visited += 1
            if e.role == "AXStaticText", let v = e.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, out.last != v { out.append(v) }
            for k in e.elements(kAXChildrenAttribute) { walk(k) }
        }
        walk(root)
        let joined = out.joined(separator: ", ")
        return joined.count > 400 ? String(joined.prefix(400)) : joined
    }

    static func firstProgressBar(in root: AXUIElement) -> AXUIElement? {
        var queue = [root], visited = 0
        while !queue.isEmpty, visited < 200 {
            let e = queue.removeFirst(); visited += 1
            if e.role == "AXProgressIndicator" { return e }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    static func isInside(_ e: AXUIElement, _ root: AXUIElement) -> Bool {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 25 { if x.isSame(root) { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }
}
