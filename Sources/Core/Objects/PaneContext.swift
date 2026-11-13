// SPDX-License-Identifier: GPL-3.0-or-later
// Where a control sits in a settings pane, said as the focus comes into it, as NVDA says a dialog's property page and
// its groupings (a tester, 13 Nov 2026: "Location Services property page, Allow the applications and services below
// to determine your location", then "Text Input grouping" in Keyboard). System Settings draws a pane as a scroll area
// of sections: nameless groups, each after the heading that names it (the first has none: the pane's name is its).
// - Into the pane from outside it (the sidebar, the search field): "<pane> property page", and the pane's description
//   where it has one (the line under its first control's label).
// - Into another section: "<heading> grouping".
// - A button named only for what it does ("Edit…") says the row it stands in first: "Input Sources, British – PC,
//   German and 2 others, Edit… button".
import Foundation
import ApplicationServices

enum PaneContext {
    /// The pane `e` is in: a scroll area whose children are the form's sections (groups, headings between them).
    static func pane(of e: AXUIElement) -> AXUIElement? {
        var p: AXUIElement? = e.element(kAXParentAttribute), hops = 0
        while let x = p, hops < 8 {
            if x.role == "AXScrollArea", isForm(x) { return x }
            if ["AXWindow", "AXSheet", "AXWebArea"].contains(x.role) { return nil }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    /// A form's scroll area: one section or more (groups), and no list, table or page of its own. (Location Services
    /// is one section, its switch and the apps' switches.)
    static func isForm(_ scroll: AXUIElement) -> Bool {
        let kids = scroll.elements(kAXChildrenAttribute)
        guard kids.contains(where: { $0.role == "AXGroup" }) else { return false }
        return !kids.contains { ["AXTable", "AXOutline", "AXList", "AXWebArea", "AXTextArea", "AXBrowser"].contains($0.role) }
    }

    /// The pane's child holding `e`: its section.
    static func section(of e: AXUIElement, in pane: AXUIElement) -> AXUIElement? {
        var x: AXUIElement? = e, hops = 0
        while let y = x, hops < 8 {
            if let parent = y.element(kAXParentAttribute), parent.isSame(pane) { return y }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    /// A section's name: the heading just before it among the pane's children.
    static func sectionName(_ section: AXUIElement, in pane: AXUIElement) -> String? {
        let kids = pane.elements(kAXChildrenAttribute)
        guard let i = kids.firstIndex(where: { $0.isSame(section) }), i > 0 else { return nil }
        let before = kids[i - 1]
        guard before.role == "AXHeading" else { return nil }
        let name = ObjectFactory.make(before).name
        return name.isEmpty ? nil : name
    }

    /// The pane's name: its window's title (System Settings titles the window by the pane).
    static func paneName(_ pane: AXUIElement) -> String? {
        guard let w = pane.element(kAXWindowAttribute) ?? SettingsPanePlugin.windowOf(pane), let t = w.string(kAXTitleAttribute), !t.isEmpty else { return nil }
        return t
    }

    /// The pane's description: in its first section, a line of text straight under the first control's label that
    /// labels nothing itself (Location Services: "Allow the applications and services below…").
    static func description(_ pane: AXUIElement) -> String? {
        guard let first = pane.elements(kAXChildrenAttribute).first(where: { $0.role == "AXGroup" }) else { return nil }
        let kids = first.elements(kAXChildrenAttribute)
        let texts = kids.filter { $0.role == "AXStaticText" }
        guard texts.count >= 2, let lf = TurnOverObject.frame(texts[0]), let df = TurnOverObject.frame(texts[1]) else { return nil }
        // Directly under the label, beginning where it begins.
        guard df.minY >= lf.maxY - 2, df.minY - lf.maxY < 12, abs(df.minX - lf.minX) < 6 else { return nil }
        // Not itself a control's label.
        let titled = kids.contains { k in k.element("AXTitleUIElement").map { $0.isSame(texts[1]) } ?? false }
        guard !titled, let d = texts[1].string(kAXValueAttribute), d.count > 20 else { return nil }
        return d
    }

    /// The texts on `button`'s row before it, for a button named only for what it does.
    static func rowWords(of button: AXUIElement) -> [String] {
        guard ["AXButton", "AXPopUpButton"].contains(button.role), let bf = TurnOverObject.frame(button),
              let parent = button.element(kAXParentAttribute) else { return [] }
        let name = ObjectFactory.make(button).name
        // Only a bare action ("Edit…", "Details…", "Options…"): a button that names its subject is said as it is.
        guard name.hasSuffix("…") || name.hasSuffix("..."), name.split(separator: " ").count <= 2 else { return [] }
        return parent.elements(kAXChildrenAttribute).compactMap { k -> (CGFloat, String)? in
            guard k.role == "AXStaticText", let f = TurnOverObject.frame(k), abs(f.midY - bf.midY) < 10, f.maxX <= bf.minX + 2,
                  let v = k.string(kAXValueAttribute), !v.isEmpty else { return nil }
            return (f.minX, v)
        }.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// What to say before the control, for a move from `old` to `new`.
    static func news(from old: AXUIElement?, to new: AXUIElement) -> [String] {
        guard let p = pane(of: new) else { return [] }
        var out: [String] = []
        let oldPane = old.flatMap { pane(of: $0) }
        let sec = section(of: new, in: p)
        if oldPane.map({ !$0.isSame(p) }) ?? true {
            if let name = paneName(p) { out.append(String(localized: "\(name) property page", comment: "Coming into a settings pane: %@ is its name (NVDA's property page)")) }
            if let d = description(p) { out.append(d) }
            if let s = sec, let n = sectionName(s, in: p) { out.append(String(localized: "\(n) grouping", comment: "Coming into a section of a settings pane: %@ is its heading")) }
        } else if let s = sec, let o = old, let os = section(of: o, in: p), !os.isSame(s), let n = sectionName(s, in: p) {
            out.append(String(localized: "\(n) grouping", comment: "Coming into a section of a settings pane: %@ is its heading"))
        }
        out += rowWords(of: new)
        return out
    }
}
