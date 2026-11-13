// SPDX-License-Identifier: GPL-3.0-or-later
// Contacts (18 Oct 2026, the Apple apps sweep). What Contacts gives accessibility (probe, names masked): the people
// as an outline ("personList"), each row "level 2"; a search field; and the chosen person's card, a SwiftUI pane
// (identifier "contactDetailPane") whose scroll area holds the name as a heading, the quick actions (message, call,
// video, mail), each detail as a label and a text area (mobile, email, address…), and buttons (Share Contact…).
// Tab from the list went to the search field and the card's buttons, never to the details (driver).
// What TurnOver changes:
// - A person in the list is said without "level 2".
// - The card (13 Nov 2026, a tester's design): Tab goes through its parts as stops, the name, the action icons
//   (message, call, video, mail; clicked, as they take no press), each button, then the details as one list (Up and
//   Down through phone, email, address…, each its label and words; Space opens the detail's menu, Call, Copy…), the
//   note, and the buttons under it. Shift-Tab goes back; before the name, to the list of people.
import Foundation
import ApplicationServices

final class ContactsAppModule: AppModule {
    static let bundleID = "com.apple.AddressBook"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("contacts_toCard", String(localized: "From the list to the person's card", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Contacts") { [weak self] g in
            // No card shown: editing one (Command L), its fields are Contacts' own to Tab through.
            guard let self else { return }
            guard let card = self.card() else {
                // Editing (Command L): Contacts' own Tab only went between the search and the list, never to the
                // fields (13 Nov 2026). Into the first field.
                if let w = self.window(), let field = Self.editFields(in: w).first {
                    Log.io("contacts: editing; to the first field"); SettingsPanePlugin.focus(field); return
                }
                Log.io("contacts: no card to go to"); g.send(); return
            }
            Log.io("contacts: to the card")
            self.go(to: 0, in: card)
        }.isAvailable = { [weak self] in self?.inList() == true }
        for forward in [true, false] {
            script(forward ? "contacts_cardNext" : "contacts_cardPrevious", forward ? String(localized: "In a card: the next part (the name, the actions, the details list, the note, the buttons)", comment: "A command, as the key list and keyboard help say it") : String(localized: "In a card: the previous part", comment: "A command, as the key list and keyboard help say it"), gestures: [forward ? "kb:tab" : "kb:shift+tab"], category: "Contacts") { [weak self] g in
                guard let self else { return }
            guard let card = self.card() else { g.send(); return }
                let stops = Self.stops(in: card)
                // The detail left from, to come back to.
                if let r = SettingsPanePlugin.heldRow, r.string(kAXIdentifierAttribute) == "ContactCardDetailsView" { Self.lastDetail = r }
                guard let here = self.stopIndex(stops) else { self.go(to: 0, in: card); return }
                let next = here + (forward ? 1 : -1)
                if next < 0, let list = self.list() {
                    _ = list.set(kAXFocusedAttribute, kCFBooleanTrue); AXHandler.shared.focusChanged(list, pid: self.pid); return
                }
                // Past the card's end: round the window, the toolbar (Sidebar, Add, Edit) first, as the screen goes.
                if next >= stops.count, let w = self.window() {
                    if self.toToolbar(in: w) { return }
                    if let field = self.searchField(in: w) { _ = field.set(kAXFocusedAttribute, kCFBooleanTrue); return }
                }
                self.go(to: next, in: card)
            }.isAvailable = { [weak self] in self?.inCard() == true }
        }
        // Shift Tab from the list: Contacts' own went to the window itself and stopped there (13 Nov 2026). To the
        // search field above the list, as the screen has it.
        // Tab from the search field: the people, as the screen goes (Contacts' own went into the card's buttons).
        script("contacts_searchToList", String(localized: "From the search field to the list of people", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Contacts") { [weak self] g in
            guard let self, let list = self.list() else { g.send(); return }
            _ = list.set(kAXFocusedAttribute, kCFBooleanTrue)
            AXHandler.shared.focusChanged(list, pid: self.pid)
        }.isAvailable = { [weak self] in
            guard let self, let f = API.focusObject, f.pid == self.pid else { return false }
            return f.element.string(kAXSubroleAttribute) == "AXSearchField" || f.axRole == "AXSearchField"
        }
        // Shift Tab from the search field: the toolbar above it (Contacts' own went into the card).
        script("contacts_searchToToolbar", String(localized: "From the search field back to the toolbar", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Contacts") { [weak self] g in
            guard let self, let w = self.window(), self.toToolbar(in: w) else { g.send(); return }
        }.isAvailable = { [weak self] in
            guard let self, let f = API.focusObject, f.pid == self.pid else { return false }
            return f.element.string(kAXSubroleAttribute) == "AXSearchField" || f.axRole == "AXSearchField"
        }
        // On the toolbar: Tab on to the search field, Shift Tab back to the card's last part (the window's own order).
        for forward in [true, false] {
            script(forward ? "contacts_toolbarNext" : "contacts_toolbarPrevious", forward ? String(localized: "From the toolbar to the search field", comment: "A command, as the key list and keyboard help say it") : String(localized: "From the toolbar back to the card", comment: "A command, as the key list and keyboard help say it"), gestures: [forward ? "kb:tab" : "kb:shift+tab"], category: "Contacts") { [weak self] g in
                guard let self, let w = self.window() else { g.send(); return }
                if forward, let field = self.searchField(in: w) { _ = field.set(kAXFocusedAttribute, kCFBooleanTrue); return }
                if !forward, let card = self.card() { self.go(to: Self.stops(in: card).count - 1, in: card); return }
                g.send()
            }.isAvailable = { [weak self] in
                guard let self, let f = SettingsPanePlugin.heldRow ?? API.focusObject?.element, f.pid == self.pid else { return false }
                return f.element(kAXParentAttribute)?.role == "AXToolbar"
            }
        }
        script("contacts_toSearch", String(localized: "From the list back to the search field", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Contacts") { [weak self] g in
            guard let self, let w = self.window(),
                  let field = self.searchField(in: w) else { g.send(); return }
            _ = field.set(kAXFocusedAttribute, kCFBooleanTrue)
        }.isAvailable = { [weak self] in self?.inList() == true }
    }

    /// To the window's toolbar, one stop: its item last used, else its first.
    private func toToolbar(in w: AXUIElement) -> Bool {
        guard let tb = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }) else { return false }
        let items = tb.elements(kAXChildrenAttribute).filter { ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox"].contains($0.role) }
        guard let stop = SettingsPanePlugin.toolbarStop(tb, items) ?? items.first else { return false }
        Log.io("contacts: to the toolbar")
        SettingsPanePlugin.focus(stop)
        return true
    }

    /// A card being edited: its fields, the name's then each detail's (an AppKit form beside the list).
    static func editFields(in w: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(w, 0)], seen = 0
        while let (e, d) = stack.popLast(), seen < 400 {
            seen += 1
            let r = e.role
            if r == "AXOutline" || r == "AXToolbar" || e.string(kAXSubroleAttribute) == "AXSearchField" { continue }
            if ["AXTextField", "AXPopUpButton", "AXCheckBox"].contains(r) { out.append(e); continue }
            if d < 8 { stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed().map { ($0, d + 1) }) }
        }
        var framed: [(AXUIElement, CGRect)] = []
        for e in out { if let f = TurnOverObject.frame(e) { framed.append((e, f)) } }
        framed.sort { a, b in
            let ay = a.1.minY, by = b.1.minY
            return abs(ay - by) > 4 ? ay < by : a.1.minX < b.1.minX
        }
        return framed.map { $0.0 }
    }

    // MARK: The card's stops

    enum Stop { case one(AXUIElement), details([AXUIElement]) }

    /// The card's parts in order: the name, each action icon and button, the details as one list, the note, the
    /// buttons under it. Read fresh each time (SwiftUI makes the card anew as a person is chosen).
    static func stops(in card: AXUIElement) -> [Stop] {
        var out: [Stop] = []
        var details: [AXUIElement] = []
        func flushDetails() { if !details.isEmpty { out.append(.details(details)); details = [] } }
        func walk(_ e: AXUIElement, _ d: Int) {
            for c in e.elements(kAXChildrenAttribute) {
                let r = c.role, id = c.string(kAXIdentifierAttribute) ?? ""
                if r == "AXHeading" { flushDetails(); out.append(.one(c)); continue }
                if id == "InlineActionsHStack" { flushDetails(); out.append(.one(c)); continue }
                if r == "AXButton", id == "ContactCardDetailsView" { details.append(c); continue }
                if ["AXButton", "AXMenuButton", "AXTextArea", "AXTextField", "AXCheckBox", "AXPopUpButton"].contains(r) { flushDetails(); out.append(.one(c)); continue }
                if d < 4 { walk(c, d + 1) }
            }
        }
        walk(card, 0)
        flushDetails()
        return out
    }

    /// Which stop TurnOver is on: the held row of the details, or the focus.
    private func stopIndex(_ stops: [Stop]) -> Int? {
        let here = SettingsPanePlugin.heldRow ?? API.focusObject?.element
        guard let here else { return nil }
        return stops.firstIndex { stop in
            switch stop {
            case .one(let e): return e.isSame(here) || { var p = here.element(kAXParentAttribute), n = 0; while let x = p, n < 4 { if x.isSame(e) { return true }; p = x.element(kAXParentAttribute); n += 1 }; return false }()
            case .details(let rows): return rows.contains { $0.isSame(here) }
            }
        }
    }

    private static var lastDetail: AXUIElement?

    private func go(to i: Int, in card: AXUIElement) {
        let stops = Self.stops(in: card)
        guard stops.indices.contains(i) else { Tones.edge(); return }
        switch stops[i] {
        case .one(let e):
            Log.io("contacts: card stop \(i + 1) of \(stops.count), \(e.role)")
            SettingsPanePlugin.focus(e)
        case .details(let rows):
            let at = Self.lastDetail.flatMap { l in rows.firstIndex { $0.isSame(l) } } ?? 0
            Log.io("contacts: card stop \(i + 1) of \(stops.count), the details list, \(rows.count) rows")
            // The list's container: the first detail's group, which doesn't scroll, so the list is counted ("list, 11
            // items", "3 of 11"); the card's scroll area scrolls, and its rows were "item 1" of a list of unknown length.
            // Contacts' own focus onto the row too: left on the note, its news took TurnOver back there, and the next
            // Shift Tab came to the list again (a tester, 13 Nov 2026: Tab stopped, Shift Tab needed).
            _ = rows[at].set(kAXFocusedAttribute, kCFBooleanTrue)
            SettingsPanePlugin.enterList(rows, container: rows[0].element(kAXParentAttribute) ?? card, at: at)
        }
    }

    /// Space or Return on a held place in the card: a detail opens its menu (Call, FaceTime, Copy…), where pressing
    /// would call at once; an action icon, which takes no press, is clicked.
    static func press(_ e: AXUIElement) -> Bool {
        if e.string(kAXIdentifierAttribute) == "ContactCardDetailsView", e.role == "AXButton" {
            lastDetail = e
            let r = AXUIElementPerformAction(e, kAXShowMenuAction as CFString)
            Log.io("contacts: a detail's menu → \(r.rawValue)")
            return r == .success
        }
        if e.string(kAXIdentifierAttribute) == "InlineActionsHStack", let f = TurnOverObject.frame(e) {
            Log.io("contacts: an action icon clicked")
            Tones.press()
            Mouse.click(at: CGPoint(x: f.midX, y: f.midY), button: .left, count: 1)
            return true
        }
        return false
    }

    private func searchField(in w: AXUIElement) -> AXUIElement? {
        var queue = [w], seen = 0
        while !queue.isEmpty, seen < 80 {
            let e = queue.removeFirst(); seen += 1
            if e.string(kAXSubroleAttribute) == "AXSearchField" || e.role == "AXSearchField" { return e }
            if !["AXOutline", "AXScrollArea"].contains(e.role) { queue.append(contentsOf: e.elements(kAXChildrenAttribute)) }
        }
        return nil
    }

    private func window() -> AXUIElement? { AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) }

    private func find(_ id: String, in root: AXUIElement?, limit: Int = 60) -> AXUIElement? {
        guard let root else { return nil }
        var queue = [root], seen = 0
        while !queue.isEmpty, seen < limit {
            let e = queue.removeFirst(); seen += 1
            if e.string(kAXIdentifierAttribute) == id { return e }
            // Not into the list's hundreds of rows.
            if e.role != "AXOutline" { queue.append(contentsOf: e.elements(kAXChildrenAttribute)) }
        }
        return nil
    }
    private func list() -> AXUIElement? { find("personList", in: window()) }
    /// The card's contents: the scroll area inside the detail pane.
    private func card() -> AXUIElement? {
        // macOS 27.2 names the card's scroll area itself (13 Nov 2026: Tab from the list said nothing, the old pane gone).
        // (Two AXUnknown elements before it carry the same identifier.)
        if let w = window() {
            var queue = [w], seen = 0
            while !queue.isEmpty, seen < 150 {
                let e = queue.removeFirst(); seen += 1
                if e.role == "AXScrollArea", e.string(kAXIdentifierAttribute) == "ContactCardScrollViewReader" { return e }
                if e.role != "AXOutline" { queue.append(contentsOf: e.elements(kAXChildrenAttribute)) }
            }
        }
        guard let pane = find("contactDetailPane", in: window()) else { return nil }
        var queue = [pane], seen = 0
        while !queue.isEmpty, seen < 20 {
            let e = queue.removeFirst(); seen += 1
            if e.role == "AXScrollArea" { return e }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    private func inList() -> Bool {
        guard let f = API.focusObject, f.pid == pid, let l = list() else { return false }
        var e: AXUIElement? = f.element; var hops = 0
        while let x = e, hops < 5 { if x.isSame(l) { return true }; e = x.element(kAXParentAttribute); hops += 1 }
        return false
    }
    private func inCard() -> Bool {
        guard let c = card(), let here = SettingsPanePlugin.heldRow ?? API.focusObject?.element, here.pid == pid else { return false }
        var e: AXUIElement? = here; var hops = 0
        while let x = e, hops < 8 { if x.isSame(c) { return true }; e = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        if element.string(kAXIdentifierAttribute) == "InlineActionsHStack" { return CardActionIcon.self }
        if element.string(kAXIdentifierAttribute) == "ContactCardDetailsView", element.role == "AXButton" { return CardDetail.self }
        return [.treeViewItem, .tableRow].contains(role) ? RowWithoutLevel.self : nil
    }
}

/// An action icon of the card (message, call, video, mail): a picture Contacts draws as a button. Said as one.
final class CardActionIcon: TurnOverObject {
    override var role: Role { .button }
}

/// A detail of the card: its label and its words ("mobile, 07…"), not the button's own "mobile, Call".
final class CardDetail: TurnOverObject {
    // As a list's row is read: its words and its place, not "list item" (the list said what it is on the way in).
    override var role: Role { .staticText }
    override var positionInfo: PositionInfo? { nil }
    override var value: String? { nil }   // in the name already
    override var name: String {
        let desc = element.string(kAXDescriptionAttribute) ?? ""
        guard let value = element.string(kAXValueAttribute), !value.isEmpty else { return desc }
        // The description is the label, then the action ("mobile, Call"): the label alone.
        let label = desc.components(separatedBy: ", ").first ?? desc
        return label.isEmpty ? value : "\(label), \(value)"
    }
}

/// A row said without its outline level ("level 2" on every name in Contacts' list).
final class RowWithoutLevel: TurnOverObject {
    override var positionInfo: PositionInfo? {
        guard var p = super.positionInfo else { return nil }
        p.level = nil
        return p
    }
}
