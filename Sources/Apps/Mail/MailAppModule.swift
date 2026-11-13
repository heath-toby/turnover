// SPDX-License-Identifier: GPL-3.0-or-later
// Mail. The message list says which messages are unread (Mail shows it only as a dot; its row offers
// the action "Read" while unread and "Unread" once read), Shift+Command+U says which way it went, and
// the compose body has a name.
import Foundation
import ApplicationServices

package final class MailAppModule: AppModule {
    static let bundleID = "com.apple.mail"

    // MARK: The message's header fields, read-only edits on Tab (a tester, 13 Nov 2026: From, To, Cc and Subject
    // reachable with Tab, as NVDA reads Outlook's; the buttons under them are a toolbar). Mail draws them as one text
    // area of lines, the sender's line, the subject's, then "To:", "Cc:", "Reply-To:", names as attachments.

    /// The field Tab is on, in the header text area.
    static var headerAt: (area: AXUIElement, index: Int, at: Date)?

    static func isHeaderArea(_ e: AXUIElement) -> Bool {
        e.role == "AXTextArea" && e.element(kAXParentAttribute)?.string(kAXDescriptionAttribute) == "message headers"
    }
    /// One of the header's buttons (the toolbar under the fields).
    static func isHeaderButton(_ e: AXUIElement) -> Bool {
        ["AXButton", "AXMenuButton"].contains(e.role) && e.element(kAXParentAttribute)?.string(kAXDescriptionAttribute) == "message content"
    }
    /// The header text area of the message `e` is in or beside (the first message shown).
    static func headerArea(near e: AXUIElement) -> AXUIElement? {
        if isHeaderArea(e) { return e }
        var content: AXUIElement? = isHeaderButton(e) ? e.element(kAXParentAttribute) : nil
        // The message the focus is in (a conversation shows several), else the first; the strips as last read (the
        // toolbar's cache, a second old at most), not walked again on every Tab in the list (a review, 13 Nov 2026).
        if content == nil, let w = SettingsPanePlugin.windowOf(e) {
            let strips = SettingsPanePlugin.named(in: w).map(\.0)
            content = strips.first { g in var p: AXUIElement? = e, n = 0; while let x = p, n < 12 { if x.isSame(g) { return true }; p = x.element(kAXParentAttribute); n += 1 }; return false } ?? strips.first
        }
        guard let c = content else { return nil }
        return headerArea(in: c)
    }

    /// The header text area of one message's "message content" group.
    static func headerArea(in content: AXUIElement) -> AXUIElement? {
        guard let h = content.elements(kAXChildrenAttribute).first(where: { $0.string(kAXDescriptionAttribute) == "message headers" }) else { return nil }
        return h.elements(kAXChildrenAttribute).first { $0.role == "AXTextArea" }
    }

    /// The header area found for the selected row, kept while that row (by its words) stays selected: the Tab
    /// command's availability is asked on every key in the list, and the window was walked each time (a review,
    /// 13 Nov 2026). A row whose message has not loaded yet is looked at again after a second.
    static var headerCache: (row: AXUIElement, key: String, area: AXUIElement?, at: Date)?

    /// From the message list: the header of the message the selected row shows. A conversation shows several
    /// messages; the first shown was taken whichever row was chosen (a review, 13 Nov 2026), so the one whose sender
    /// and subject match the row's is chosen.
    static func headerAreaFromList(_ f: AXUIElement) -> AXUIElement? {
        let table = f.string(kAXDescriptionAttribute) == "messages" ? f : MailMessageRow.isMessageRow(f) ? f.element(kAXParentAttribute) : nil
        guard let table, let row = MailMessageRow.isMessageRow(f) ? f : table.elements(kAXSelectedRowsAttribute).first else { return headerArea(near: f) }
        let key = MailUnread.key(row)
        if let c = headerCache, c.row.isSame(row), c.key == key {
            if let a = c.area, a.role != "?" { return a }
            if c.area == nil, Date().timeIntervalSince(c.at) < 1 { return nil }
        }
        var area: AXUIElement?
        if let w = SettingsPanePlugin.windowOf(f) {
            let strips = SettingsPanePlugin.named(in: w).map(\.0)
            let areas = strips.compactMap(headerArea(in:))
            if areas.count > 1 {
                let texts = key.components(separatedBy: "|")
                let candidates = areas.map { a -> (from: String, subject: String) in
                    let fields = headerFields(a)
                    return (fields.first?.text ?? "", fields.count > 1 ? fields[1].text : "")
                }
                area = areas[bestHeader(sender: texts.first ?? "", subject: texts.count > 1 ? texts[1] : "", candidates: candidates)]
            } else { area = areas.first }
        }
        headerCache = (row, key, area, Date())
        return area
    }

    /// Which message's header matches a row: its sender in the From field counts most, the subject next; the first
    /// shown when none match.
    package static func bestHeader(sender: String, subject: String, candidates: [(from: String, subject: String)]) -> Int {
        func has(_ a: String, _ b: String) -> Bool { !b.isEmpty && a.range(of: b, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        var best = 0, bestScore = 0
        for (i, c) in candidates.enumerated() {
            let score = (has(c.from, sender) ? 2 : 0) + (has(c.subject, subject) ? 1 : 0)
            if score > bestScore { best = i; bestScore = score }
        }
        return best
    }

    /// The fields: label, words (names in place of their attachments) and where the line starts.
    static func headerFields(_ area: AXUIElement) -> [(label: String, text: String, start: Int)] {
        let value = area.string(kAXValueAttribute) ?? ""
        let names = area.elements(kAXChildrenAttribute).filter { $0.string(kAXSubroleAttribute) == "AXTextAttachment" }
            .map { ($0.string(kAXValueAttribute) ?? $0.string(kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespaces) }
        var out: [(String, String, Int)] = []
        var k = 0, start = 0
        for (i, line) in value.components(separatedBy: "\n").enumerated() {
            defer { start += (line as NSString).length + 1 }
            var words: [String] = [], plain = ""
            for ch in line {
                if ch == "\u{FFFC}" {
                    if !plain.trimmingCharacters(in: .whitespaces).isEmpty { words.append(plain.trimmingCharacters(in: .whitespaces)) }
                    plain = ""
                    if k < names.count, !names[k].isEmpty { words.append(names[k]) }
                    k += 1
                } else { plain.append(ch) }
            }
            if !plain.trimmingCharacters(in: .whitespaces).isEmpty { words.append(plain.trimmingCharacters(in: .whitespaces)) }
            guard !words.isEmpty else { continue }
            var label = ""
            // "To:", "Cc:", "Reply-To:": Mail's own label, in the Mac's language.
            if let first = words.first, let colon = first.firstIndex(of: ":"), first.distance(from: first.startIndex, to: colon) <= 14 {
                label = String(first[..<colon])
                let rest = first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if rest.isEmpty { words.removeFirst() } else { words[0] = rest }
            } else if i == 0 { label = String(localized: "From", comment: "A received message's sender, read as a field") }
            else if out.count == 1 { label = String(localized: "Subject", comment: "A received message's subject, read as a field") }
            guard !words.isEmpty else { continue }
            out.append((label, words.joined(separator: ", "), start))
        }
        return out
    }

    /// Reading a message in browse mode with no link or control before the reading position: Shift Tab is the header's.
    /// A message being written (its body is a web area too).
    static func compose(_ e: AXUIElement) -> Bool { place.hasPrefix("compose:") || (e.role == "AXWebArea" && EditableWebArea.isEditable(e)) }

    static func atMessageStart() -> Bool {
        // (By the focus, not the place noted: the message's body is drawn by Mail's web content process, whose
        // focus news never reaches this module.)
        guard let f = API.focusObject, f.axRole == "AXWebArea" || SettingsPanePlugin.isInWeb(f.element), !compose(f.element) else { return false }
        // On the message itself, browse mode not yet in it (just come from the header's buttons): its start.
        guard let d = API.focusTreeInterceptor else { return f.axRole == "AXWebArea" }
        guard !d.passThrough else { return false }
        let roles: Set<String> = ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox"]
        return d.buffer.find(from: d.position, forward: false, roles: roles) == nil
    }

    /// To field `index` of the header: the text area takes the keyboard, its caret at the line, and the field is said.
    func goHeader(_ area: AXUIElement, _ index: Int) {
        let fields = Self.headerFields(area)
        guard fields.indices.contains(index) else { Tones.edge(); return }
        let f = fields[index]
        Self.headerAt = (area, index, Date())
        _ = area.set(kAXFocusedAttribute, kCFBooleanTrue)
        var r = CFRange(location: f.start, length: 0)
        if let v = AXValueCreate(.cfRange, &r) { _ = area.set(kAXSelectedTextRangeAttribute, v) }
        // TurnOver's focus is the field too, whether or not Mail's own follows (its event is held back as said).
        let obj = ObjectFactory.make(area)
        API.setFocusObject(obj, ancestors: obj.ancestors)
        notePlace(area)
        Log.io("mail: header field \(index + 1) of \(fields.count)")
        Tones.focusTick()
        Speech.cancel()
        let role = String(localized: "read-only edit", comment: "A role: a text field that can't be typed in")
        Speech.speakMessage([f.label, role, f.text].filter { !$0.isEmpty }.joined(separator: ", "))
        ObjectNavigator.shared.focusMoved(to: area, pid: pid)
    }

    /// Each message's header buttons: the row of buttons standing directly in its "message content" group.
    static func headerStrips(in window: AXUIElement) -> [(AXUIElement, CGRect)] {
        var out: [(AXUIElement, CGRect)] = []
        var stack: [(AXUIElement, Int)] = [(window, 0)], visited = 0
        while let (e, d) = stack.popLast(), visited < 300 {
            visited += 1
            let r = e.role
            if r == "AXGroup", e.string(kAXDescriptionAttribute) == "message content" {
                let buttons = e.elements(kAXChildrenAttribute).filter { ["AXButton", "AXMenuButton"].contains($0.role) }
                    .compactMap { b in TurnOverObject.frame(b).map { (b, $0) } }
                // The row: the buttons level with Reply.
                guard let reply = buttons.first(where: { $0.0.string(kAXDescriptionAttribute) == "Reply" }) else { continue }
                let row = buttons.filter { abs($0.1.midY - reply.1.midY) < 4 }
                if row.count >= 3 { out.append((e, row.map(\.1).reduce(row[0].1) { $0.union($1) })) }
                continue
            }
            if d > 8 || ["AXTable", "AXOutline", "AXToolbar", "AXWebArea", "AXList"].contains(r) { continue }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).map { ($0, d + 1) })
        }
        return out
    }

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        // The message's header buttons (bin, Reply, Reply All, Forward, Attachments): a toolbar, one Tab stop with the
        // arrows along it (a tester, 13 Nov 2026). They sit loose in the "message content" group, one per message.
        SettingsPanePlugin.namedToolbars[bundleIdentifier] = { Self.headerStrips(in: $0) }
        script("mail_composeNext", String(localized: "Writing a message: the next field, including the Priority, From and Signature pop-ups", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            self.composeMove(forward: true, from: f, g)
        }.isAvailable = { Self.place.hasPrefix("compose:") && Self.place != "compose:body" }   // Tab in the message is the message's
        script("mail_composePrevious", String(localized: "Writing a message: the previous field, including the pop-ups", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            self.composeMove(forward: false, from: f, g)
        }.isAvailable = { Self.place.hasPrefix("compose:") }
        script("mail_toMailboxes", String(localized: "From the message list: the mailbox list (Shift Tab)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            self.focusList("mailboxes", from: f)
        }.isAvailable = { Self.place == "messages" }
        // Return in the search field: Mail searches and says nothing; the keys stayed in the field and Tab went to the
        // toolbar (8 Oct 2026). Say how many results, and go to them.
        script("mail_submitSearch", String(localized: "Searching: Return searches, says how many results, and goes to them", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            // The count from the message list itself, not from the window's title: the title's "12 results" is
            // English only, and other languages heard nothing (a review, 13 Nov 2026). Up to 2 s for the list to change.
            let table = self.messageTable(from: f)
            let before = table.map(Self.rowCount) ?? -1
            g.send()
            guard let table else { return }
            let pressed = InputManager.lastKeyDownAt
            Poll.until(every: 0.1, limit: 2, waitNotice: 3, { Self.rowCount(table) != before }) { [weak self] _ in
                guard let self, API.focusPid == self.pid, InputManager.lastKeyDownAt <= pressed else { return }
                let n = Self.rowCount(table)
                Log.io("mail: search done, \(n) rows (\(before) before)")
                Speech.speakMessage(Self.resultsPhrase(n))
                // Not while Mail's search suggestions are open: Return there chose one, and moving away closed them
                // under the user (a review, 13 Nov 2026).
                guard n > 0, !AXHandler.shared.isMenuOpen, let now = API.focusObject?.element else { return }
                self.focusList("messages", from: now)
            }
        }.isAvailable = { API.focusObject?.role == .searchField }
        // Command Shift D sends: say so once the compose window has gone (nothing confirmed it; a tester, 8 Oct 2026).
        script("mail_send", String(localized: "Writing a message: Command Shift D sends it, and says so", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+shift+d"], category: "Mail") { g in
            g.send()
            // Said as the compose window goes, before the window behind it is read: said 1.2 s later, it queued behind
            // that window and its message list, and the next key cut it off (12 Oct 2026: "it's not saying sent").
            guard let w = API.focusObject.flatMap({ SettingsPanePlugin.windowOf($0.element) }) else { return }
            // Watched until the window goes or Mail puts up an alert, up to 30 s: a big attachment or a slow server
            // keeps it open longer than the 3 s once allowed, and "sent" was never said (a review, 13 Nov 2026).
            let pid = w.pid, dialogs = Self.dialogCount(pid)
            Self.sending = (w, Date(), dialogs)
            Poll.until(every: 0.25, limit: Self.sendingLimit, waitNotice: Self.sendingLimit + 1, {
                Self.sendOutcome(windowStillListed: AXUIElementCreateApplication(pid).elements(kAXWindowsAttribute).contains { CFEqual($0, w) },
                                 alert: w.elements(kAXChildrenAttribute).contains { $0.role == "AXSheet" } || Self.dialogCount(pid) > dialogs) != .waiting
            }) { _ in Self.saySentIfGone() }
        }.isAvailable = { Self.place.hasPrefix("compose:") }
        // Command ' and Command Option ' change the quote level of what is being written: say the level it is now
        // (nothing was said; a tester, 12 Oct 2026).
        for (name, desc, key) in [("mail_quoteMore", "Writing a message: increases the quote level, and says it", "kb:command+'"),
                                  ("mail_quoteLess", "Writing a message: decreases the quote level, and says it", "kb:command+option+'")] {
            script(name, desc, gestures: [key], category: "Mail") { g in
                g.send()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let f = API.focusObject, let info = try? f.makeTextInfo(.caret) as? WebTextInfo else { return }
                    let lvl = (info.elementsAtStart().first?.attr("AXBlockQuoteLevel") as? NSNumber)?.intValue ?? 0
                    BufferTextInfo.lastQuoteLevel = lvl
                    Speech.speakMessage(lvl > 0 ? String(localized: "quote level \(String(lvl))", comment: "How deep a quote is in a Mail message") : String(localized: "no quote", comment: "Spoken message"))
                }
            }.isAvailable = { Self.place.hasPrefix("compose:") }
        }
        script("mail_toMessages", String(localized: "From the mailbox list: the message list (Tab)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            self.focusList("messages", from: f)
        }.isAvailable = { Self.place == "mailboxes" }
        // The header fields on Tab: from the message list into the shown message's first field; along the fields;
        // past the last, the header's toolbar; Shift Tab back from its toolbar to the last field.
        script("mail_headerNext", String(localized: "Reading a message: the next header field (From, Subject, To, Cc), then its buttons", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            if Self.isHeaderArea(f) {
                let i = Self.headerAt.flatMap { $0.area.isSame(f) ? $0.index : nil } ?? 0
                if i + 1 < Self.headerFields(f).count { self.goHeader(f, i + 1); return }
                // Past the last field: the buttons, one stop (the toolbar's last used, else its first).
                Self.headerAt = nil
                if let c = f.element(kAXParentAttribute)?.element(kAXParentAttribute),
                   let b = c.elements(kAXChildrenAttribute).first(where: { Self.isHeaderButton($0) }) {
                    let row = c.elements(kAXChildrenAttribute).filter { Self.isHeaderButton($0) }
                    let stop = SettingsPanePlugin.toolbarStop(c, row) ?? b
                    SettingsPanePlugin.focus(stop); return
                }
                g.send(); return
            }
            guard let area = Self.place == "messages" ? Self.headerAreaFromList(f) : Self.headerArea(near: f) else { g.send(); return }
            self.goHeader(area, 0)
        }.isAvailable = {
            guard let f = API.focusObject?.element else { return false }
            return Self.isHeaderArea(f) || (Self.place == "messages" && Self.headerAreaFromList(f) != nil)
        }
        script("mail_headerPrevious", String(localized: "Reading a message: the previous header field", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            if Self.isHeaderArea(f) {
                let i = Self.headerAt.flatMap { $0.area.isSame(f) ? $0.index : nil } ?? 0
                if i > 0 { self.goHeader(f, i - 1); return }
                Self.headerAt = nil
                self.focusList("messages", from: f); return
            }
            // From the message itself, before its first link or button: up to its header's buttons.
            if !Self.isHeaderButton(f), let area = Self.headerArea(near: f), let c = area.element(kAXParentAttribute)?.element(kAXParentAttribute) {
                let row = c.elements(kAXChildrenAttribute).filter { Self.isHeaderButton($0) }
                if let stop = SettingsPanePlugin.toolbarStop(c, row) ?? row.first { Log.io("mail: Shift Tab from the message to its header's buttons"); SettingsPanePlugin.focus(stop); return }
            }
            guard let area = Self.headerArea(near: f) else { g.send(); return }
            self.goHeader(area, max(0, Self.headerFields(area).count - 1))
        }.isAvailable = {
            guard let f = API.focusObject?.element else { return false }
            return Self.isHeaderArea(f) || Self.isHeaderButton(f) || Self.atMessageStart()
        }
        // Escape leaves the message being read, as in Outlook on Windows (7 Oct 2026): a message in its own
        // window closes, and the keys go back to the message list; in the main window, the list takes the keys.
        // Only while reading (browse mode): in focus mode Escape first goes back to browse mode, and in a message
        // being written it is Mail's own.
        script("mail_leaveMessage", String(localized: "Reading a message: back to the message list (closes the message's own window)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: "Mail") { [weak self] g in
            guard let self, let d = API.focusTreeInterceptor else { g.send(); return }
            self.leaveMessage(from: d.webArea, g)
        }.isAvailable = {
            guard let d = API.focusTreeInterceptor, !d.passThrough, d.webArea.pid == pid else { return false }
            return !Self.place.hasPrefix("compose:") && !AXHandler.shared.isMenuOpen
        }
        script("mail_getNewMail", String(localized: "Checks for new mail and says so", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+shift+n"], category: "Mail") { g in
            g.send()
            Speech.speakMessage(String(localized: "checking for new mail", comment: "Spoken message"))
        }
        script("mail_toggleRead", String(localized: "Marks the message read or unread, and says which", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+shift+u"], category: "Mail") { g in
            g.send()
            // The focus is the message list (its rows are read as its selection) or, rarely, a row.
            guard let f = API.focusObject else { return }
            let rows = f.element.string(kAXDescriptionAttribute) == "messages" ? f.element.elements(kAXSelectedRowsAttribute) : MailMessageRow.isMessageRow(f.element) ? [f.element] : []
            guard !rows.isEmpty else { return }
            // Mail changes the rows' action a moment after the key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let unread = rows.filter(MailMessageRow.isUnread).count
                let said = rows.count == 1 ? (unread == 1 ? String(localized: "unread", comment: "A Mail message not yet read") : String(localized: "read", comment: "A Mail message marked read"))
                    : unread == rows.count ? String(localized: "\(String(rows.count)) messages marked unread", comment: "Mail messages marked unread: how many") : String(localized: "\(String(rows.count)) messages marked read", comment: "Mail messages marked read: how many")
                Speech.speakMessage(said)
            }
        }
        // Delete, archive, junk, flag and Move Again in the message list: the row the selection lands on is read (a
        // tester, 13 Nov 2026: nothing was said after Delete). Mail posts no selection news once its list has gone
        // quiet (SelectableList.quietUntil), so the row is looked for here.
        script("mail_listAction", String(localized: "In the message list: deletes, archives, moves to junk, flags or moves the message, and reads the message selected after", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:backspace", "kb:delete", "kb:command+backspace", "kb:control+command+a", "kb:shift+command+j", "kb:shift+command+l", "kb:option+command+t"],
               category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element, let table = Self.listOf(f) else { g.send(); return }
            self.actOnMessage(table, g)
        }.isAvailable = { Self.place == "messages" && !AXHandler.shared.isMenuOpen && !TurnOverMenu.shared.isOpen }

        // MARK: Address suggestions (a tester, 13 Nov 2026: Mail's list of addresses under To was never read, and Tab
        // went to the next field without taking the suggestion). Declared last, so they come first for Tab and Return.
        script("mail_suggestionMove", String(localized: "Writing an address: Up and Down move through Mail's suggestions and read them", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:upArrow", "kb:downArrow"], category: "Mail") { [weak self] g in
            guard let self, let s = Self.suggestions else { g.send(); return }
            let list = s.list, before = Self.selectedSuggestion(list)?.index
            g.send()
            let pressed = InputManager.lastKeyDownAt
            Poll.until(every: 0.03, limit: 0.4, waitNotice: 1, { Self.selectedSuggestion(list)?.index != before }) { [weak self] _ in
                guard let self, Self.inAddressField, InputManager.lastKeyDownAt <= pressed else { return }
                self.saySuggestion(list, withPlace: true, again: true)
            }
        }.isAvailable = { Self.suggestionsOpen() }
        script("mail_acceptSuggestion", String(localized: "Writing an address: Tab or Return takes Mail's suggestion, and says the name added", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:tab", "kb:enter"], category: "Mail") { [weak self] g in
            guard let self, let field = API.focusObject?.element else { g.send(); return }
            self.acceptSuggestion(field, g)
        }.isAvailable = { Self.suggestionsOpen() }
        script("mail_closeSuggestions", String(localized: "Writing an address: Escape closes Mail's suggestions", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:escape"], category: "Mail") { g in
            g.send()
            Self.suggestions = nil; Self.suggestionSaid = nil
        }.isAvailable = { Self.suggestionsOpen() }
    }

    // MARK: Acting on the message list

    /// The message list `e` is or is in.
    static func listOf(_ e: AXUIElement) -> AXUIElement? {
        e.string(kAXDescriptionAttribute) == "messages" ? e : MailMessageRow.isMessageRow(e) ? e.element(kAXParentAttribute) : nil
    }

    /// When Mail's own selection news for a message row last came (or TurnOver's in its place).
    static var rowEventAt = Date.distantPast

    private func actOnMessage(_ table: AXUIElement, _ g: KeyboardGesture) {
        let before = table.elements(kAXSelectedRowsAttribute).first
        let beforeKey = before.map(MailUnread.key) ?? ""
        // The rows either side, noted before Mail selects one and marks it read.
        MailUnread.noteNeighbours(table, of: before)
        let flag = g.keyName.lowercased() == "l"   // the row stays; it is read again with its flag
        g.send()
        let pressed = InputManager.lastKeyDownAt, since = Date()
        Poll.until(every: 0.04, limit: flag ? 0.3 : 0.6, waitNotice: 1, {
            guard !flag, let now = table.elements(kAXSelectedRowsAttribute).first else { return false }
            return !(before.map { CFEqual($0, now) } ?? false) || MailUnread.key(now) != beforeKey
        }) { [weak self] moved in
            guard let self, API.focusPid == self.pid, Self.place == "messages", InputManager.lastKeyDownAt <= pressed else { return }
            // Mail said so itself, and that was read.
            if Self.rowEventAt > since { return }
            guard let now = table.elements(kAXSelectedRowsAttribute).first else {
                Log.io("mail: \(g.keyName) in the list; nothing selected after it")
                return
            }
            if !moved, !flag, MailUnread.key(now) == beforeKey { Log.io("mail: \(g.keyName) in the list; the selection did not move"); return }
            Log.io("mail: \(g.keyName) in the list; reading the row selected now")
            Self.rowEventAt = Date()
            Speech.cancel()
            EventHandler.queue(Event(.selection, ObjectFactory.make(now)))
        }
    }

    // MARK: Address suggestions

    static let addressPlaces: Set<String> = ["compose:Mail.toField", "compose:Mail.ccField", "compose:Mail.bccField", "compose:Mail.replyToField"]
    static var inAddressField: Bool { addressPlaces.contains(place) }
    /// Mail's list of suggested addresses as last found, and the window it is in (nil: a part of the field itself).
    static var suggestions: (list: AXUIElement, window: AXUIElement?)?
    /// The suggestion said last, so typing another letter that leaves it highlighted says nothing more.
    static var suggestionSaid: (text: String, at: Date)?
    private var suggestionLook = 0
    private var suggestionShapeLogged = Date.distantPast
    private static let listRoles: Set<String> = ["AXTable", "AXList", "AXOutline"]

    /// The list is still up: in an address field, its window still one of Mail's and on screen, with rows. Asked on
    /// every Tab, Return and arrow there, so three questions at most.
    static func suggestionsOpen() -> Bool {
        guard inAddressField, let s = suggestions else { return false }
        if let w = s.window {
            guard AXUIElementCreateApplication(w.pid).elements(kAXWindowsAttribute).contains(where: { $0.isSame(w) }) else { suggestions = nil; return false }
            if let size = w.attr(kAXSizeAttribute) { var z = CGSize.zero; axValue(size, .cgSize, &z); if z.height < 4 { return false } }
        }
        guard suggestionCount(s.list) > 0 else { return false }
        return true
    }

    nonisolated static func suggestionRows(_ list: AXUIElement) -> [AXUIElement] {
        let rows = list.elements(kAXRowsAttribute)
        return rows.isEmpty ? list.elements(kAXChildrenAttribute).filter { $0.role != "AXScrollBar" } : rows
    }
    nonisolated static func suggestionCount(_ list: AXUIElement) -> Int {
        var n: CFIndex = 0
        if AXUIElementGetAttributeValueCount(list, kAXRowsAttribute as CFString, &n) == .success, n > 0 { return n }
        AXUIElementGetAttributeValueCount(list, kAXChildrenAttribute as CFString, &n)
        return n
    }

    /// The highlighted suggestion: the list's selected row (or child), or the one marked selected.
    nonisolated static func selectedSuggestion(_ list: AXUIElement) -> (row: AXUIElement, index: Int, count: Int)? {
        let rows = suggestionRows(list)
        guard let sel = list.elements(kAXSelectedRowsAttribute).first ?? list.elements(kAXSelectedChildrenAttribute).first
                ?? rows.first(where: { ($0.attr(kAXSelectedAttribute) as? Bool) == true }) else { return nil }
        return (sel, rows.firstIndex { CFEqual($0, sel) } ?? 0, rows.count)
    }

    /// A suggestion's words: the texts in its row (name, address), each once.
    nonisolated static func suggestionText(_ row: AXUIElement) -> String {
        var parts: [String] = []
        var queue = [(row, 0)], seen = 0
        while !queue.isEmpty, seen < 30 {
            let (e, d) = queue.removeFirst(); seen += 1
            for k in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let t = e.attr(k) as? String { parts.append(t) }
            }
            if d < 3 { queue.append(contentsOf: e.elements(kAXChildrenAttribute).map { ($0, d + 1) }) }
        }
        return joinedParts(parts)
    }

    /// Texts joined for speech: blanks dropped, and each said once (a cell and its text hold the same words).
    package nonisolated static func joinedParts(_ parts: [String]) -> String {
        var out: [String] = []
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || out.contains(where: { $0 == t || $0.contains(t) }) { continue }
            out.removeAll { t.contains($0) }
            out.append(t)
        }
        return out.joined(separator: ", ")
    }

    /// The name in a suggestion's words ("Ann Smith, ann@example.com": "Ann Smith").
    package nonisolated static func namePart(_ suggestion: String) -> String {
        suggestion.components(separatedBy: ", ").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The names an address field holds as tokens: its parts' words.
    nonisolated static func tokenNames(_ field: AXUIElement) -> [String] {
        field.elements(kAXChildrenAttribute).compactMap { c -> String? in
            let t = (c.string(kAXDescriptionAttribute) ?? c.string(kAXTitleAttribute) ?? c.attr(kAXValueAttribute) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }

    /// Mail's suggestion list for the address field `field`: a list with rows in a window of Mail's other than the
    /// one being written in (an untitled window comes and goes as the address fields take the keyboard; seen in the
    /// log, 13 Nov 2026), or a list inside the field. Its shape (roles and counts only) is logged, for the live check.
    private func findSuggestions(field: AXUIElement) -> (list: AXUIElement, window: AXUIElement?)? {
        let compose = SettingsPanePlugin.windowOf(field)
        var shape: [String] = []
        for w in AXUIElementCreateApplication(pid).elements(kAXWindowsAttribute) where !(compose.map { w.isSame($0) } ?? false) {
            let sub = w.string(kAXSubroleAttribute) ?? "-"
            let titled = !(w.string(kAXTitleAttribute) ?? "").isEmpty
            // The main viewer, another message: titled standard windows.
            if sub == "AXStandardWindow", titled { shape.append("\(sub) titled"); continue }
            var queue = [(w, 0)], seen = 0, roles: [String: Int] = [:]
            while !queue.isEmpty, seen < 60 {
                let (e, d) = queue.removeFirst(); seen += 1
                let r = e.role
                roles[r, default: 0] += 1
                if Self.listRoles.contains(r), e.string(kAXDescriptionAttribute) != "messages", Self.suggestionCount(e) > 0 {
                    logSuggestionShape("in a window (\(w.role)/\(sub), titled \(titled)) at depth \(d): \(r)/\(e.string(kAXSubroleAttribute) ?? "-")", list: e)
                    return (e, w)
                }
                if d < 6 { queue.append(contentsOf: e.elements(kAXChildrenAttribute).map { ($0, d + 1) }) }
            }
            shape.append("\(w.role)/\(sub) titled \(titled): \(roles.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        }
        for c in field.elements(kAXChildrenAttribute) where Self.listRoles.contains(c.role) && Self.suggestionCount(c) > 0 {
            logSuggestionShape("inside the field: \(c.role)", list: c)
            return (c, nil)
        }
        if Date().timeIntervalSince(suggestionShapeLogged) > 3 {
            suggestionShapeLogged = Date()
            let kids = field.elements(kAXChildrenAttribute).map(\.role)
            Log.io("mail: no address suggestions found; field \(field.role) with \(kids.count) parts (\(Set(kids).sorted().joined(separator: ", "))); other windows: \(shape.isEmpty ? "none" : shape.joined(separator: "; "))")
        }
        return nil
    }

    private func logSuggestionShape(_ where_: String, list: AXUIElement) {
        guard Date().timeIntervalSince(suggestionShapeLogged) > 3 else { return }
        suggestionShapeLogged = Date()
        let sel = Self.selectedSuggestion(list)
        let rowRoles = sel.map { $0.row.elements(kAXChildrenAttribute).map(\.role).joined(separator: ", ") } ?? "none selected"
        Log.io("mail: address suggestions \(where_), \(Self.suggestionCount(list)) rows, selected \(sel.map { String($0.index + 1) } ?? "none"); the row's parts: \(rowRoles)")
    }

    /// Typing in an address field: once it pauses, the suggestion Mail highlights is said (again only when it changes).
    private func lookForSuggestionsSoon() {
        suggestionLook += 1
        let n = suggestionLook
        for delay in [0.35, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, n == suggestionLook, Self.inAddressField, API.focusPid == pid, let f = API.focusObject?.element else { return }
                // (The second look only for a list slow to come.)
                if delay > 0.5, Self.suggestions != nil { return }
                guard let found = findSuggestions(field: f) else { Self.suggestions = nil; Self.suggestionSaid = nil; return }
                Self.suggestions = found
                saySuggestion(found.list, withPlace: false, again: false)
            }
        }
    }

    private func saySuggestion(_ list: AXUIElement, withPlace: Bool, again: Bool) {
        guard let sel = Self.selectedSuggestion(list) else { return }
        let text = Self.suggestionText(sel.row)
        guard !text.isEmpty else { return }
        let said = withPlace ? "\(text), \(Phrases.position(sel.index + 1, of: sel.count))" : text
        if !again, let s = Self.suggestionSaid, s.text == said || (!withPlace && s.text.hasPrefix(text)) { return }
        Self.suggestionSaid = (said, Date())
        Speech.cancel()
        Speech.redactedInLog("address suggestion") { Speech.speakMessage(said) }
    }

    private func acceptSuggestion(_ field: AXUIElement, _ g: KeyboardGesture) {
        let chosen = Self.suggestions.flatMap { Self.selectedSuggestion($0.list) }.map { Self.suggestionText($0.row) } ?? ""
        let tokens = Self.tokenNames(field), value = field.string(kAXValueAttribute) ?? ""
        Self.suggestions = nil; Self.suggestionSaid = nil
        g.send()
        let pressed = InputManager.lastKeyDownAt
        Poll.until(every: 0.05, limit: 0.8, waitNotice: 1, { Self.tokenNames(field) != tokens }) { changed in
            guard InputManager.lastKeyDownAt <= pressed else { return }
            let now = Self.tokenNames(field)
            var added = now
            for t in tokens { if let i = added.firstIndex(of: t) { added.remove(at: i) } }
            // No token seen, but the field changed: the suggestion's name, as Mail took it.
            let name = added.last ?? ((field.string(kAXValueAttribute) ?? "") != value ? Self.namePart(chosen) : "")
            Log.io("mail: suggestion taken with \(g.keyName); \(changed ? "a new token (\(now.count) now)" : "no new token seen")\(name.isEmpty ? ", nothing to say" : "")")
            guard !name.isEmpty else { return }
            Speech.redactedInLog("address") { Speech.speakMessage(name) }
        }
    }

    // Tab between the mailbox list and the message list. Mail puts its mailbox list in the Tab order only while
    // VoiceOver runs: with TurnOver, Shift Tab from the messages went to the favourites bar and the toolbar, and the
    // mailboxes could not be reached (5 Oct 2026). Worked out as the focus moves; read by the keyboard thread.
    private static let placeLock = NSLock()
    private static var _place = ""   // "messages", "mailboxes" or ""
    static var place: String { placeLock.lock(); defer { placeLock.unlock() }; return _place }

    /// A message being written: its header in the order a person expects. Mail's own Tab skips the three pop-ups
    /// (Priority, From, Signature), so the From address could not be changed from the keyboard (5 Oct 2026).
    /// A compose window's fields as last found, by identifier.
    static var composeFields: (window: AXUIElement, at: Date, byId: [String: AXUIElement], parts: Int)?
    static let composeOrder = ["Mail.toField", "Mail.ccField", "Mail.bccField", "Mail.replyToField", "Mail.subjectField",
                               "popup_priority", "popup_from", "popup_signature", "body"]

    /// How many parts the header holds around its fields (the children of the To field's row, and of the container
    /// above it, as one number): a field shown with View is a new part there. -1 when no field is known.
    static func headerPartCount(_ byId: [String: AXUIElement]) -> Int {
        guard let field = byId["Mail.toField"] ?? byId["Mail.subjectField"], let row = field.element(kAXParentAttribute) else { return -1 }
        var a: CFIndex = 0, b: CFIndex = 0
        AXUIElementGetAttributeValueCount(row, kAXChildrenAttribute as CFString, &a)
        if let up = row.element(kAXParentAttribute) { AXUIElementGetAttributeValueCount(up, kAXChildrenAttribute as CFString, &b) }
        return a * 1000 + b
    }

    /// Whether the compose fields last found must be looked for again: the field TurnOver is on is a header field
    /// they don't hold, or the header's parts have changed in number since.
    package static func composeCacheMisses(fieldID: String, fieldCached: Bool, partsThen: Int, partsNow: Int) -> Bool {
        (composeOrder.contains(fieldID) && !fieldCached) || partsThen != partsNow
    }

    private func notePlace(_ e: AXUIElement) {
        var p = ""
        let id = e.string(kAXIdentifierAttribute) ?? ""
        if Self.composeOrder.contains(id) { p = "compose:" + id }
        // Mail names the body "message body" both when writing and when reading: only an editable one is writing.
        else if e.role == "AXWebArea", e.string(kAXDescriptionAttribute) == "message body", EditableWebArea.isEditable(e) { p = "compose:body" }
        else if e.role == "AXWebArea" { p = "reading" }
        else if e.string(kAXDescriptionAttribute) == "messages" || MailMessageRow.isMessageRow(e) { p = "messages" }
        else if e.role == "AXOutline" || e.element(kAXParentAttribute)?.role == "AXOutline" { p = "mailboxes" }
        Self.placeLock.lock(); Self._place = p; Self.placeLock.unlock()
    }

    private func composeMove(forward: Bool, from: AXUIElement, _ g: KeyboardGesture) {
        guard let w = SettingsPanePlugin.windowOf(from) else { g.send(); return }
        // The window's fields, kept a few seconds: the walk of up to 300 parts, at Mail's pace, made each Tab lag (a
        // tester, 13 Nov 2026: "the tab focus was extremely laggy").
        var byId: [String: AXUIElement] = [:]
        // Walked again when a field shown since is missing from it (View, Bcc Address Field, or Reply-To: the new field
        // was skipped until the cache ran out, a review, 13 Nov 2026): the field Tab is on is a header field not
        // in it, or the header holds a different number of parts than when it was walked.
        let onNow = SettingsPanePlugin.heldRow ?? from
        let onID = onNow.string(kAXIdentifierAttribute) ?? ""
        if let c = Self.composeFields, c.window.isSame(w), Date().timeIntervalSince(c.at) < 8, !c.byId.values.contains(where: { $0.role == "?" }),
           !Self.composeCacheMisses(fieldID: onID, fieldCached: c.byId.values.contains { $0.isSame(onNow) },
                                    partsThen: c.parts, partsNow: Self.headerPartCount(c.byId)) {
            byId = c.byId
        } else {
            var queue = [w]; var seen = 0
            while !queue.isEmpty, seen < 300 {
                let e = queue.removeFirst(); seen += 1
                if let id = e.string(kAXIdentifierAttribute), Self.composeOrder.contains(id), byId[id] == nil { byId[id] = e }
                if e.role == "AXWebArea", e.string(kAXDescriptionAttribute) == "message body" { byId["body"] = e; continue }
                if e.role == "AXToolbar" { continue }
                queue.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
            Self.composeFields = (w, Date(), byId, Self.headerPartCount(byId))
        }
        // Only what is showing (Cc, Bcc, Reply To and Priority come and go with View, Header Fields).
        let present = Self.composeOrder.filter { id in
            guard let e = byId[id] else { return false }
            return id == "body" || ((e.attr(kAXSizeAttribute)).map { v -> Bool in var z = CGSize.zero; axValue(v, .cgSize, &z); return z.height > 1 } ?? false)
        }
        // Where TurnOver is, by the field itself: a field that won't take Mail's focus is held by TurnOver, no focus news
        // comes, and the place noted stayed the field before, so Shift Tab went to Cc again and again (13 Nov 2026).
        let on = SettingsPanePlugin.heldRow ?? from
        let here = byId.first(where: { $0.value.isSame(on) })?.key ?? String(Self.place.dropFirst("compose:".count))
        guard let i = present.firstIndex(of: here) else { g.send(); return }
        let n = forward ? i + 1 : i - 1
        guard present.indices.contains(n), let target = byId[present[n]] else { g.send(); return }   // the ends: Mail's own
        Log.io("mail: \(forward ? "Tab" : "Shift+Tab") from \(here) to \(present[n])")
        SettingsPanePlugin.focus(target)
        Self.placeLock.lock(); Self._place = "compose:" + present[n]; Self.placeLock.unlock()
    }

    /// The message being read inside a scroll area: the first web area that isn't being written in. Mail's "message
    /// content" holds it four levels down (group, scroll area, web area; measured 13 Oct 2026); the message list's
    /// scroll area holds none.
    package static func messageIn(_ scroll: AXUIElement,
                                  isEditable: @MainActor (AXUIElement) -> Bool = EditableWebArea.isEditable) -> AXUIElement? {
        var level = scroll.elements(kAXChildrenAttribute)
        for _ in 0..<6 {
            guard level.count <= 200 else { return nil }
            // An editable web area beside the message is a compose body, not the end of the search. Never
            // descend into it and mistake one of its nested web areas for received mail (issue 179, 29 Oct 2026).
            if let web = level.first(where: { $0.role == "AXWebArea" && !isEditable($0) }) { return web }
            level = level.filter { !["AXTable", "AXOutline", "AXScrollBar", "AXWebArea"].contains($0.role) }.flatMap { $0.elements(kAXChildrenAttribute) }
            if level.isEmpty || level.count > 200 { return nil }
        }
        return nil
    }

    private func landInMessage(_ window: AXUIElement) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, API.focusPid == self.pid else { return }
            // Already reading a page, or typing: leave it.
            if API.focusTreeInterceptor != nil || Self.place.hasPrefix("compose:") { return }
            var queue = [window]; var seen = 0; var hasList = false; var web: AXUIElement?
            while !queue.isEmpty, seen < 400 {
                let e = queue.removeFirst(); seen += 1
                if e.role == "AXTable", e.string(kAXDescriptionAttribute) == "messages" { hasList = true; break }
                if e.role == "AXWebArea" { if web == nil, !EditableWebArea.isEditable(e) { web = e }; continue }
                if e.role == "AXToolbar" { continue }
                queue.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
            guard !hasList, let web else { return }
            Log.io("mail: a message in its own window; reading starts in the message")
            AXHandler.shared.focusChanged(web, pid: self.pid)
        }
    }

    private func leaveMessage(from: AXUIElement, _ g: KeyboardGesture) {
        guard let w = SettingsPanePlugin.windowOf(from) else { g.send(); return }
        // The main viewer has the message list; a message opened on its own (Return with the preview hidden) does not.
        var queue = [w]; var seen = 0; var hasList = false
        while !queue.isEmpty, seen < 400, !hasList {
            let e = queue.removeFirst(); seen += 1
            if e.role == "AXTable", e.string(kAXDescriptionAttribute) == "messages" { hasList = true }
            if e.role == "AXToolbar" || e.role == "AXWebArea" { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        if hasList {
            Log.io("mail: Escape from the message to the list")
            focusList("messages", from: from)
        } else {
            Log.io("mail: Escape closes the message window")
            KeyboardGesture(identifier: "kb:command+w")?.send()
            // Mail brings the main window back; read the list where it is.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let app = AXUIElementCreateApplication(self.pid)
                if let main = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) { self.focusList("messages", from: main) }
            }
        }
    }

    /// The message list in the window `from` is in.
    private func messageTable(from: AXUIElement) -> AXUIElement? {
        guard let w = from.role == "AXWindow" ? from : SettingsPanePlugin.windowOf(from) else { return nil }
        var queue = [w]; var seen = 0
        while !queue.isEmpty, seen < 400 {
            let e = queue.removeFirst(); seen += 1
            if e.role == "AXTable", e.string(kAXDescriptionAttribute) == "messages" { return e }
            if e.role == "AXToolbar" || e.role == "AXWebArea" { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    /// A list's rows, counted without fetching them.
    nonisolated static func rowCount(_ table: AXUIElement) -> Int {
        var n: CFIndex = 0
        return AXUIElementGetAttributeValueCount(table, kAXRowsAttribute as CFString, &n) == .success ? n : 0
    }

    /// What a search found, as said.
    package static func resultsPhrase(_ n: Int) -> String {
        n == 0 ? String(localized: "no results", comment: "Spoken message")
            : n == 1 ? String(localized: "1 result", comment: "A Mail search found one message")
            : String(localized: "\(String(n)) results", comment: "A Mail search: how many messages it found")
    }

    private func focusList(_ wanted: String, from: AXUIElement) {
        guard let w = from.role == "AXWindow" ? from : SettingsPanePlugin.windowOf(from) else { return }
        var queue = [w]; var seen = 0; var target: AXUIElement?
        while !queue.isEmpty, seen < 400, target == nil {
            let e = queue.removeFirst(); seen += 1
            if wanted == "mailboxes", e.role == "AXOutline" { target = e }
            if wanted == "messages", e.role == "AXTable", e.string(kAXDescriptionAttribute) == "messages" { target = e }
            if e.role == "AXToolbar" { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        guard let t = target else { Tones.edge(); return }
        _ = t.set(kAXFocusedAttribute, kCFBooleanTrue)
        // Mail reports the move itself, and that is read; only if it stays quiet does TurnOver read the list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let f = API.focusObject?.element else { return }
            var p: AXUIElement? = f; var hops = 0; var inside = false
            while let x = p, hops < 4 { if x.isSame(t) { inside = true; break }; p = x.element(kAXParentAttribute); hops += 1 }
            if !inside { AXHandler.shared.focusChanged(t.elements(kAXSelectedRowsAttribute).first ?? t, pid: self.pid) }
        }
    }

    /// The window a message was being written in when Command Shift D was pressed, when, and how many dialogs Mail
    /// had open then, until "sent" is said.
    static var sending: (window: AXUIElement, at: Date, dialogs: Int)?
    /// How long a send is watched for.
    nonisolated static let sendingLimit: TimeInterval = 30
    package nonisolated enum SendOutcome: Equatable { case waiting, sent, alert }
    /// The window gone: sent. Still there with an alert on it (no address, the server refused): not sent, and the
    /// alert reads itself.
    package nonisolated static func sendOutcome(windowStillListed: Bool, alert: Bool) -> SendOutcome {
        !windowStillListed ? .sent : alert ? .alert : .waiting
    }
    nonisolated static func dialogCount(_ pid: pid_t) -> Int {
        AXUIElementCreateApplication(pid).elements(kAXWindowsAttribute).filter { $0.string(kAXSubroleAttribute) == "AXDialog" }.count
    }
    /// "Sent" once that window has gone (Mail closes it as the message goes; a missing address leaves it open with
    /// an alert, and nothing is said).
    static func saySentIfGone() {
        guard let s = sending else { return }
        guard Date().timeIntervalSince(s.at) < sendingLimit + 1 else { sending = nil; return }
        let pid = s.window.pid
        let outcome = sendOutcome(windowStillListed: AXUIElementCreateApplication(pid).elements(kAXWindowsAttribute).contains { $0.isSame(s.window) },
                                  alert: s.window.elements(kAXChildrenAttribute).contains { $0.role == "AXSheet" } || dialogCount(pid) > s.dialogs)
        switch outcome {
        case .waiting: return
        case .alert:
            // Closed later without sending (the draft kept), it must not be taken for sent.
            sending = nil
            Log.io("mail: an alert on the message being sent; not said as sent")
        case .sent:
            sending = nil
            Speech.speakMessage(String(localized: "sent", comment: "Spoken message"))
        }
    }

    package override func handleEvent(_ event: Event, next: () -> Void) {
        // After Command Shift D: "sent" before the window and focus behind the compose window are read.
        if Self.sending != nil, [.foreground, .gainFocus].contains(event.kind) { Self.saySentIfGone() }
        if event.kind == .gainFocus {
            notePlace(event.obj.element)
            if !Self.inAddressField { Self.suggestions = nil; Self.suggestionSaid = nil }
        }
        // Typing an address: Mail's suggestions are looked for once the typing pauses.
        if event.kind == .typedCharacter, event.obj.pid == pid, Self.inAddressField { lookForSuggestionsSoon() }
        // Another message chosen: the header field TurnOver was on belongs to the one before.
        if event.kind == .selection, Self.headerAt != nil, !Self.isHeaderArea(event.obj.element) { Self.headerAt = nil }
        // The header text area taking the keyboard for a field TurnOver has just said: not read again whole.
        if event.kind == .gainFocus, let h = Self.headerAt, h.area.isSame(event.obj.element), Date().timeIntervalSince(h.at) < 1.5 { return }
        // The focus on the scroll area around a message (Mail can come back to it after Command Tab; nothing in it is
        // TurnOver's to read, and the arrows only scrolled, 13 Oct 2026): reading starts in the message, as
        // when a message opens in its own window.
        if event.kind == .gainFocus, event.obj.element.role == "AXScrollArea", let web = Self.messageIn(event.obj.element) {
            Log.io("mail: focus on the message's scroll area; reading starts in the message")
            DispatchQueue.main.async { [pid] in AXHandler.shared.focusChanged(web, pid: pid) }
            return
        }
        next()
        // A message opened in its own window (Return with the preview pane hidden, a tester): the reading starts in
        // the message, not on the window's toolbar.
        if event.kind == .foreground, event.obj.element.role == "AXWindow" { landInMessage(event.obj.element) }
        // Mail marks a message read the moment it is selected, before TurnOver can ask: note which of the rows
        // the next key can reach are unread, while they still are.
        if event.kind == .selection || event.kind == .gainFocus {
            let el = event.obj.element
            let table = MailMessageRow.isMessageRow(el) ? el.element(kAXParentAttribute) : (el.string(kAXDescriptionAttribute) == "messages" ? el : nil)
            if let table { MailUnread.snapshot(table) }
            if event.kind == .selection, table != nil { Self.rowEventAt = Date() }
        }
    }

    /// Mail's suggestion list moving its highlight (where it says so): the suggestion is read. Only while an address
    /// field has the keyboard, and never for the message list.
    package override func listSelectionChanged(_ list: AXUIElement) -> Bool {
        guard Self.inAddressField, API.focusPid == pid, Self.listRoles.contains(list.role), list.string(kAXDescriptionAttribute) != "messages" else { return false }
        if let s = Self.suggestions, s.list.isSame(list) {
            saySuggestion(list, withPlace: true, again: false)
            return true
        }
        // A list in a window other than the one being written in: the suggestions, come before the typing paused.
        guard let field = API.focusObject?.element, let fw = SettingsPanePlugin.windowOf(field), let lw = list.element(kAXWindowAttribute), !lw.isSame(fw) else { return false }
        logSuggestionShape("found by its selection news (\(lw.string(kAXSubroleAttribute) ?? "-"))", list: list)
        Self.suggestions = (list, lw)
        saySuggestion(list, withPlace: false, again: false)
        return true
    }

    package override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        if role == .tableRow, MailMessageRow.isMessageRow(element) { return MailMessageRow.self }
        if role == .webArea, EditableWebArea.isEditable(element) { return MailMessageBody.self }
        if element.string(kAXIdentifierAttribute) == "popup_priority" { return MailPriorityPopup.self }
        return nil
    }
}

/// The message window's priority pop-up, which Mail describes by its icon ("Exclamation mark").
final class MailPriorityPopup: TurnOverObject {
    override var name: String { "Priority" }
}

public enum MailRowWords {
    /// Whether a message row's own words already start with unread. Which rows are unread comes from Mail itself (its
    /// Read action); only this check reads words, and they are Mail's, in Mail's language: English "unread" and
    /// TurnOver's word both count, so a Turkish TurnOver over an English Mail doesn't say it twice.
    public static func saysUnread(_ name: String, word: String) -> Bool {
        ["unread", word].contains { !$0.isEmpty && name.range(of: $0, options: [.anchored, .caseInsensitive]) != nil }
    }
}

final class MailMessageRow: TurnOverObject {
    override var name: String {
        let n = super.name
        let unread = String(localized: "unread", comment: "A Mail message not yet read")
        if MailRowWords.saysUnread(n, word: unread) { return n }
        return Self.isUnread(element) || MailUnread.wasUnread(element) ? "\(unread), \(n)" : n
    }


    static func isMessageRow(_ e: AXUIElement) -> Bool {
        e.element(kAXParentAttribute)?.string(kAXDescriptionAttribute) == "messages"
    }

    nonisolated static func isUnread(_ e: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success, let list = names as? [String] else { return false }
        return list.contains { $0.components(separatedBy: "\n").first == "Name:Read" }
    }
}

final class MailMessageBody: EditableWebArea {
    override var name: String { let n = super.name; return n.isEmpty ? String(localized: "message body", comment: "A Mail message's text, when it has no name") : n }

    /// Mail corrects a word as you finish it ("teh" becomes "the"); VoiceOver says so, and so does TurnOver now:
    /// the word as typed is compared with the word in the message a moment later (a tester, ; wishlist 5).
    override func event_typedCharacter(_ ch: Character) {
        let typed = Speech.typedWordSoFar
        // After a Backspace in the word, TurnOver holds only the letters typed since: no comparison is possible.
        let edited = Speech.typedWordWasEdited
        // A key held back while the word before waits for the field comes here again when it is echoed.
        let held = TurnOverObject.waitingForField
        super.event_typedCharacter(ch)
        guard !held, typed.count >= 2, !edited, ch == " " || ".,;:!?".contains(ch) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, API.focusObject?.isSameElement(as: self) == true,
                  let caret = try? self.makeTextInfo(.caret), caret.start > 1 else { return }
            // The word just before the character that ended it.
            let before = caret.copy(); before.start = max(0, caret.start - typed.count - 12); before.end = caret.start
            // Still just after the character that ended the word: a key typed since moves on, and the word being
            // typed now would be mistaken for a correction.
            guard before.text.last == ch || (ch == " " && before.text.last == "\u{a0}") else { return }
            let words = before.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            // Smart quotes aren't corrections: don't and don’t are the same word.
            func plain(_ w: String) -> String { w.lowercased().replacingOccurrences(of: "’", with: "'") }
            guard let now = words.last.map(String.init), !now.isEmpty, plain(now) != plain(typed),
                  !plain(now).hasPrefix(plain(typed)) else { return }
            // The typed word was read from the field after Mail had corrected it: already said as corrected.
            if let said = Speech.lastTypedWordSpoken, plain(said) == plain(now) { return }
            Log.io("autocorrect: a word was changed (\(typed.count) to \(now.count) characters)")
            Speech.speakMessage(String(localized: "corrected to \(now)", comment: "Mail corrected a typed word: %@ is the new word"))
        }
    }
}

/// Which messages near the selection were unread, by sender, subject and time.
enum MailUnread {
    nonisolated(unsafe) private static var unread = Set<String>()   // under `lock`
    nonisolated private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "turnover.mail.unread")

    nonisolated static func key(_ row: AXUIElement) -> String {
        let cell = row.elements(kAXChildrenAttribute).first ?? row
        // The texts (sender, subject, time); the images before them come and go (unread, replied).
        return cell.elements(kAXChildrenAttribute).lazy.compactMap { $0.string(kAXValueAttribute) }.prefix(3).joined(separator: "|")
    }

    static func wasUnread(_ row: AXUIElement) -> Bool {
        let k = key(row)
        lock.lock(); defer { lock.unlock() }
        return !k.isEmpty && unread.contains(k)
    }

    /// Before a key that moves the selection for Mail (Delete, Archive): the rows either side of `row`, noted unread
    /// now, on the main thread, as the key waits. Only noted, never forgotten: a look run after Mail had moved on would
    /// find the row it lands on read already.
    static func noteNeighbours(_ table: AXUIElement, of row: AXUIElement?) {
        guard let i = row.flatMap({ ($0.attr(kAXIndexAttribute) as? NSNumber)?.intValue }) else { return }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(table, kAXRowsAttribute as CFString, &count) == .success else { return }
        for j in [i - 1, i + 1] where j >= 0 && j < count {
            var v: CFArray?
            guard AXUIElementCopyAttributeValues(table, kAXRowsAttribute as CFString, j, 1, &v) == .success,
                  let r = (v as? [AXUIElement])?.first, MailMessageRow.isUnread(r) else { continue }
            let k = key(r)
            guard !k.isEmpty else { continue }
            lock.lock(); unread.insert(k); lock.unlock()
        }
    }

    /// The first row and the rows either side of the selection.
    static func snapshot(_ table: AXUIElement) {
        queue.async {
            // The rows wanted, by index, not all 23,000 of a big mailbox fetched on every move: Mail answers on its own
            // main thread, so the whole fetch held up the next row's name too (a review, 13 Nov 2026).
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(table, kAXRowsAttribute as CFString, &count) == .success, count > 0 else { return }
            func row(_ i: Int) -> AXUIElement? {
                guard i >= 0, i < count else { return nil }
                var v: CFArray?
                guard AXUIElementCopyAttributeValues(table, kAXRowsAttribute as CFString, i, 1, &v) == .success else { return nil }
                return (v as? [AXUIElement])?.first
            }
            let selected = table.elements(kAXSelectedRowsAttribute).first.flatMap { ($0.attr(kAXIndexAttribute) as? NSNumber)?.intValue }
            var indices: Set<Int> = [0]
            if let i = selected { indices.formUnion([i - 1, i + 1].filter { $0 >= 0 && $0 < count }) }
            for i in indices {
                guard let r = row(i) else { continue }
                let k = key(r)
                guard !k.isEmpty else { continue }
                let isUnread = MailMessageRow.isUnread(r)
                lock.lock(); if isUnread { unread.insert(k) } else if i != selected { unread.remove(k) }; lock.unlock()
                if isUnread { Log.io("mail: row \(i) is unread") }
            }
            // The row just read is read now.
            if let i = selected, let r = row(i), !MailMessageRow.isUnread(r) {
                let k = key(r); lock.lock(); unread.remove(k); lock.unlock()
            }
        }
    }
}
