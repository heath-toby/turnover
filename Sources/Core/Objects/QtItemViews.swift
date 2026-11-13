// SPDX-License-Identifier: GPL-3.0-or-later
// Qt's item views on the Mac (13 Nov 2026, KeePassXC 2.7 with Qt 5.15). A tree or list view comes through as a nameless
// group holding a group per item, each titled with the item's text and pressable, with no selection, level or role
// of its own. Tab onto KeePassXC's folder tree said nothing at all, and each folder was "Root grouping". Here the
// holder is a list and each item a list item, so Tab says "list, 8 items" and the arrows "Root, 1 of 8".
import Foundation
import AppKit
import ApplicationServices

enum QtItemViews {
    private static var qt: [pid_t: Bool] = [:]
    /// Built with Qt: its bundle carries Qt's core framework.
    static func isQt(_ pid: pid_t) -> Bool {
        if let known = qt[pid] { return known }
        var yes = false
        if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL {
            let fw = url.appendingPathComponent("Contents/Frameworks")
            yes = ["QtCore.framework", "QtGui.framework", "QtWidgets.framework"].contains { FileManager.default.fileExists(atPath: fw.appendingPathComponent($0).path) }
                // Qt's Mac platform plugin, however Qt itself is bundled (KeePassXC carries Qt 5 as plain libraries).
                || FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/PlugIns/platforms/libqcocoa.dylib").path)
                || ((try? FileManager.default.contentsOfDirectory(atPath: fw.path)) ?? []).contains { $0.hasPrefix("libQt5Core") || $0.hasPrefix("libQt6Core") }
        }
        qt[pid] = yes
        return yes
    }

    private static func nameless(_ e: AXUIElement) -> Bool {
        (e.string(kAXTitleAttribute) ?? "").isEmpty && (e.string(kAXDescriptionAttribute) ?? "").isEmpty
    }
    private static func pressable(_ e: AXUIElement) -> Bool {
        var acts: CFArray?
        guard AXUIElementCopyActionNames(e, &acts) == .success else { return false }
        return ((acts as? [String]) ?? []).contains(kAXPressAction)
    }
    /// A nameless group of two or more groups, the first titled and pressable: an item view.
    static func isView(_ e: AXUIElement) -> Bool {
        guard e.role == "AXGroup", nameless(e) else { return false }
        let kids = e.elements(kAXChildrenAttribute)
        guard kids.count >= 2, kids.allSatisfy({ $0.role == "AXGroup" }) else { return false }
        return !(kids[0].string(kAXTitleAttribute) ?? "").isEmpty && pressable(kids[0])
    }

    /// The role an AXGroup has in a Qt app's item view, if it is one.
    static func role(of e: AXUIElement) -> Role? {
        guard e.role == "AXGroup", isQt(e.pid) else { return nil }
        if !(e.string(kAXTitleAttribute) ?? "").isEmpty, pressable(e), let p = e.element(kAXParentAttribute), isView(p) { return .listItem }
        if isView(e) { return .list }
        return nil
    }
}
