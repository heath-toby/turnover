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
    /// Kept a moment per element: every item asks of its view, and a long list's arrows asked of all its children
    /// each time (a review, 13 Nov 2026). Only the first few children are looked at.
    private static var viewCache: [(e: AXUIElement, yes: Bool, at: Date)] = []
    static func isView(_ e: AXUIElement) -> Bool {
        let now = Date()
        viewCache.removeAll { now.timeIntervalSince($0.at) > 2 }
        if let hit = viewCache.first(where: { CFEqual($0.e, e) }) { return hit.yes }
        var yes = false
        if e.role == "AXGroup", nameless(e) {
            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(e, kAXChildrenAttribute as CFString, &count)
            if count >= 2 {
                var v: CFArray?
                AXUIElementCopyAttributeValues(e, kAXChildrenAttribute as CFString, 0, 3, &v)
                let kids = (v as? [AXUIElement]) ?? []
                yes = !kids.isEmpty && kids.allSatisfy { $0.role == "AXGroup" } && !(kids[0].string(kAXTitleAttribute) ?? "").isEmpty && pressable(kids[0])
            }
        }
        viewCache.append((e, yes, now))
        if viewCache.count > 32 { viewCache.removeFirst() }
        return yes
    }

    /// A Qt table's column titles, for saying what it holds when its rows can't be read.
    static func columnTitles(_ e: AXUIElement) -> [String] {
        e.elements(kAXChildrenAttribute).filter { $0.role == "AXColumn" }.compactMap { $0.string(kAXTitleAttribute) }.filter { !$0.isEmpty }
    }

    /// Whether a titled group sits in a view, through titled items (a few levels of subfolders).
    private static func isItemChain(_ e: AXUIElement) -> Bool {
        var x: AXUIElement? = e; var hops = 0
        while let y = x, hops < 6 {
            guard let p = y.element(kAXParentAttribute) else { return false }
            if isView(p) { return true }
            guard p.role == "AXGroup", !(p.string(kAXTitleAttribute) ?? "").isEmpty else { return false }
            x = p; hops += 1
        }
        return false
    }

    /// The role an AXGroup has in a Qt app's item view, if it is one.
    static func role(of e: AXUIElement) -> Role? {
        // The app first (kept per process): every group made in every other app asked its role again (a review, 13 Nov 2026).
        guard isQt(e.pid), e.role == "AXGroup" else { return nil }
        // (Or a subfolder: an item inside an item, KeePassXC's "Surf Shark" under "Shared".)
        if !(e.string(kAXTitleAttribute) ?? "").isEmpty, pressable(e), let p = e.element(kAXParentAttribute),
           isView(p) || (p.role == "AXGroup" && !(p.string(kAXTitleAttribute) ?? "").isEmpty && pressable(p) && p.element(kAXParentAttribute).map { isView($0) || $0.role == "AXGroup" } == true && isItemChain(p)) { return .listItem }
        if isView(e) { return .list }
        // A table that gives its columns and no rows (KeePassXC's entries, Qt 5): a table, though its rows can't be read.
        if nameless(e), let first = e.elements(kAXChildrenAttribute).first, first.role == "AXColumn" { return .table }
        return nil
    }
}
