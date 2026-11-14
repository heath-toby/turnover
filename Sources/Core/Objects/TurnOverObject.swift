// SPDX-License-Identifier: GPL-3.0-or-later
// The object (NVDA: NVDAObjects.NVDAObject). One widget, abstracted: name,
// role, value, states, description, shortcut, position; its relations; the
// text inside it; the events it receives and the scripts it answers. The rest
// of the reader works with this and never with the accessibility API.
//
// Objects are made by ObjectFactory: the app module may choose a class for an
// element, then the role picks a behaviour (EditableText for text fields,
// Dialog for dialogs), then the base class.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

open class TurnOverObject: ScriptableObject {
    public let element: AXUIElement
    public let axRole: String
    public let axSubrole: String?
    public let pid: pid_t

    public required init(element: AXUIElement) {
        self.element = element
        // The role and subrole ObjectFactory already read for this element, if it did: each was asked twice per
        // object, and the focus's ancestors are made on every focus change (a review, 13 Nov 2026).
        if let known = TurnOverObject.knownRoles, known.element === element {
            axRole = known.role; axSubrole = known.subrole
        } else {
            axRole = element.role
            axSubrole = element.string(kAXSubroleAttribute)
        }
        TurnOverObject.knownRoles = nil
        pid = element.pid
        super.init()
        initOverlay()
    }

    /// Set by ObjectFactory just before it makes an object of an element whose role and subrole it has read; taken
    /// (and cleared) by that object's init (main thread).
    static var knownRoles: (element: AXUIElement, role: String, subrole: String?)?

    /// Where subclasses declare their scripts (NVDA: initOverlayClass).
    open func initOverlay() {}

    // MARK: - Properties (lazy, cached per object: objects are made fresh per event)

    open var role: Role { _role }
    // An iPad app's item with a name and a press is a button to the user (Clock's recent timers said only "twenty-five
    // minutes", Stocks' symbols; 12 Nov 2026), as VoiceOver says it. Tab already counts them as stops.
    // A Qt item view's groups are its list and items (QtItemViews).
    private lazy var _role: Role = axRole == "AXGenericElement" && SettingsPanePlugin.isPressableItem(element) ? .button
        : axRole == "AXGroup" ? (QtItemViews.role(of: element) ?? Role.from(axRole: axRole, subrole: axSubrole))
        : Role.from(axRole: axRole, subrole: axSubrole)

    /// A role's spoken name when the control supplies a better one (NVDA: roleText), or a plugin's.
    open var roleText: String? { profileLabel?.1 }
    /// A plugin profile's name and role for this element, if one applies (PLUGIN-GUIDE.md).
    public private(set) lazy var profileLabel: (String?, String?)? = ProfileStore.shared.label(for: element, pid: pid)

    /// NVDA's name: the title; or the description that AppKit and Office use as a label; or the label element beside it.
    open var name: String {
        // A field with no label but a placeholder ("Title" in Safari's bookmark sheet) is named by it, as VoiceOver does.
        if _name.isEmpty, [.editableText, .searchField, .comboBox].contains(role), let p = placeholder, !p.isEmpty { return p }
        // The window's own buttons have no name: VoiceOver calls them by what they do.
        if _name.isEmpty, let n = ["AXCloseButton": "close", "AXMinimizeButton": "minimise", "AXZoomButton": "zoom", "AXFullScreenButton": "full screen"][element.string(kAXSubroleAttribute) ?? ""] { return n }
        if _name.isEmpty, let l = swiftUILabel() { return l }
        // A saved search's window titled by its file's path (Finder's Recents, with the full path shown in titles:
        // ".../MyLibraries/myDocuments.cannedSearch"): its name as Finder shows it, "Recents" (11 Nov 2026).
        if role == .window, _name.hasPrefix("/"), _name.hasSuffix(".cannedSearch") || _name.hasSuffix(".savedSearch") {
            return FileManager.default.displayName(atPath: _name)
        }
        return _name
    }
    /// The name as the element gives it, for a subclass that knows where else to look (TurnOver Settings' module).
    var rawName: String { _name }
    /// SwiftUI links a control to its label (AXTitleUIElement) a moment after the control takes the focus: asked
    /// at once, the name was empty and stayed so ("switch, on" in TurnOver Settings, 18 Oct 2026). Asked again.
    func swiftUILabel() -> String? {
        guard let l = element.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute)?.trimmingCharacters(in: CharacterSet(charactersIn: ": \n")),
              !l.isEmpty, l.count <= 60 else { return nil }
        return l
    }
    private var _name: String {
        if let n = nameWorkedOut { return n }
        let n = Self.oneLine(computedName); nameWorkedOut = n; return n
    }
    private var nameWorkedOut: String?
    /// The name, only if it has already been worked out for this object (the event log: working it out for every
    /// caret move and every focus lost cost a title, a description and sometimes a walk; a review, 13 Nov 2026).
    var nameIfKnown: String? { nameWorkedOut }

    /// A programming class name standing in for a title ("Avalonia.Controls.Grid": .NET's Avalonia titles controls
    /// it wasn't given a name for with their class): no name at all (parts request #5, Libation, 14 Oct 2026). Three
    /// or more dotted parts, each a capitalised word, no spaces. Pure.
    nonisolated public static func isClassName(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !s.contains(" ") else { return false }
        return parts.allSatisfy { p in p.first.map { $0.isUppercase } == true && p.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }
    }

    /// A title on several lines says each different line once ("user@example.com\nuser@example.com" in a VPN app's menu).
    static func oneLine(_ s: String) -> String {
        guard s.contains("\n") else { return s }
        var seen: [String] = []
        for l in s.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !l.isEmpty && !seen.contains(l) { seen.append(l) }
        return seen.joined(separator: ", ")
    }

    private var computedName: String {
        if let n = profileLabel?.0, !n.isEmpty { return n }
        if let t = element.string(kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !isValueEcho(t), !Self.isClassName(t) { return t }
        if let d = element.string(kAXDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty, !isValueEcho(d), !Self.isClassName(d) { usedDescriptionAsName = true; return d }
        // A spin button titled by its text field (Word's Paragraph dialog: "0 cm"): the field's own label names it.
        if let tu = element.element(kAXTitleUIElementAttribute), tu.role == "AXTextField" {
            let field = ObjectFactory.make(tu).name
            if !field.isEmpty { return field }
        }
        if let label = element.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute)?.trimmingCharacters(in: CharacterSet(charactersIn: ": \n")), !label.isEmpty, label.count <= 60 { return label }
        if let l = neighbourLabel() { return l }
        // An icon button with only a tooltip is named by it, as VoiceOver reads it: Cyberduck's Back, Forward and its
        // Browser, Bookmarks and History buttons were just "button" and "radio button" (Day 4, 11 Oct 2026).
        // Not the window's own buttons: the green one's tooltip ("this button also has an action to zoom the
        // window", Voice Memos, 14 Oct 2026) is read instead of "full screen".
        if [.button, .radioButton, .checkBox, .popUpButton, .menuButton, .toggleButton].contains(role),
           !["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(axSubrole ?? ""),
           let h = element.string(kAXHelpAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty, h.count <= 60 { return h }
        // A row or cell with no name of its own is the text of what it holds (Mail's message list: sender, subject, date, preview).
        if [.tableRow, .tableCell, .listItem, .treeViewItem, .cell].contains(role) { return contentText(limit: 8) }
        // An item, button or link whose name is only in the text it holds (Electron apps: GitHub Desktop's repository
        // list is menu items with the repository's name in a child, so each was a nameless "menu item", 21 Oct 2026).
        if [.menuItem, .button, .link].contains(role) {
            let t = contentText(limit: 4)
            // Nothing inside, the words in its value: Chromium's options built as menu items (1Password's items: the
            // item list was nameless menu items, 12 Nov 2026).
            if t.isEmpty, role == .menuItem, let v = element.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
            return t
        }
        // A panel that can be pressed and names nothing of itself (Loopback's source blocks, Tab stops said as
        // nothing, 13 Nov 2026): the first names inside it.
        // (Only TurnOver's focus, not a page's groups; names from what isn't a stop of its own. A review, 13 Nov 2026.)
        // (The focus as the app reports it: the focus rules ask before TurnOver's focus has moved there.)
        if axRole == "AXUnknown" || axRole == "AXGroup", (element.attr(kAXFocusedAttribute) as? Bool) == true, !SettingsPanePlugin.isInWeb(element) {
            var acts: CFArray?
            if AXUIElementCopyActionNames(element, &acts) == .success, ((acts as? [String]) ?? []).contains(kAXPressAction) {
                var names: [String] = []
                var queue = element.elements(kAXChildrenAttribute).prefix(12).map { ($0, 1) }, seen = 0
                while !queue.isEmpty, seen < 30, names.count < 2 {
                    let (x, d) = queue.removeFirst(); seen += 1
                    if !SettingsPanePlugin.controlRoles.contains(x.role), let n = (x.string(kAXTitleAttribute) ?? x.string(kAXDescriptionAttribute))?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                        names.append(n)
                    } else if d < 3 { queue += x.elements(kAXChildrenAttribute).prefix(12).map { ($0, d + 1) } }
                }
                return names.joined(separator: ", ")
            }
        }
        return ""
    }

    /// The text that labels an unnamed control from beside it: on its row to its left, else just above it. Native
    /// windows only (a web page names its own controls), and only among a modest number of siblings.
    private func neighbourLabel() -> String? {
        guard [.popUpButton, .comboBox, .editableText, .slider, .spinButton, .menuButton, .checkBox, .radioButton].contains(role),
              var parent = element.element(kAXParentAttribute), var me = Self.frame(element) else { return nil }
        // A text area alone in its scroll area is labelled beside the scroll area (Contacts' card: "Notes" before it;
        // the note was "edit blank", a sweep, 13 Nov 2026).
        if parent.role == "AXScrollArea", parent.elements(kAXChildrenAttribute).count == 1,
           let outer = parent.element(kAXParentAttribute), let sf = Self.frame(parent), sf.height < 120 { parent = outer; me = sf }   // (a small one: a tall text view's "left" reached any text beside it)
        guard let texts = Self.siblingTexts(in: parent) else { return nil }
        var left: (String, CGRect)?, above: (String, CGFloat)?
        for (t, f) in texts {
            if Self.isLeftLabel(f, of: me, reach: Self.farLabelReach) {
                if left == nil || f.maxX > left!.1.maxX { left = (t, f) }
            } else if f.maxY <= me.minY + 4, me.minY - f.maxY < 30, abs(f.minX - me.minX) < 80 {
                if above == nil || f.maxY > above!.1 { above = (t, f.maxY) }
            }
        }
        // The nearest text on the row, further than 150 points: a label only with no control between it and the field
        // (a wide form's labels in a column; a review, 13 Nov 2026). Asked only then: the siblings' frames cost a question each.
        switch Self.labelSide(left: left?.1, hasAbove: above != nil, of: me) {
        case .left: break
        case .farLeft:
            let others = parent.elements(kAXChildrenAttribute).prefix(80).filter { $0.role != "AXStaticText" && !CFEqual($0, element) }.compactMap { Self.frame($0) }
            if let (_, f) = left, !Self.isFarLeftLabel(f, of: me, between: others) { left = nil }
        case .above, .none: left = nil
        }
        return (left.map { ($0.0, $0.1.maxX) } ?? above).map { $0.0.trimmingCharacters(in: CharacterSet(charactersIn: ": ")) }
    }

    /// A text that labels a field from its left: on the field's row (centred with it and overlapping it vertically),
    /// ending before it and no more than 150 points away. Without the distance, any text on the row labelled the field
    /// however far across the window it was (a review, 13 Nov 2026). Pure.
    nonisolated public static func isLeftLabel(_ f: CGRect, of me: CGRect, reach: CGFloat = 150) -> Bool {
        abs(f.midY - me.midY) <= max(6, me.height / 2) && f.minY < me.maxY && f.maxY > me.minY
            && f.maxX <= me.minX + 8 && me.minX - f.maxX < reach
    }

    /// Which neighbour labels a field: a text within 150 points on its row, else a text just above it, else the nearest
    /// text on the row up to 300 points away (`farLeft`: still to be checked for a control between). A far text on the
    /// row beat a real label above (a read-only value in a form with its labels above, a review, 13 Nov 2026). Pure.
    nonisolated package enum LabelSide { case left, farLeft, above, none }
    nonisolated package static func labelSide(left: CGRect?, hasAbove: Bool, of me: CGRect) -> LabelSide {
        if let f = left, isLeftLabel(f, of: me) { return .left }
        if hasAbove { return .above }
        return left == nil ? .none : .farLeft
    }

    /// How far a left label may be when it is the nearest text on the row and nothing stands between.
    nonisolated public static let farLabelReach: CGFloat = 300

    /// The nearest text to a field's left, up to 300 points away, labels it when no other control on the row sits
    /// between them: a wide form with its labels in a left column (a review, 13 Nov 2026). Pure.
    nonisolated public static func isFarLeftLabel(_ f: CGRect, of me: CGRect, between others: [CGRect]) -> Bool {
        guard isLeftLabel(f, of: me, reach: farLabelReach) else { return false }
        return !others.contains { o in
            o.minX >= f.maxX - 2 && o.maxX <= me.minX + 2 && o.minY < me.maxY && o.maxY > me.minY
        }
    }

    /// A parent's short static texts and their frames, for neighbourLabel; nil where it isn't looked in (more than
    /// 80 children, or web content). Every unnamed field asked all its siblings three questions each, up to 80 (a
    /// review, 13 Nov 2026): kept for the next field in the same parent for two seconds, while the app says nothing of
    /// its controls changing and the first text hasn't moved (a scroll moves the field and its labels together).
    private static var siblingTextsKept: (parent: AXUIElement, at: Date, texts: [(text: String, frame: CGRect, element: AXUIElement)]?)?
    private static func siblingTexts(in parent: AXUIElement) -> [(String, CGRect)]? {
        if let k = siblingTextsKept, CFEqual(k.parent, parent), Date().timeIntervalSince(k.at) < 2,
           AXHandler.shared.observers[parent.pid] != nil, (AXHandler.shared.lastStructureAt[parent.pid] ?? .distantPast) < k.at {
            guard let texts = k.texts else { return nil }
            if texts.first.map({ frame($0.element) == $0.frame }) ?? true { return texts.map { ($0.text, $0.frame) } }
        }
        let at = Date()
        let siblings = parent.elements(kAXChildrenAttribute)
        guard siblings.count <= 80, !siblings.contains(where: { $0.role == "AXWebArea" }), parent.role != "AXWebArea" else {
            siblingTextsKept = (parent, at, nil)
            return nil
        }
        var texts: [(text: String, frame: CGRect, element: AXUIElement)] = []
        for s in siblings where s.role == "AXStaticText" {
            guard let t = s.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count <= 60,
                  let f = frame(s) else { continue }
            texts.append((t, f, s))
        }
        siblingTextsKept = (parent, at, texts)
        return texts.map { ($0.text, $0.frame) }
    }

    /// The static text, values and descriptions inside this element, in order, bounded.
    public func contentText(limit: Int) -> String {
        var parts: [String] = []
        var images: [String] = []
        var queue = element.elements(kAXChildrenAttribute)
        var visited = 0
        // Each element's role, value, title, description and children in one question (SwiftUI apps are slow to
        // answer: Contacts' rows took 80 ms each to name, 10 Oct 2026).
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute]
        func trimmed(_ v: AnyObject?) -> String? {
            guard let t = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        while !queue.isEmpty, visited < 60, parts.count < limit {
            let e = queue.removeFirst(); visited += 1
            let a = e.attrs(names)
            let r = (a[kAXRoleAttribute] as? String) ?? "?"
            let kids = { (a[kAXChildrenAttribute] as? [AXUIElement]) ?? [] }
            let value = a[kAXValueAttribute], title = trimmed(a[kAXTitleAttribute]), desc = trimmed(a[kAXDescriptionAttribute])
            if r == "AXCheckBox" {
                // A switch says on or off; a check box says checked or not. One with no name of its own (System
                // Settings' permission lists: the app's name is a text beside a nameless AXSwitch, so each row was
                // only "Claude", 8 Nov 2026) still says its role and state after the texts.
                let on = (value as? NSNumber)?.intValue == 1
                let isSwitch = (a[kAXSubroleAttribute] as? String) == "AXSwitch"
                let state = isSwitch ? (on ? State.on.displayString : State.on.negativeDisplayString)
                                     : (on ? State.checked.displayString : State.checked.negativeDisplayString)
                if let t = title ?? desc { parts.append("\(t), \(state)") }
                else { parts.append("\((isSwitch ? Role.switchControl : Role.checkBox).displayString), \(state)") }
            } else if r == "AXStaticText" || r == "AXTextField" {
                if let v = trimmed(value) { parts.append(String(v.prefix(300))) }
                else if r == "AXTextField" { queue.append(contentsOf: kids()) }
            } else if (r == "AXCell" || r == "AXGroup"), let d = desc {
                // A cell that describes itself (Safari's Reading List: "Boson, en.wikipedia.org") says it once.
                parts.append(String(d.prefix(300)))
            } else if r == "AXHeading", let d = desc ?? title ?? trimmed(value) {
                // System Settings' Automation list: each app's name is a heading in its row (only "collapsed, 1 of
                // 13" was heard, 7 Oct 2026).
                parts.append(String(d.prefix(300)))
            } else if r == "AXImage" {
                if let d = desc { images.append(d) }
            } else if r == "AXButton" {
                if let d = desc ?? title { parts.append(d) }
            } else {
                queue.append(contentsOf: kids())
            }
        }
        // An icon's description only stands in when the row has no text of its own.
        return (parts.isEmpty ? images : parts).joined(separator: ", ")
    }
    private var usedDescriptionAsName = false

    /// Word puts a field's contents into its own title; a label equal to the value is no label.
    private func isValueEcho(_ t: String) -> Bool {
        guard role == .editableText || role == .searchField || role == .comboBox, let v = element.string(kAXValueAttribute) else { return false }
        return t.caseInsensitiveCompare(v) == .orderedSame
    }

    open var description: String? { _description }

    /// The texts on the same row as a control whose name its siblings share (Mail's Fonts settings: three
    /// "Select…" buttons, each beside its own "Message font:" and "Helvetica 12"). Nothing ties them to the
    /// button but where they are, so where they are is used: the texts whose middle is level with it, left to right.
    private func rowLabel() -> String? {
        guard [.button, .popUpButton, .menuButton].contains(role), let parent = element.element(kAXParentAttribute) else { return nil }
        let siblings = parent.elements(kAXChildrenAttribute)
        guard siblings.count <= 60, let me = Self.frame(element) else { return nil }
        let title = element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute) ?? ""
        guard !title.isEmpty, siblings.filter({ ($0.string(kAXTitleAttribute) ?? $0.string(kAXDescriptionAttribute)) == title }).count >= 2 else { return nil }
        var row: [(CGFloat, String)] = []
        for s in siblings where s.role == "AXStaticText" {
            guard let f = Self.frame(s), let v = s.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { continue }
            if f.midY >= me.minY, f.midY <= me.maxY { row.append((f.minX, v)) }
        }
        guard !row.isEmpty else { return nil }
        return row.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }

    public static func debugFrame(_ e: AXUIElement) -> String { frame(e).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "-" }
    /// An element's frame on screen, in points from the top left of the main display (accessibility's own
    /// convention, so it compares with CGEvent and Vision points without flipping). Nil when the app gives no
    /// position or size, or gives something that isn't one: never a made-up zero. The one place this is read
    /// (20 Oct 2026: seven copies became this one); callable off the main thread.
    nonisolated static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = e.attr(kAXPositionAttribute), let z = e.attr(kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard axValue(p, .cgPoint, &pt), axValue(z, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private lazy var _description: String? = {
        _ = _name
        if let r = rowLabel() { return r }
        if !usedDescriptionAsName, let d = element.string(kAXDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty, d != _name, !Role.withNavigableText.contains(role) { return d }
        // AXHelp is the hover tip ("Drag to the Mini Player to add to the queue"): not a description, as NVDA treats it.
        return nil
    }()

    open var placeholder: String? { element.string("AXPlaceholderValue") }

    /// The value as text, formatted for the role (NVDA: value). Check boxes carry theirs in states.
    open var value: String? { _value }
    /// A number box with nothing in it whose spinner holds the number: Avalonia's NumericUpDown puts the value on the
    /// AXIncrementor around the text box that has the focus, which read "blank" while showing 3 (parts request #5,
    /// Libation, 14 Oct 2026).
    /// Apps where a deep walk found an incrementor, and apps where one full walk found none: after that, two levels
    /// (every empty search box paid up to 28 round trips on the focus: code review, 16 Oct 2026).
    nonisolated(unsafe) private static var deepIncrementorPids: Set<pid_t> = []
    nonisolated(unsafe) private static var shallowIncrementorPids: Set<pid_t> = []
    private var incrementorValue: String? {
        guard [.editableText, .spinButton].contains(role) else { return nil }
        let deep = !Self.shallowIncrementorPids.contains(pid)
        let limit = deep ? 14 : 2   // eleven levels in Libation's spinner
        var p = element.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < limit {
            if x.role == "AXIncrementor", let v = x.attr(kAXValueAttribute) { Self.deepIncrementorPids.insert(pid); let t = "\(v)"; return t.isEmpty ? nil : t }
            p = x.element(kAXParentAttribute); hops += 1
        }
        if deep, !Self.deepIncrementorPids.contains(pid) { Self.shallowIncrementorPids.insert(pid) }
        return nil
    }
    private lazy var _value: String? = {
        guard let v = element.attr(kAXValueAttribute) else { return incrementorValue }
        if let s = v as? String {
            if s.isEmpty, let n = incrementorValue { return n }
            // Some toolkits (wxWidgets: Bambu Studio) hand over an object's debug description as its value.
            if s.hasPrefix("<NS"), s.contains(" 0x") { return nil }
            if s.contains(Attachments.mark) { return Attachments.expand(s, in: element, from: 0) }
            return s
        }
        if let n = v as? NSNumber {
            switch role {
            case .checkBox, .radioButton, .toggleButton, .switchControl, .disclosureTriangle, .menuItem, .checkMenuItem, .radioMenuItem, .tab, .button, .menuButton, .popUpButton: return nil
            case .slider, .progressBar, .levelIndicator, .spinButton:
                if let s = element.string("AXValueDescription"), !s.isEmpty { return s }
                // A slider from 0 to 1 is a fraction: said as a percentage, as VoiceOver says it (9 Oct 2026).
                if role == .slider, let lo = element.attr(kAXMinValueAttribute) as? NSNumber, let hi = element.attr(kAXMaxValueAttribute) as? NSNumber,
                   lo.doubleValue == 0, hi.doubleValue == 1 { return Phrases.percent(Int((n.doubleValue * 100).rounded())) }
                // A progress bar is always a percentage of its range, as VoiceOver and NVDA say it: an installer's
                // download was "0.9" (18 Oct 2026).
                if role == .progressBar {
                    let lo = (element.attr(kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
                    let hi = (element.attr(kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? (n.doubleValue <= 1 ? 1 : 100)
                    if hi > lo { return Phrases.percent(Int(((n.doubleValue - lo) / (hi - lo) * 100).rounded())) }
                }
                return n.doubleValue == n.doubleValue.rounded() ? "\(n.intValue)" : String(format: "%.1f", n.doubleValue)
            default: return n.stringValue
            }
        }
        if let d = v as? Date { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: d) }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }()

    open var states: Set<State> { _states }
    private lazy var _states: Set<State> = {
        var s = Set<State>()
        // Unavailable is said only of things that can be used. Preview's page list and its PDF pages report themselves
        // disabled, and "list, unavailable" or "page, unavailable" means nothing to the user (Day 2, 10 Oct 2026).
        // An item of a collection says it's disabled though it can be chosen and opened (every board in Freeform was
        // "unavailable", parts sweep, 14 Oct 2026): not said there.
        // Nor a control that has the keyboard: a disabled one can't take it. Java's (PDFsam) report every button
        // disabled, and each Tab said "Split, button, unavailable" (parts sweep, 14 Oct 2026).
        if let enabled = element.attr(kAXEnabledAttribute) as? Bool, !enabled, !Role.neverUnavailable.contains(role),
           element.element(kAXParentAttribute)?.string(kAXSubroleAttribute) != "AXSectionList",
           // A link in a line of text (SwiftUI's "Learn more…") says it's disabled and opens when clicked (13 Nov 2026).
           !(axRole == "AXLink" && element.element(kAXParentAttribute)?.role == "AXStaticText"),
           (element.attr(kAXFocusedAttribute) as? Bool) != true { s.insert(.unavailable) }
        if let f = element.attr(kAXFocusedAttribute) as? Bool, f { s.insert(.focused) }
        if let sel = element.attr(kAXSelectedAttribute) as? Bool, sel { s.insert(.selected) }
        if let n = element.attr(kAXValueAttribute) as? NSNumber {
            switch role {
            case .checkBox, .checkMenuItem, .radioButton, .radioMenuItem, .toggleButton:
                if n.intValue == 2 { s.insert(.halfChecked) } else if n.intValue != 0 { s.insert(role == .toggleButton ? .pressed : .checked) }
            case .switchControl: if n.intValue != 0 { s.insert(.on) }
            case .tab: if n.intValue != 0 { s.insert(.selected) }   // a tab button's value: the tab showing
            case .disclosureTriangle: s.insert(n.intValue != 0 ? .expanded : .collapsed)
            default: break
            }
        }
        if let e = element.attr(kAXExpandedAttribute) as? Bool { s.insert(e ? .expanded : .collapsed) }
        if let d = element.attr("AXDisclosing") as? Bool, role == .treeViewItem {
            // Finder's list view: only a row that can disclose (a folder) is expanded or collapsed.
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, "AXDisclosing" as CFString, &settable)
            if settable.boolValue || d { s.insert(d ? .expanded : .collapsed) }
        }
        if let m = element.string("AXMenuItemMarkChar"), !m.isEmpty { s.insert(.checked) }
        if role == .menuItem, element.elements(kAXChildrenAttribute).contains(where: { $0.role == "AXMenu" }) { s.insert(.hasPopup) }
        // "password edit" says it is protected; "protected" as well was one word too many (3 Oct 2026).
        if let r = element.attr("AXRequired") as? Bool, r { s.insert(.required) }
        if let m = element.attr(kAXModalAttribute) as? Bool, m { s.insert(.modal) }
        if let b = element.attr("AXElementBusy") as? Bool, b { s.insert(.busy) }
        // Safari marks every empty required field invalid before anything is typed: that is not news. Invalid is
        // said once the field holds something the page rejects.
        if let inv = element.attr("AXInvalid") as? String, inv != "false", !inv.isEmpty {
            let empty = role == .passwordEdit ? SecureEcho.length(element) == 0 : (element.string(kAXValueAttribute) ?? "").isEmpty
            if !(empty && s.contains(.required)) { s.insert(.invalidEntry) }
        }
        if Role.withNavigableText.contains(role), role != .document, role != .webArea, axRole != "AXWebArea" { s.insert(.editable); if axRole == "AXTextArea" { s.insert(.multiLine) } }
        // A field whose text can't be changed: NVDA's "read-only edit" (Mail's message header, From, To, Subject: a
        // tester, 13 Nov 2026). Terminal's text area answers the same and is a terminal, not a field.
        if ["AXTextField", "AXTextArea"].contains(axRole), element.string(kAXSubroleAttribute) != "AXTerminalTextArea" {
            var settable: DarwinBoolean = true
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, !settable.boolValue {
                s.insert(.readOnly)
                ReadOnlyLog.note(element, axRole)
            }
        }
        return s
    }()

    /// The names of the keys macOS draws in menus as symbols (Carbon's menu glyph numbers).
    static let menuGlyphNames: [Int: String] = [
        2: "tab", 3: "shift tab", 4: "enter", 9: "space", 10: "forward delete", 11: "return", 23: "delete", 27: "escape",
        28: "clear", 98: "page up", 99: "caps lock", 100: "left arrow", 101: "right arrow", 102: "home", 104: "up arrow",
        105: "end", 106: "down arrow", 107: "page down", 140: "eject",
    ].merging((0..<12).map { (111 + $0, "F\($0 + 1)") }, uniquingKeysWith: { a, _ in a })
    /// A command character that is a control or function key, named.
    static func menuKeyName(_ ch: String) -> String {
        guard let u = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return ch }
        switch u.value {
        case 0x08, 0x7F: return "delete"
        case 0x09: return "tab"
        case 0x0D, 0x03: return "return"
        case 0x1B: return "escape"
        case 0x20: return "space"
        case 0xF700: return "up arrow"
        case 0xF701: return "down arrow"
        case 0xF702: return "left arrow"
        case 0xF703: return "right arrow"
        case 0xF704...0xF726: return "F\(u.value - 0xF704 + 1)"
        case 0xF728: return "forward delete"
        case 0xF729: return "home"
        case 0xF72B: return "end"
        case 0xF72C: return "page up"
        case 0xF72D: return "page down"
        case 0x1F3A4: return "dictation key"   // Start Dictation: drawn as a microphone, said "🎤"
        default: return ch
        }
    }

    /// "command N" from a menu item's command character and modifiers.
    open var keyboardShortcut: String? { _shortcut }
    private lazy var _shortcut: String? = {
        // A key drawn as a symbol (Finder's Move to Bin, command delete) has a glyph number, or a control character,
        // in place of a letter: it was said as nothing, "shift command" (the menu walk, 11 Nov 2026).
        let glyph = element.int("AXMenuItemCmdGlyph").flatMap { Self.menuGlyphNames[$0] }
        let raw = element.string("AXMenuItemCmdChar") ?? ""
        guard !raw.isEmpty || glyph != nil else { return nil }
        let ch = glyph ?? Self.menuKeyName(raw)
        let mods = element.int("AXMenuItemCmdModifiers") ?? 0
        var parts: [String] = []
        if mods & 4 != 0 { parts.append("control") }
        if mods & 2 != 0 { parts.append("option") }
        if mods & 1 != 0 { parts.append("shift") }
        if mods & 8 == 0 { parts.append("command") }
        parts.append(ch.count == 1 && ch.first!.isLetter ? ch.lowercased() : ch)
        return parts.joined(separator: " ")
    }()

    /// A row with a disclosure triangle in it (a real branch), looked for a few levels down.
    static func hasDisclosureTriangle(_ row: AXUIElement) -> Bool {
        var queue: [(AXUIElement, Int)] = [(row, 0)], seen = 0
        while !queue.isEmpty, seen < 40 {
            let (e, d) = queue.removeFirst(); seen += 1
            if e.role == "AXDisclosureTriangle" { return true }
            if d < 3 { queue += e.elements(kAXChildrenAttribute).map { ($0, d + 1) } }
        }
        return false
    }

    public struct PositionInfo { public var index: Int?; public var count: Int?; public var level: Int? }
    open var positionInfo: PositionInfo? { _positionInfo }
    private lazy var _positionInfo: PositionInfo? = {
        guard [.listItem, .tableRow, .treeViewItem, .tab, .menuItem, .checkMenuItem, .radioMenuItem, .radioButton, .dockItem].contains(role) else { return nil }
        var p = PositionInfo()
        if role == .treeViewItem, let level = element.int("AXDisclosureLevel"), level > 0 {
            // A section heading at the top ("A" in Contacts, "iCloud" in Notes' folders) has no disclosure triangle:
            // it isn't a branch, and "level 2" on every row under it was noise (Contacts, Reminders, Notes, Photos;
            // a rule for all, 11 Nov 2026).
            var top = element, steps = 0
            while steps < 20, let up = top.element("AXDisclosedByRow") { top = up; steps += 1 }
            let shown = steps > 0 && !Self.hasDisclosureTriangle(top) ? level - 1 : level
            if shown > 0 { p.level = shown + 1 }   // NVDA-style: the top level goes without saying
        }
        // A web page's own count (aria-posinset, aria-setsize): the whole list, where only the rows in view exist.
        // 1Password's items said no place at all: nameless menu items, not counted as siblings (12 Nov 2026).
        if let i = element.int("AXARIAPosInSet"), let n = element.int("AXARIASetSize"), i > 0, i <= n {
            p.index = i; p.count = n
            return p
        }
        if let parent = element.element(kAXParentAttribute) {
            var count: CFIndex = 0
            let parentRole = parent.role
            let attr = parentRole == "AXTable" || parentRole == "AXOutline" ? "AXRows" : kAXChildrenAttribute
            if AXUIElementGetAttributeValueCount(parent, attr as CFString, &count) == .success, count > 0 {
                // A table's or outline's row by its own index, where the row at that index is this one: its rows are
                // all rows, so the count is theirs. Every row read all its siblings and asked each its role, up to 200
                // (a review, 13 Nov 2026).
                if attr == "AXRows", axRole == "AXRow", let i = element.int(kAXIndexAttribute), i >= 0, i < Int(count),
                   let at = (parent.attributeValuesResult("AXRows", index: i, maxValues: 1).value as? [AXUIElement])?.first, CFEqual(at, element) {
                    p.index = i + 1; p.count = Int(count)
                } else if count <= 200, let siblings = parent.attr(attr) as? [AXUIElement] {
                    // Only siblings of the same role count, and a menu's separators (untitled, disabled items) don't.
                    let same = siblings.filter { s in
                        guard s.role == axRole else { return false }
                        if axRole == "AXMenuItem", (s.string(kAXTitleAttribute) ?? "").isEmpty { return false }
                        return true
                    }
                    if let i = same.firstIndex(where: { CFEqual($0, element) }) { p.index = i + 1; p.count = same.count }
                    // Elements that don't compare equal (a tester's desktop icons read as the last of the last, issue
                    // 140, 28 Oct 2026): the sibling in the same place with the same name is this one.
                    else if let f = Self.frame(element), let i = same.firstIndex(where: { s in
                        Self.frame(s).map { abs($0.minX - f.minX) < 1 && abs($0.minY - f.minY) < 1 } == true && s.string(kAXTitleAttribute) == element.string(kAXTitleAttribute)
                    }) { p.index = i + 1; p.count = same.count }
                } else if let i = element.int(kAXIndexAttribute), i < Int(count) { p.index = i + 1; p.count = Int(count) }
            }
        }
        return p.index == nil && p.level == nil ? nil : p
    }()

    // MARK: - Relations

    open var parent: TurnOverObject? { element.element(kAXParentAttribute).map { ObjectFactory.make($0) } }
    open var children: [TurnOverObject] { element.elements(kAXChildrenAttribute).map { ObjectFactory.make($0) } }
    open var firstChild: TurnOverObject? { element.elements(kAXChildrenAttribute).first.map { ObjectFactory.make($0) } }
    open var next: TurnOverObject? { sibling(+1) }
    open var previous: TurnOverObject? { sibling(-1) }
    private func sibling(_ delta: Int) -> TurnOverObject? {
        guard let parent = element.element(kAXParentAttribute) else { return nil }
        let kids = parent.elements(kAXChildrenAttribute)
        guard let i = kids.firstIndex(where: { CFEqual($0, element) }), kids.indices.contains(i + delta) else { return nil }
        return ObjectFactory.make(kids[i + delta])
    }
    /// Ancestors from the parent up to the application, bounded.
    open var ancestors: [TurnOverObject] {
        let started = Date()
        let kept = Self.keptChain()
        var out: [TurnOverObject] = []
        var links: [AncestorLink] = []
        var e = element.element(kAXParentAttribute)
        while let p = e, out.count < 40 {
            // Where the walk meets the chain made last time, the rest of it is that chain: its elements, roles and
            // subroles are not asked again. The objects are still made fresh.
            if let kept, let k = kept.firstIndex(where: { CFEqual($0.element, p) }) {
                for l in kept[k...] where out.count < 40 {
                    out.append(ObjectFactory.make(l.element, known: (l.role, l.subrole))); links.append(l)
                }
                break
            }
            let (r, s) = ObjectFactory.roles(of: p)
            out.append(ObjectFactory.make(p, known: (r, s))); links.append(AncestorLink(element: p, role: r, subrole: s))
            if r == "AXApplication" { break }   // the role already read (one call per level less: code review, 16 Oct 2026)
            e = p.element(kAXParentAttribute)
        }
        if links.last?.role == "AXApplication" { TurnOverObject.lastChain = (links, started) }
        return out
    }

    /// One ancestor as last read: the element, its role and subrole.
    struct AncestorLink { let element: AXUIElement; let role: String; let subrole: String? }
    /// The last ancestor chain made up to the application, nearest first, and when its reading began (main thread).
    /// The whole chain was read again on every focus change, though a Tab between two controls of a pane shares all
    /// of it (a review, 13 Nov 2026).
    private static var lastChain: (links: [AncestorLink], at: Date)?
    /// The last chain, while it can stand: under ten seconds old, every process in it watched, and none has said
    /// its controls came or went (created, layout, rows, a window: AXHandler.lastStructureAt) since it was read.
    private static func keptChain() -> [AncestorLink]? {
        guard let c = lastChain, Date().timeIntervalSince(c.at) < 10 else { return nil }
        let ax = AXHandler.shared
        for pid in Set(c.links.map { $0.element.pid }) {
            guard ax.observers[pid] != nil, (ax.lastStructureAt[pid] ?? .distantPast) < c.at else { return nil }
        }
        return c.links
    }
    open var window: TurnOverObject? { element.element(kAXWindowAttribute).map { ObjectFactory.make($0) } }
    open var appModule: AppModule { AppModuleHandler.shared.appModule(for: pid) }

    /// NVDA: isPresentableFocusAncestor — spoken when the focus enters it.
    open var isPresentableFocusAncestor: Bool {
        if Role.presentableAncestors.contains(role) { return role != .groupBox || !name.isEmpty }
        return false
    }

    // MARK: - Text

    open var hasNavigableText: Bool { Role.withNavigableText.contains(role) }

    /// The TextInfo class for this object; EditableText overrides to AXTextInfo.
    open var textInfoClass: TextInfo.Type { hasNavigableText ? AXTextInfo.self : TextInfo.self }

    public func makeTextInfo(_ position: TextPosition) throws -> TextInfo {
        guard hasNavigableText else { throw TextInfoError("no text") }
        return try textInfoClass.init(obj: self, position: position)
    }

    // MARK: - Identity

    public func isSameElement(as other: TurnOverObject?) -> Bool { other.map { CFEqual(element, $0.element) } ?? false }
    public func isSameElement(as other: AXUIElement) -> Bool { CFEqual(element, other) }

    // MARK: - Actions

    public func setFocus() { _ = element.set(kAXFocusedAttribute, kCFBooleanTrue) }
    public func doDefaultAction() { AXUIElementPerformAction(element, kAXPressAction as CFString) }

    // MARK: - Events (NVDA: event_*). The object is the last handler in the chain.

    /// Speak this object as the focus (NVDA: reportFocus).
    open func reportFocus() {
        TurnOverObject.lastName = (element, name)
        // The selection event that follows on the same element is the same news (LibreOffice Calc's cells take the
        // focus and are selected on each arrow: every cell was said twice, parts sweep 14 Oct 2026).
        TurnOverObject.noteSelectionSpoken(element)
        if let chosen = TurnOverObject.chosenInGroup(element) {
            Speech.speakMessage(String(localized: "list", comment: "A role: a list"))
            Speech.speakObject(ObjectFactory.make(chosen), reason: .focus)
            return
        }
        Speech.speakObject(self, reason: .focus)
    }

    /// The one item chosen in a group that holds the focus and keeps a selection of its own: a web list built of
    /// plain blocks (1Password's items, a listbox whose options are menu items). The group's name is all its text,
    /// so the focus and each arrow read the whole list (12 Nov 2026); its chosen item is the news.
    public static func chosenInGroup(_ e: AXUIElement) -> AXUIElement? {
        guard e.role == "AXGroup" else { return nil }
        let chosen = e.elements(kAXSelectedChildrenAttribute)
        return chosen.count == 1 ? chosen[0] : nil
    }

    /// The focus's name as last spoken. Claude's collapsed summary button ("Ran 23 commands (2 failed), compacted the
    /// session, read MediaView.swift") reports a name change each time the conversation moves on, with the same name:
    /// it was read again every few seconds (7 Oct 2026). Only a new name is news.
    static var lastName: (element: AXUIElement, name: String)?

    open func event_gainFocus() {
        // A settings window opens with the focus on the window itself (Mail): nothing for the arrows to move.
        // Put it on the pane's tab, as Windows opens a dialog on its tab control; that focus speaks.
        if role == .window, let tab = PreferenceTab.selectedTab(in: element) {
            Log.io("settings window has no focus inside; to its tab \"\(Log.words(tab.string(kAXTitleAttribute) ?? ""))\"")
            _ = tab.set(kAXFocusedAttribute, kCFBooleanTrue)
            return
        }
        reportFocus()
    }
    open func event_loseFocus() { Speech.clearTypedWordBuffer() }
    open func event_focusEntered() { Speech.speakObject(self, reason: .focusEntered) }
    open func event_focusExited() {}
    open func event_foreground() { Speech.cancel() }
    open func event_valueChange() {
        guard API.focusObject?.isSameElement(as: self) == true else { return }
        // A progress bar that beeps (ProgressWatch) isn't also read out at every percent, as NVDA's focus isn't.
        if role == .progressBar, ["beep", "both"].contains(config.presentation.progressBars) { return }
        // A check box keeps its state in its value (a number): the news is "checked" / "not checked" (NVDA's state
        // change). Pressing the developer agreement's box said nothing, 3 Oct 2026.
        if [.checkBox, .radioButton, .toggleButton, .switchControl].contains(role) {
            // Read afresh, a moment after the event: this object may be the focus object made before the press, its
            // states remembered (it said "checked" as the box became unchecked, 3 Oct 2026). Only the check state
            // is news here, not "required" or "invalid entry".
            // Only if the focus is still on it: Qt (MuseScore) reports a value change on the box being left, just
            // before the focus moves, and its state was said after the next control's (parts sweep, 14 Oct 2026).
            let el = element
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard API.focusObject?.element.isSame(el) == true else { return }
                Speech.speakCheckState(of: el)
            }
            return
        }
        // The value is read afresh: this is the focus object, made when the control took the focus, and its value
        // is remembered from then (a slider said 0.9 at every step, in a game, 9 Oct 2026).
        let fresh = ObjectFactory.make(element)
        Speech.speakObjectProperty(fresh, value: true)
    }
    open func event_nameChange() {
        guard role != .window, API.focusObject?.isSameElement(as: self) == true else { return }
        // A list group's name is its text: its selection says what changed.
        if TurnOverObject.chosenInGroup(element) != nil { return }
        // The name read afresh, as event_valueChange reads the value: this is the focus object, made when the item
        // took the focus, and its name is remembered from then. A cell renamed for each chosen item (LaunchBar's bar)
        // was compared with its first name each time and nothing was said (10 Nov 2026).
        let fresh = ObjectFactory.make(element)
        let n = fresh.name
        if let last = TurnOverObject.lastName, CFEqual(last.element, element), last.name == n { return }
        TurnOverObject.lastName = (element, n)
        Speech.speakObjectProperty(fresh, name: true)
    }
    open func event_stateChange() { if API.focusObject?.isSameElement(as: self) == true { Speech.speakObjectProperty(self, states: true) } }
    open func event_descriptionChange() {}
    open func event_caret() {}
    open func event_selection() {
        // A list that announces its own selection and the script that waited for it can both report one row.
        if let (e, t) = TurnOverObject.lastSelectionSpoken, Date().timeIntervalSince(t) < 0.6, e.isSame(element) { return }
        TurnOverObject.lastSelectionSpoken = (element, Date())
        // A nameless cell (a SwiftUI collection's group): read by what it holds (Shortcuts' grid, 12 Nov 2026).
        if let chosen = TurnOverObject.chosenInGroup(element) { Speech.speakObject(ObjectFactory.make(chosen), reason: .focus) }
        else if name.isEmpty, axRole == "AXGroup", let inner = TurnOverObject.namedInside(element) { Speech.speakObject(ObjectFactory.make(inner), reason: .focus) }
        else { Speech.speakObject(self, reason: .focus) }
        // "3 selected", after the row that changed: only this row's, and only just set (one left by an event that was
        // dropped or swallowed came out minutes later in another app: a review, 14 Nov 2026).
        // Cleared when said or stale only: with Shift Down held the next row's note is already waiting, and clearing it on a
        // mismatch lost the count (a review, 14 Nov 2026).
        if let note = TurnOverObject.selectionNote {
            if note.element.isSame(element), Date().timeIntervalSince(note.at) < 2 { Speech.speakMessage(note.text); TurnOverObject.selectionNote = nil }
            else if Date().timeIntervalSince(note.at) >= 2 { TurnOverObject.selectionNote = nil }
        }
    }
    /// The first named thing inside a nameless wrapper, looking at twenty elements at most.
    public static func namedInside(_ e: AXUIElement) -> AXUIElement? {
        var queue = e.elements(kAXChildrenAttribute); var n = 0
        while !queue.isEmpty, n < 20 {
            let x = queue.removeFirst(); n += 1
            if !ObjectFactory.make(x).name.isEmpty { return x }
            queue.append(contentsOf: x.elements(kAXChildrenAttribute))
        }
        return nil
    }
    /// Set by the selection notification when several rows are selected: said after the row that changed.
    public static var selectionNote: (text: String, element: AXUIElement, at: Date)?
    private static var lastSelectionSpoken: (AXUIElement, Date)?
    public static func noteSelectionSpoken(_ e: AXUIElement) { lastSelectionSpoken = (e, Date()) }
    /// Whether any selection was read since `date` (a key's own read already done).
    public static func selectionSpoken(since date: Date) -> Bool { lastSelectionSpoken.map { $0.1 >= date } ?? false }
    open func event_textChange() {}
    open func event_alert() { Speech.speakObject(self, reason: .focus) }
    /// NVDA: a live region's new text is spoken, politely (queued) or assertively (interrupting).
    open func event_liveRegionChange() {
        guard config.presentation.reportDynamicContentChanges else { return }
        let t = ClaudeTranscript.text(of: element, skipHidden: false)
        guard !t.isEmpty else { return }
        LiveRegions.speak(t, from: element, assertive: element.string("AXARIALive") == "assertive")
    }
    open func event_menuStart() {
        // A menu bar menu is named by the menu bar item above it (Word's menus have no names of their own).
        // A submenu is named by the item that holds it ("Clear submenu").
        var parent = element.element(kAXParentAttribute)
        // An iPad app's menu (Maps, Messages) names a group in its window as its parent, not the menu bar's title: it
        // was said as a context menu, and Right went no further along the bar (the menu walk, 11 Nov 2026).
        if let owner = Self.menuBarItem(owning: element) { parent = owner }
        // A menu that names the application, or its menu bar, as its parent: Electron's menu extras (1Password's) hang their menu off
        // the application, and it was said as a context menu (12 Nov 2026). The extra holding it, or the one open, is its owner.
        if ["AXApplication", "AXMenuBar"].contains(parent?.role ?? ""), let bar = AXUIElementCreateApplication(pid).element("AXExtrasMenuBar"),
           let extra = bar.elements(kAXChildrenAttribute).first(where: { ($0.attr(kAXSelectedAttribute) as? Bool) == true || $0.elements(kAXChildrenAttribute).contains { $0.isSame(element) } }) {
            parent = extra
        }
        let parentRole = parent?.role ?? ""
        var menuName = name.isEmpty ? (parent?.string(kAXTitleAttribute) ?? "") : name
        // A status menu hangs off an unnamed menu extra: it is the application's menu ("a VPN app's menu").
        if menuName.isEmpty, parentRole == "AXMenuBarItem" || parent?.string(kAXSubroleAttribute) == "AXMenuExtra" {
            menuName = parent?.string(kAXDescriptionAttribute) ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        }
        if menuName.isEmpty, let (n, at) = StatusMenus.lastOpened, Date().timeIntervalSince(at) < 3 {
            StatusMenus.lastOpened = nil
            menuName = n.components(separatedBy: ",").first ?? n
            Speech.speakMessage(String(localized: "\(menuName) menu", comment: "A menu bar item: %@ is its name (View menu)"))
            return
        }
        let isSubmenu = parentRole == "AXMenuItem"
        if parentRole == "AXMenuBarItem", Date().timeIntervalSince(Speech.lastMenuBarItemSpoken) < 0.4 { return }   // already said ("View menu, 5 of 10")
        // A context menu says so (6 Oct 2026): one just asked for (VO Shift M, the right Option, Shift F10), or
        // any menu that hangs off no menu bar, menu or button, even when the app gives it a name.
        let asked = Date().timeIntervalSince(Self.contextMenuRequestedAt) < 2
        let ownMenu: Set<String> = ["AXMenuBarItem", "AXMenuItem", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXButton"]   // a menu bar, submenu or pop-up button's menu
        if asked || (!ownMenu.contains(parentRole) && parent?.string(kAXSubroleAttribute) != "AXMenuExtra" && StatusMenus.lastOpened == nil) {
            Self.contextMenuRequestedAt = .distantPast
            VoiceOverSounds.play("PopupAppeared.aiff")
            Speech.speakMessage(String(localized: "context menu", comment: "Spoken message"))
            return
        }
        Speech.speakMessage(menuName.isEmpty ? String(localized: "context menu", comment: "Spoken message")
            : isSubmenu ? String(localized: "\(menuName) submenu", comment: "A submenu opened: its name") : String(localized: "\(menuName) menu", comment: "A menu bar item: %@ is its name (View menu)"))
    }
    /// The menu bar title whose menu this is, found from the bar (a menu's own parent can be wrong: iPad apps).
    public static func menuBarItem(owning menu: AXUIElement) -> AXUIElement? {
        guard menu.role == "AXMenu", menu.element(kAXParentAttribute)?.role != "AXMenuBarItem",
              let bar = AXUIElementCreateApplication(menu.pid).element(kAXMenuBarAttribute) else { return nil }
        for item in bar.elements(kAXChildrenAttribute).prefix(20) where item.elements(kAXChildrenAttribute).contains(where: { CFEqual($0, menu) }) { return item }
        return nil
    }
    /// When a context menu was last asked for by key; the menu that opens then is announced as one.
    public static var contextMenuRequestedAt = Date.distantPast
    open func event_menuEnd() {}
    /// The last text field the focus was on (a combo box's search field owns its list of results).
    public static var listField: AXUIElement?
    /// The focus moved into the results of a search field that keeps the keys (1Password's Quick Access: the first
    /// letter moves the focus to the first result, and the rest went unechoed, 12 Nov 2026): the field the keys go to.
    static func typingField(for e: AXUIElement) -> AXUIElement? {
        guard let f = listField, f.role != "?", !CFEqual(f, e) else { return nil }
        let owned = f.elements("AXOwns") + f.elements("AXLinkedUIElements")
        guard !owned.isEmpty else { return nil }
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 8 { if owned.contains(where: { CFEqual($0, x) }) { return f }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }
    open func event_typedCharacter(_ ch: Character) {
        if !hasNavigableText, let f = Self.typingField(for: element) { ObjectFactory.make(f).event_typedCharacter(ch); return }
        // Keys that come while a word's end waits for the field are held back, so they reach the echo in order.
        if Self.waitingForField { Self.heldTyped.append((self, ch)); return }
        if role == .passwordEdit || Speech.typingIntoSecretField { Speech.speakSecureCharacter(); return }
        let inWord = ch.isLetter || ch.isNumber || ch == "'" || ch == "’"
        let editable = hasNavigableText && !states.contains(.readOnly)
        if inWord, hasNavigableText, Speech.typedWordSoFar.isEmpty, !Speech.typedWordWasEdited, Speech.echoesTypedWords(editable: editable) {
            // (A key held back starts its word where the field put it, not at the caret, which is past it by now.)
            Self.wordStart = Self.replayWordStart ?? (try? makeTextInfo(.caret))?.start
            Self.replayWordStart = nil   // only for the first word after the word that waited
        }
        guard !inWord, ch != "\u{8}", hasNavigableText, !Speech.typedWordSoFar.isEmpty || Speech.typedWordWasEdited else {
            Speech.speakTypedCharacter(ch, inEditable: editable)
            return
        }
        // With word echo off for this field (the default) nothing needs the field's own word: every space and
        // punctuation mark waited up to 100 ms for the field and held back the keys after it (a review, 13 Nov 2026).
        guard Speech.echoesTypedWords(editable: editable) else {
            Speech.speakTypedCharacter(ch, inEditable: editable)
            return
        }
        // A word ends: its word is read from the field once the field has taken this key, looked for every 10 ms for
        // up to 100 ms; the letters typed if it hasn't by then.
        Self.waitingForField = true
        let start = Speech.typedWordWasEdited ? nil : Self.wordStart   // (a Backspace may have gone back past it)
        func attempt(_ n: Int) {
            var found = (taken: false, word: String?.none, next: Int?.none)
            var nextStart: Int?
            if let info = try? makeTextInfo(.caret) {
                let from = max(0, info.start - 80)
                found = Speech.fieldWord(endedBy: ch, before: info.textRange(from, info.start), notBefore: start.map { $0 - from })
                nextStart = found.next.map { $0 + from }
            }
            if !found.taken, n < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { attempt(n + 1) }; return }
            if !found.taken { Log.io("typed word: the field hadn't taken the key after 100 ms; the letters typed") }
            Speech.speakTypedCharacter(ch, inEditable: editable, wordBefore: { found.word })
            Self.waitingForField = false
            Self.replayWordStart = nextStart
            while !Self.waitingForField, !Self.heldTyped.isEmpty {
                let (o, c) = Self.heldTyped.removeFirst()
                o.event_typedCharacter(c)
            }
            Self.replayWordStart = nil
        }
        attempt(0)
    }
    /// Where the caret was when the word being typed began, so its end is told from the word before's.
    private static var wordStart: Int?
    /// A word's end is waiting for the field; keys typed meanwhile are held back.
    private(set) static var waitingForField = false
    private static var heldTyped: [(TurnOverObject, Character)] = []
    /// Where the field put the word after the one just ended, for a key held back that starts it.
    private static var replayWordStart: Int?

    /// Dispatch (NVDA: eventHandler.executeEvent's last step).
    open func handleEvent(_ event: Event) {
        if event.kind == .caret || event.kind == .valueChange || event.kind == .selection, let f = API.focusObject, f.role == .passwordEdit,
           f.isSameElement(as: self) || axRole == "AXWebArea" {
            SecureEcho.changed(f.element)
            return
        }
        if event.kind == .gainFocus, role == .passwordEdit { SecureEcho.focused(element) }
        if event.kind == .gainFocus { SettingsPanePlugin.focusMoved(to: self) }
        switch event.kind {
        case .gainFocus: event_gainFocus()
        case .loseFocus: event_loseFocus()
        case .focusEntered: event_focusEntered()
        case .focusExited: event_focusExited()
        case .foreground: event_foreground()
        case .valueChange: event_valueChange()
        case .nameChange: event_nameChange()
        case .stateChange: event_stateChange()
        case .descriptionChange: event_descriptionChange()
        case .caret: event_caret()
        case .selection: event_selection()
        case .textChange: event_textChange()
        case .alert: event_alert()
        case .menuStart: event_menuStart()
        case .menuEnd: event_menuEnd()
        case .typedCharacter: if let c = event.character { event_typedCharacter(c) }
        case .appModuleGainFocus, .appModuleLoseFocus: break
        case .liveRegionChange: event_liveRegionChange()
        }
    }
}

/// Makes the right object for an element (NVDA: NVDAObject.__new__ with findOverlayClasses).
public enum ObjectFactory {
    /// `known`: the element's role and subrole, already read (the focus's ancestors kept from the last focus).
    public static func make(_ element: AXUIElement, known: (role: String, subrole: String?)? = nil) -> TurnOverObject {
        let (axRole, subrole) = known ?? roles(of: element)
        let role = axRole == "AXGroup" ? (QtItemViews.role(of: element) ?? Role.from(axRole: axRole, subrole: subrole)) : Role.from(axRole: axRole, subrole: subrole)
        // The object's init takes the role and subrole read here rather than asking again (a review, 13 Nov 2026).
        // Set just before each init: a module's objectClass hook may make other objects first.
        func made(_ cls: TurnOverObject.Type) -> TurnOverObject {
            TurnOverObject.knownRoles = (element, axRole, subrole)
            return cls.init(element: element)
        }
        let module = AppModuleHandler.shared.appModule(for: element.pid)
        if let cls = module.objectClass(for: element, role: role, subrole: subrole) { return made(cls) }
        for plugin in GlobalPluginHandler.shared.plugins {
            if let cls = plugin.objectClass(for: element, role: role, subrole: subrole) { return made(cls) }
        }
        if role == .button, PreferenceTab.isPreferenceTab(element) { return made(PreferenceTab.self) }
        switch role {
        case .webArea: return EditableWebArea.isEditable(element) ? made(EditableWebArea.self) : made(WebArea.self)
        case .editableText, .searchField, .passwordEdit, .document, .textFrame: return made(EditableText.self)
        // A combo box you type into (a web search box with suggestions: Wikipedia's) is edited like a text field.
        case .comboBox where element.attr(kAXSelectedTextRangeAttribute) != nil: return made(EditableComboBox.self)
        case .dialog, .sheet: return made(Dialog.self)
        case .slider: return made(Slider.self)
        // (A Qt item view keeps its own arrows: its items say nothing of being chosen, and the app moves its focus.)
        case .table, .list, .treeView, .outline, .browser: return axRole == "AXGroup" ? made(TurnOverObject.self) : made(SelectableList.self)
        default: return made(TurnOverObject.self)
        }
    }

    /// An element's role and subrole in one question to the app, as `role` and `string(kAXSubroleAttribute)` give
    /// them ("?" and nil when missing). One question rather than two, for every object made (a review, 13 Nov 2026).
    /// An app that won't answer a question for several is asked for each.
    static func roles(of element: AXUIElement) -> (String, String?) {
        let a = element.attrs([kAXRoleAttribute, kAXSubroleAttribute])
        if a.isEmpty { return (element.role, element.string(kAXSubroleAttribute)) }
        return ((a[kAXRoleAttribute] as? String) ?? "?", a[kAXSubroleAttribute] as? String)
    }
}

/// Repeats of the same live text within a moment are one announcement (Chromium posts a change per node).
public enum LiveRegions {
    private static var last: (String, Date) = ("", .distantPast)

    /// The page's live regions (aria-live polite or assertive) and their words now. A walk of at most 600 elements and
    /// 50 ms, not into a live region found. It runs on main before every browse mode Enter and Space: up to 1,500
    /// elements, two questions each, held the key on a long page (a review, 14 Nov 2026). A region past the limit is
    /// still said when the browser posts its change; only Safari's silent ones (watchAfterPress) are missed there.
    static func snapshot(in root: AXUIElement, limit: Int = 600, seconds: TimeInterval = 0.05) -> [(element: AXUIElement, text: String, assertive: Bool)] {
        var out: [(AXUIElement, String, Bool)] = []
        var queue = [root], next = 0
        let until = Date().addingTimeInterval(seconds)
        while next < queue.count, next < limit, Date() < until {
            let e = queue[next]; next += 1
            if let live = e.string("AXARIALive"), live == "polite" || live == "assertive" {
                out.append((e, ElementMatcher.text(of: e), live == "assertive")); continue
            }
            queue += e.elements(kAXChildrenAttribute)
        }
        return out
    }

    /// After a press on a page: the live regions are looked at a few times, and words that came into one are said.
    /// Safari changed a polite region ("Pressed!") and posted nothing (the test page, 11 Nov 2026); where the browser
    /// does post, the same words aren't said twice (speak's own check).
    /// Called before the key or press goes to the page (a page answers within milliseconds: looked at after, the
    /// region already held the new words); a second call just after is the same press.
    private static var watchStartedAt = Date.distantPast
    public static func watchAfterPress(in root: AXUIElement) {
        if Date().timeIntervalSince(watchStartedAt) < 0.5 { return }
        watchStartedAt = Date()
        let before = snapshot(in: root)
        guard !before.isEmpty else { return }
        var said: [String] = []
        for delay in [0.4, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for (e, old, assertive) in before {
                    let now = ElementMatcher.text(of: e)
                    guard now != old, !now.isEmpty, !said.contains(now) else { continue }
                    said.append(now)
                    let added = now.hasPrefix(old) && !old.isEmpty ? String(now.dropFirst(old.count)).trimmingCharacters(in: .whitespacesAndNewlines) : now
                    if !added.isEmpty { speak(added, from: e, assertive: assertive) }
                }
            }
        }
    }
    public static func speak(_ text: String, from element: AXUIElement, assertive: Bool) {
        let t = String(text.prefix(500))
        // A streaming page re-posts the same text many times; it is news once (again only after a long quiet).
        if t == last.0, Date().timeIntervalSince(last.1) < 30 { last.1 = Date(); return }
        // A live region inside another posts for both: the same words again, one a part of the other, at once
        // (The Playroom's Uno, a tester, 9 Oct 2026). Within a second and a half, a part of what was just said is not news.
        if Date().timeIntervalSince(last.1) < 1.5, !last.0.isEmpty, last.0.contains(t) { Log.io("live region: repeat of a part, not said"); return }
        last = (t, Date())
        if assertive { Speech.cancel() }
        Log.io("live region: \(Log.words(String(t.prefix(80))))")
        Speech.speakNews(t)
    }
}


/// Each app and role first found read-only, logged once: a toolkit that answers "not settable" for a field that is
/// typed in would be found in a sweep (a review, 13 Nov 2026).
enum ReadOnlyLog {
    // Every read and write is inside `lock`, from whichever thread makes an object.
    nonisolated(unsafe) private static var seen: Set<String> = []
    private static let lock = NSLock()
    static func note(_ e: AXUIElement, _ role: String) {
        let b = NSRunningApplication(processIdentifier: e.pid)?.bundleIdentifier ?? "pid \(e.pid)"
        lock.lock(); let fresh = seen.insert(b + "|" + role).inserted; lock.unlock()
        if fresh { Log.io("read-only edit: \(role) in \(b)") }
    }
}
