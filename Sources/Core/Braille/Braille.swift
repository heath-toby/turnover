// SPDX-License-Identifier: GPL-3.0-or-later
// Braille (NVDA: braille.handler). While TurnOver leads, the display shows what speech is about: the line under
// the caret (in editable text and in browse mode), or else the focused object, and TurnOver's messages for a few
// seconds. Panning moves along the line and on to the next or previous one; a routing key moves the caret to
// its character, or presses the object. When TurnOver hands back, the display is let go, so VoiceOver can drive it
// again (6 Oct 2026; docs/BRAILLE-PLAN.md).
import Foundation
import ApplicationServices

/// A display driver (NVDA: BrailleDisplayDriver). Calls come on the main thread.
public protocol BrailleDisplayDriver: AnyObject {
    var name: String { get }
    var cellCount: Int { get }
    func write(_ cells: [UInt8])
    func close()
}

/// A key on the display: a routing key over a cell, or one of its named keys ("d2", "joystickUp").
public enum BrailleKey: Equatable {
    case routing(Int)
    case key(String)
}

public enum Braille {
    public private(set) static var display: BrailleDisplayDriver?

    /// What the display is showing.
    private enum Source {
        case text(TextInfo, lineStart: Int)   // a line of text; offsets in it map to cells one for one
        case object(TurnOverObject)
        case message
        case item          // what TurnOver's own cursor is on (a held list, the menu, the VoiceOver cursor)
    }
    private static var source: Source?
    /// A view of TurnOver's own that has the keys (screen recognition's result): the line it shows with the cursor in
    /// it, and what its display keys do ("upArrow", "downArrow", "enter", "route:<offset in the line>").
    public static var modalLine: (() -> (String, Int?)?)?
    public static var modalKey: ((String) -> Void)?
    private static var modalShowing = false
    private static var text = ""
    private static var cursor: Int?
    private static var windowStart = 0
    private static var messageUntil: Date?
    private static var lastWritten: [UInt8] = []
    private static var lastLoggedText = "", lastLoggedStart = -1
    private static var pending: DispatchWorkItem?
    private static var lastCaret = -1
    /// The translated line: cells, the text offset each shows, and the cell the caret is on.
    private static var cells: [UInt8] = []
    private static var cellMap: [Int] = []
    private static var cursorCell: Int?
    /// Cells under selected text (NVDA: show selection).
    private static var selectedCells = Set<Int>()
    private static var selection: (Int, Int)?

    /// The line's bold, italic and underlined stretches (offsets in `text`), when formatting is shown.
    private static var emphasis: [EmphasisRun] = []
    /// Cells under formatted text, given dots 7 and 8 (formatting shown that way).
    private static var emphasisCells = Set<Int>()
    /// Cells put before a paragraph (NVDA's paragraph start marker), read by paragraph.
    private static var leadingCells: [UInt8] = []
    /// Where the window starts are counted from (the focus's place, with context before it), and the cursor is
    /// TurnOver's review cursor (its own shape).
    private static var windowOrigin = 0
    private static var cursorIsReview = false

    /// Back to plain text: no formatting, marker, context or review cursor (each kind of thing shown sets its own).
    private static func plain() { emphasis = []; leadingCells = []; windowOrigin = 0; cursorIsReview = false }

    private static func layout() {
        (cells, cellMap) = BrailleOutput.translate(text, cursor: cursor, emphasis: emphasis)
        cursorCell = cursor.map { c in
            cellMap.firstIndex(of: c) ?? cellMap.firstIndex { $0 > c } ?? cells.count
        }
        selectedCells = []
        if config.braille.showSelection, let (a, b) = selection, b > a {
            for (i, o) in cellMap.enumerated() where o >= a && o < b { selectedCells.insert(i) }
        }
        emphasisCells = []
        if config.braille.formattingMarks == "dots78", !emphasis.isEmpty {
            for (i, o) in cellMap.enumerated() where emphasis.contains(where: { NSLocationInRange(o, $0.range) }) && cells[i] & 0x3F != 0 { emphasisCells.insert(i) }
        }
        // The paragraph marker: cells of its own before the text, standing for its start.
        if !leadingCells.isEmpty {
            let n = leadingCells.count
            cells.insert(contentsOf: leadingCells, at: 0)
            cellMap.insert(contentsOf: Array(repeating: 0, count: n), at: 0)
            cursorCell = cursorCell.map { $0 + n }
            selectedCells = Set(selectedCells.map { $0 + n }); emphasisCells = Set(emphasisCells.map { $0 + n })
        }
        // A contracted word being typed shows as its cells, at the cursor, until it is translated (as VoiceOver does).
        let typing = BrailleInput.pending
        if !typing.isEmpty, let c = cursorCell {
            let at = min(c, cells.count)
            cells.insert(contentsOf: typing, at: at)
            cellMap.insert(contentsOf: Array(repeating: cursor ?? 0, count: typing.count), at: min(at, cellMap.count))
            cursorCell = at + typing.count
            // The marks under text after the cursor move along with it.
            selectedCells = Set(selectedCells.map { $0 >= at ? $0 + typing.count : $0 })
            emphasisCells = Set(emphasisCells.map { $0 >= at ? $0 + typing.count : $0 })
        }
        windows = windowStarts()
    }

    // MARK: Windows (NVDA: braille.BrailleBuffer's windowStartPos and windowEndPos, with word wrap)

    /// Where each display-width of the line starts. With word wrap, a window that would end inside a word ends at
    /// the last space before it instead (unless the word is longer than the display).
    private static var windows: [Int] = [0]

    private static func windowStarts() -> [Int] {
        let n = display?.cellCount ?? 40
        // Context before the focus: windows of a display's width back from where the focus starts.
        var before: [Int] = []
        var b = min(windowOrigin, cells.count)
        while b > 0 { b = max(0, b - n); before.insert(b, at: 0) }
        var starts: [Int] = before, s = min(windowOrigin, max(cells.count - 1, 0))
        while s < max(cells.count, 1) {
            starts.append(s)
            var e = min(s + n, cells.count)
            if config.braille.wordWrap, e < cells.count, cells[e] & 0x3F != 0, cells[e - 1] & 0x3F != 0,
               let space = (s + 1..<e).last(where: { cells[$0] & 0x3F == 0 }) {
                e = space + 1
            }
            // The next window starts at the next word: blanks at a break are skipped.
            while e < cells.count, cells[e] & 0x3F == 0, config.braille.wordWrap { e += 1 }
            if e <= s { e = s + n }
            s = e
        }
        return starts
    }

    private static func windowEnd(_ start: Int) -> Int {
        let n = display?.cellCount ?? 40
        let next = windows.first { $0 > start } ?? cells.count
        return min(next, start + n)
    }

    /// The window holding a cell.
    private static func window(containing cell: Int) -> Int { windows.last { $0 <= cell } ?? 0 }

    // MARK: Displays

    /// A display came (the driver opened it): show what is current.
    public static func attach(_ driver: BrailleDisplayDriver) {
        display?.close()
        display = driver
        lastWritten = []
        Log.info("braille: \(driver.name), \(driver.cellCount) cells")
        // Every time TurnOver takes the display, including back from VoiceOver at an app switch: over Bluetooth that
        // takes a few seconds, and the sound says when it is ready (6 Oct 2026).
        Tones.brailleConnected()
        refresh()
    }

    public static func detach(_ driver: BrailleDisplayDriver) {
        guard display === driver else { return }
        display = nil
        updateBlink()
        Log.info("braille: \(driver.name) gone")
        // Lost, or let go to VoiceOver: either way the display is no longer TurnOver's.
        Tones.brailleDisconnected()
    }

    // MARK: What is shown

    /// A braille setting changed (in Settings or the menu): shown again with it, the cursor's blink restarted.
    public static func settingsChanged() {
        blinkTimer?.invalidate(); blinkTimer = nil; blinkOn = true
        if autoScroll != nil { startAutoScroll() }   // a new speed from Settings
        lastContext = ""; lastObject = nil   // shown afresh with the new choices
        lastWritten = []
        refreshSoon()
    }

    /// After any script or event: look again, once things settle.
    public static func refreshSoon() {
        guard display != nil else { return }
        pending?.cancel()
        let w = DispatchWorkItem { refresh() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: w)
    }

    /// What TurnOver says by itself (messages, live regions, new output) shows for a while (NVDA: show messages and
    /// message timeout): the chosen seconds for each display's width of it (Preferences, Braille), or until a key.
    /// The panning keys move through it, which keeps it up; any other key puts the display back.
    // MARK: Announcement history (VoiceOver: space with dots 1 3 4 5): the last 30 messages, newest first; up and
    // down move through them, read and shown; the same chord or any other key leaves.

    private static var history: [String] = []
    /// Which of them were private when they came (a two-factor code), so a replay is private too.
    private static var historyPrivate: [Bool] = []
    private static var historyIndex: Int?

    static func toggleHistory() {
        if historyIndex != nil { historyIndex = nil; Speech.speakMessage(String(localized: "announcement history off", comment: "Spoken message")); messageUntil = nil; refresh(); return }
        guard !history.isEmpty else { Speech.speakMessage(String(localized: "no announcements", comment: "Spoken message")); return }
        historyIndex = 0
        showHistory()
    }

    private static func showHistory() {
        guard let i = historyIndex, history.indices.contains(i) else { return }
        let s = history[i]
        let wasPrivate = historyPrivate.indices.contains(i) ? historyPrivate[i] : false
        if wasPrivate { Speech.asPrivate { Speech.speakText(s) } } else { Speech.speakText(s) }
        source = .message
        plain()
        messagePrivate = wasPrivate   // a two-factor code, a copied password: never in the log
        text = displayed(s); cursor = nil; windowStart = 0; selection = nil
        layout()
        messageUntil = .distantFuture
        show()
    }

    /// Text as the display gets it: every line break, control character and object placeholder becomes a blank cell,
    /// one for one, so offsets still match the text's. A table with no cell for them showed its "unknown" sign at the
    /// end of every line (VoiceOver's Slovenian table, reported 20 Oct 2026); U+2028, U+2029 and U+FFFC reached the
    /// translator before.
    public static func displayed(_ s: String) -> String {
        guard s.utf16.contains(where: isBlankOnDisplay) else { return s }
        let units = s.utf16.map { isBlankOnDisplay($0) ? 0x20 : $0 }
        return String(decoding: units, as: UTF16.self)
    }

    private static func isBlankOnDisplay(_ u: UInt16) -> Bool {
        u < 0x20 || (0x7F...0x9F).contains(u) || u == 0x2028 || u == 0x2029 || u == 0xFFFC
    }

    // MARK: Short forms (NVDA: braille.roleLabels and positiveStateLabels)
    //
    // An item's role and states as NVDA shows them on a display: "btn", "chk ( )", "lnk", "h2", "+" for collapsed.
    // Spelt out ("check box, not checked") they took most of a 20-cell display (7 Oct 2026).
    public static let shortForms: [String: String] = [
        "button": "btn", "menu button": "mnubtn", "pop up button": "cbo", "combo box": "cbo", "check box": "chk",
        "radio button": "rbtn", "edit": "edt", "search": "edt", "search field": "edt", "password edit": "pwdedt",
        "link": "lnk", "visited link": "vlnk", "list": "lst", "list view": "lst", "tree view": "tv", "table": "tbl",
        "outline": "tv", "menu": "mnu", "menu bar": "mnubar", "menu item": "", "submenu": "submnu", "tab": "tab",
        "tab control": "tabctl", "tool bar": "tlbr", "dialog": "dlg", "alert": "alrt", "window": "wnd",
        "grouping": "grp", "heading": "h", "slider": "sldr", "spin button": "spnbtn", "progress bar": "prgbar",
        "separator": "-----", "graphic": "gra", "image": "gra", "document": "doc", "text": "", "status bar": "stbar",
        "toggle button": "tgbtn", "disclosure triangle": "dsclsr", "table row": "", "row": "", "cell": "",
        "tree view item": "", "list item": "", "outline row": "", "column": "", "table cell": "",
        "checked": "(x)", "not checked": "( )", "half checked": "(-)", "mixed": "(-)", "expanded": "-",
        "collapsed": "+", "selected": "sel", "pressed": "=]", "unavailable": "unavbl", "dimmed": "unavbl",
        "required": "req", "read only": "ro", "blank": "", "on": "(x)", "off": "( )",
    ]

    /// Speech's parts for an item, as a display shows them: short roles and states, "h2" for "heading level 2",
    /// "lv 2" for "level 2", joined by spaces.
    /// `role`: the item's own role, when the parts are an item's: its word is shortened by the role itself, so two roles
    /// that one language says alike (Turkish "tablo" for table and tree view) keep their own short forms.
    public static func brailleText(_ parts: [String], role: Role? = nil, separator: String = " ") -> String {
        var out: [String] = []
        let roleWord = role.map { $0.displayString.lowercased() }
        for raw in parts {
            let p = raw.trimmingCharacters(in: .whitespaces)
            let k = p.lowercased()
            if let role, k == roleWord, let short = roleShortForms[role] { if !short.isEmpty { out.append(short) }; continue }
            if let short = spokenShortForms[k] { if !short.isEmpty { out.append(short) }; continue }
            if let n = levelNumber(k, Phrases.headingLevel) { out.append("h\(n)"); continue }
            if let n = levelNumber(k, Phrases.level) { out.append("lv \(n)"); continue }
            if !p.isEmpty { out.append(p) }
        }
        return out.joined(separator: separator)
    }

    /// The short forms by role and by state: bound to what the item is, not to the words a language says it with.
    public static let roleShortForms: [Role: String] = [
        .button: "btn", .menuButton: "mnubtn", .popUpButton: "cbo", .comboBox: "cbo", .checkBox: "chk", .radioButton: "rbtn",
        .editableText: "edt", .searchField: "edt", .passwordEdit: "pwdedt", .link: "lnk", .list: "lst", .treeView: "tv",
        .outline: "tv", .table: "tbl", .menu: "mnu", .menuBar: "mnubar", .menuItem: "", .tab: "tab", .tabControl: "tabctl",
        .toolBar: "tlbr", .dialog: "dlg", .window: "wnd", .groupBox: "grp", .heading: "h", .slider: "sldr",
        .spinButton: "spnbtn", .progressBar: "prgbar", .separator: "-----", .graphic: "gra", .image: "gra", .document: "doc",
        .webArea: "doc", .staticText: "", .statusBar: "stbar", .toggleButton: "tgbtn", .disclosureTriangle: "dsclsr",
        .tableRow: "", .tableColumn: "", .tableCell: "", .cell: "", .treeViewItem: "", .listItem: "",
    ]
    public static let stateShortForms: [State: String] = [
        .checked: "(x)", .halfChecked: "(-)", .expanded: "-", .collapsed: "+", .selected: "sel", .pressed: "=]",
        .unavailable: "unavbl", .required: "req", .readOnly: "ro", .on: "(x)", .off: "( )", .hasPopup: "submnu",
    ]

    /// The short forms by the words as speech says them in the reader's language: each role's and state's own word,
    /// over the English ones (kept for words an app says itself, in English). Built in a fixed order, so it is the
    /// same at every launch; a word two different short forms share in a language is left as it is said.
    private static let spokenShortForms: [String: String] = {
        var words = Role.allCases.compactMap { r in roleShortForms[r].map { (r.displayString, $0) } }
        words += State.allCases.compactMap { st in stateShortForms[st].map { (st.displayString, $0) } }
        words += [(State.checked.negativeDisplayString, "( )"), (Phrases.blank, "")]
        return spokenShortForms(base: shortForms, words: words)
    }()
    /// Adds the spoken words to `base`, in their order; a word given two different short forms gets neither.
    public static func spokenShortForms(base: [String: String], words: [(spoken: String, short: String)]) -> [String: String] {
        var out = base, added: [String: String] = [:], ambiguous = Set<String>()
        for (spoken, short) in words {
            let k = spoken.lowercased()
            guard !k.isEmpty, base[k] == nil else { continue }
            if let had = added[k], had != short { ambiguous.insert(k) } else { added[k] = short }
        }
        for (k, short) in added where !ambiguous.contains(k) { out[k] = short }
        return out
    }

    /// The number in "heading level 2" or "level 2", as `phrase` says it in the reader's language.
    private static func levelNumber(_ words: String, _ phrase: (Int) -> String) -> Int? {
        guard let n = words.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).first, phrase(n).lowercased() == words else { return nil }
        return n
    }

    // MARK: TurnOver's own cursor (NVDA: braille tethered to review)
    //
    // Where TurnOver's cursor is on something that isn't the app's focus (WhatsApp's chats and messages, the shelves
    // of Music and the App Store, the TurnOver menu, the VoiceOver cursor on text that can't take the focus), the
    // display shows that item, and keeps showing it until the focus or the caret moves, or the view lets it go.
    // (Before, those items reached the display only as four-second messages, or not at all, and the display fell
    // back to the message box underneath, 7 Oct 2026.)
    private static var heldItem: (text: String, focus: AXUIElement?, caret: Int?)?

    public static func item(_ s: String) {
        // (Commas kept: a message or a chat's name has its own.)
        let t = brailleText(displayed(s).components(separatedBy: ", "), separator: ", ")
        let focus = API.focusObject?.element
        let caret = API.caretObject.flatMap { try? $0.makeTextInfo(.caret) }?.start
        let changed = heldItem?.text != t
        heldItem = (t, focus, caret)
        // A new item replaces a message about the one before (as speech does).
        messageUntil = nil
        if changed { windowStart = 0 }
        refresh()
    }

    /// The view's cursor went back to the app (Escape to the message box, the menu closed).
    public static func releaseItem() {
        guard heldItem != nil else { return }
        heldItem = nil
        refreshSoon()
    }

    private static func heldItemStillCurrent() -> Bool {
        guard let h = heldItem else { return false }
        let focus = API.focusObject?.element
        let sameFocus: Bool = { switch (h.focus, focus) { case (nil, nil): return true; case let (a?, b?): return CFEqual(a, b); default: return false } }()
        let caret = API.caretObject.flatMap { try? $0.makeTextInfo(.caret) }?.start
        if sameFocus, caret == h.caret { return true }
        heldItem = nil
        return false
    }

    /// The focus or the caret moved (NVDA dismisses a message then): a message up for a moment already gives way.
    public static func focusOrCaretMoved() {
        if let shownAt = messageShownAt, Date().timeIntervalSince(shownAt) > 0.5, messageUntil != nil, historyIndex == nil {
            messageUntil = nil
        }
    }
    private static var messageShownAt: Date?

    private static var messagePrivate = false
    public static func message(_ s: String) {
        if !s.isEmpty, history.first != s {
            history.insert(s, at: 0); historyPrivate.insert(Speech.isPrivateNow, at: 0)
            if history.count > 30 { history.removeLast(); historyPrivate.removeLast() }
        }
        guard historyIndex == nil else { return }
        guard let d = display, !s.isEmpty, config.braille.showMessages != "off" else { return }
        source = .message
        plain()
        text = displayed(s); cursor = nil; windowStart = 0; selection = nil
        layout()
        let widths = Double((cells.count + d.cellCount - 1) / max(d.cellCount, 1))
        holdMessage(min(300, Double(max(1, config.braille.messageSeconds)) * max(1, widths)))
        messageShownAt = Date()
        show()
    }

    private static func holdMessage(_ seconds: Double) {
        // Shown until a key: a date that never comes.
        if config.braille.showMessages == "indefinitely" { messageUntil = .distantFuture; return }
        let until = Date().addingTimeInterval(seconds)
        messageUntil = until
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) {
            if let u = messageUntil, u == until, Date() >= u { messageUntil = nil; refresh() }
        }
    }

    static func refresh() {
        guard display != nil else { return }
        if let until = messageUntil, Date() < until { return }
        messageUntil = nil
        plain()
        if let m = modalLine?() {
            let changed = !modalShowing || text != displayed(m.0)
            source = .message; modalShowing = true
            text = displayed(m.0); cursor = m.1; selection = nil
            layout()
            if changed { windowStart = 0 }
            if let c = cursorCell, c < windowStart || c >= windowEnd(windowStart) { windowStart = window(containing: c) }
            if !windows.contains(windowStart) { windowStart = window(containing: windowStart) }
            show()
            return
        }
        modalShowing = false
        // NVDA's "display speech output": the display shows what was last spoken.
        if config.braille.mode == "speechOutput" {
            let said = Speech.lastSpoken
            let fresh = text != displayed(said)
            source = .message; text = displayed(said); cursor = nil; selection = nil
            layout()
            if fresh { windowStart = 0 }
            if !windows.contains(windowStart) { windowStart = window(containing: windowStart) }
            show()
            return
        }
        // Tethered to focus: TurnOver's own cursor isn't shown (NVDA's "tether to focus").
        if config.braille.tether != "focus", heldItemStillCurrent(), let h = heldItem {
            let fresh: Bool = { if case .item = source { return text != h.text }; return true }()
            source = .item
            text = h.text; cursor = nil; selection = nil
            if fresh { windowStart = 0 }
            layout()
            if !windows.contains(windowStart) { windowStart = window(containing: windowStart) }
            show()
            return
        }
        let oldLine: Int? = { if case .text(_, let s) = source { return s }; return nil }()
        // Tethered to review: the review cursor's line (NVDA's "tether to review"); else the caret's.
        let reviewed = config.braille.tether == "review" ? TextReview.current() : nil
        if let caret = reviewed ?? API.caretObject.flatMap({ hasText($0) ? try? $0.makeTextInfo(.caret) : nil }) {
            // Panned on with "Panning moves the cursor" off: the line reached, until the caret moves.
            var shown = caret
            if reviewed == nil, let h = heldLine {
                if h.caret == caret.start, h.info.obj.isSameElement(as: caret.obj) { shown = h.info.copy() } else { heldLine = nil }
            }
            let byParagraph = config.braille.readByParagraph
            let line = shown.copy(); line.expand(byParagraph ? .paragraph : .line)
            source = .text(line, lineStart: line.start)
            text = displayed(line.text)
            // Read by paragraph, a paragraph's start can be marked (NVDA's paragraph start marker).
            if byParagraph { leadingCells = ["pilcrow": BrailleOutput.translate("¶", cursor: nil).cells + [0], "spaces": [0, 0]][config.braille.paragraphMarker] ?? [] }
            // Bold, italic and underline, for the table's signs or dots 7 and 8 (asked of the app only when shown).
            if config.braille.formattingMarks != "off" { emphasis = line.emphasisRuns() }
            cursorIsReview = reviewed != nil
            let caretHere = caret.start >= line.start && caret.start <= line.end
            cursor = caretHere ? caret.start - line.start : nil
            selection = caretHere ? caret.selectionOffsets().map { ($0.0 - line.start, $0.1 - line.start) } : nil
            layout()
            // The window follows the caret only when the caret moves (or typing grows the word): panning leaves the
            // caret behind on purpose, and an unrelated refresh must not pull the window back to it.
            if oldLine != line.start || caret.start != lastCaret || !BrailleInput.pending.isEmpty {
                if oldLine != line.start { windowStart = 0 }
                if let c = cursorCell, c < windowStart || c >= windowEnd(windowStart) { windowStart = window(containing: c) }
            }
            if !windows.contains(windowStart) { windowStart = window(containing: windowStart) }
            lastCaret = caret.start
        } else if let focus = API.focusObject {
            // A list, table or outline: its selected item, as speech reads it (Mail's list showed only "message
            // table", 6 Oct 2026).
            let row = selectedItem(in: focus)
            let obj = row ?? focus
            // The same item as last time, even with a message shown in between: kept as it was.
            let sameItem = lastObject.map { obj.isSameElement(as: $0) } ?? false
            lastObject = obj.element
            source = .object(obj)
            let own = brailleText(Speech.objectPropertiesSpeech(obj, reason: .focus), role: obj.role)
            // NVDA's focus context presentation: what the focus is in (window, list, group) before it, the display
            // starting so the focus is in view; panning back reads the context. Worked out once per focus: asking
            // every ancestor's name at each refresh cost tens of messages to the app, and the display jumped from
            // the context to the focus at the next refresh (a review, 14 Nov 2026).
            let context: String, contextChanged: Bool
            if sameItem { context = lastContext; contextChanged = false }
            else {
                context = focusContext(row == nil ? API.focusAncestors : API.focusAncestors + [focus])
                contextChanged = context != lastContext
                lastContext = context
            }
            text = context.isEmpty ? own : context + " " + own
            cursor = nil; selection = nil
            if sameItem { windowOrigin = lastOrigin }
            else if !context.isEmpty {
                // The origin needs the cells: laid out once to find where the focus starts in them.
                layout()
                let ownStart = (context as NSString).length + 1
                let ownCell = cellMap.firstIndex { $0 >= ownStart } ?? 0
                let n = display?.cellCount ?? 40
                let fill = config.braille.focusContext == "always" || (config.braille.focusContext == "changes" && contextChanged)
                windowOrigin = fill ? min(ownCell, max(0, cells.count - n)) : ownCell
            }
            lastOrigin = windowOrigin
            layout()
            // The same item again (its value changed, another event): the window stays where the reader panned to.
            windowStart = sameItem && windows.contains(objectWindowStart) ? objectWindowStart : windowOrigin
        } else {
            source = nil; text = ""; cursor = nil; selection = nil; windowStart = 0
            layout()
        }
        show()
    }

    /// The context last shown before a focus, to tell when it changes.
    private static var lastContext = ""
    private static var lastOrigin = 0
    /// The item last shown, and where its window was (panned to, or placed).
    private static var lastObject: AXUIElement?
    private static var objectWindowStart = 0

    /// The focus's ancestors as the display shows them, outermost first: those with a name, or a role worth knowing
    /// (a list, a table, a dialog), the four nearest the focus.
    private static func focusContext(_ ancestors: [TurnOverObject]) -> String {
        let worth: Set<Role> = [.list, .table, .treeView, .outline, .toolBar, .dialog, .menu, .menuBar, .tabControl, .groupBox, .window]
        var parts: [String] = []
        for a in ancestors where a.role != .application {
            let name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || worth.contains(a.role) else { continue }
            let s = brailleText([name, a.role.displayString], role: a.role).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, parts.last != s { parts.append(s) }
        }
        return parts.suffix(4).joined(separator: " ")
    }

    private static func selectedItem(in obj: TurnOverObject) -> TurnOverObject? {
        guard [.table, .list, .treeView].contains(obj.role) || ["AXTable", "AXOutline", "AXList", "AXBrowser"].contains(obj.axRole) else { return nil }
        for key in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] {
            if let row = obj.element.elements(key).first { return ObjectFactory.make(row) }
        }
        return nil
    }

    private static func hasText(_ obj: TurnOverObject) -> Bool {
        if let d = API.focusTreeInterceptor, !d.passThrough { return true }   // browse mode: caretObject is its document
        // (Word's page doesn't say it is editable: the display showed "doc" while you typed, 7 Oct 2026.)
        return obj.states.contains(.editable) || obj.role == .terminal || (obj.role == .document && obj.hasNavigableText)
    }

    /// The cursor's dots (NVDA: cursor shape), and whether the blink has it showing now.
    private static var cursorDots: UInt8 { ["8": 0x80, "7": 0x40, "78": 0xC0, "all": 0xFF][cursorIsReview ? config.braille.cursorShapeReview : config.braille.cursorShape] ?? 0xC0 }
    private static var blinkOn = true
    private static var blinkTimer: Timer?

    private static func show() {
        guard let d = display else { return }
        let n = d.cellCount
        var cells = Self.cells
        for i in selectedCells where i < cells.count { cells[i] |= 0xC0 }
        for i in emphasisCells where i < cells.count { cells[i] |= 0xC0 }
        if let c = cursorCell, config.braille.showCursor, blinkOn || !config.braille.blinkCursor {
            while cells.count <= c { cells.append(0) }
            cells[c] |= cursorDots
        }
        let start = min(windowStart, max(0, cells.count - 1))
        // The cursor cell past the last character (the end of a line) belongs to the last window.
        var end = windowEnd(start)
        if let c = cursorCell, c == Self.cells.count, end == Self.cells.count { end += 1 }
        var window = Array(cells[min(start, cells.count)..<min(end, cells.count)])
        while window.count < n { window.append(0) }
        updateBlink()
        guard window != lastWritten else { return }
        // What the display shows, for testing: the kind, and the text of this window of the line.
        if lastLoggedText != text || lastLoggedStart != start {
            lastLoggedText = text; lastLoggedStart = start
            let kind: String = { switch source { case .text: return "line"; case .object: return "object"; case .message: return messageUntil != nil ? "message" : "view"; case .item: return "cursor item"; case nil: return "nothing" } }()
            let a = start < cellMap.count ? cellMap[start] : 0
            let b = windowEnd(start) < cellMap.count ? cellMap[windowEnd(start)] : (text as NSString).length
            let shown = (text as NSString).substring(with: NSRange(location: min(a, (text as NSString).length), length: max(0, min(b, (text as NSString).length) - min(a, (text as NSString).length))))
            if case .message = source, messagePrivate { Log.io("braille shows (\(kind)): (private, \(shown.count) cells)") }
            else if Speech.logsWords {
                // The dots themselves, as the display has them (the cursor's and selection's dots too), so a table's
                // output can be checked against what it should be, not only what it was made from (a tester, 12 Nov 2026).
                var dots = window; while dots.last == 0 { dots.removeLast() }
                let pattern = String(String.UnicodeScalarView(dots.compactMap { UnicodeScalar(0x2800 + UInt32($0)) }))
                Log.io("braille shows (\(kind)\(messageUntil != nil ? ", held" : "")): \(shown) ⟦\(pattern)⟧")
            }
            else { Log.io("braille shows (\(kind)\(messageUntil != nil ? ", held" : "")): [\(shown.count) cells]") }
        }
        if case .object = source { objectWindowStart = start }
        lastWritten = window
        d.write(window)
    }

    /// The cursor blinks while it is in view (NVDA: cursor blink rate).
    private static func updateBlink() {
        let wanted = display != nil && config.braille.blinkCursor && config.braille.showCursor && cursorCell != nil && messageUntil == nil
        if wanted, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: Double(max(100, config.braille.blinkRateMs)) / 1000, repeats: true) { _ in
                MainActor.assumeIsolated { blinkOn.toggle(); show() }
            }
        } else if !wanted, let t = blinkTimer {
            t.invalidate(); blinkTimer = nil; blinkOn = true
        }
    }

    // MARK: Keys

    // BAUM can send unsupported mixed chords such as dot keys with an extra thumb key. Those names contain
    // typed cells too: redact diagnostics while keeping the original identifier for dispatch (#62, 28 Oct 2026).
    package static func diagnosticKeyName(_ name: String) -> String {
        name.split(separator: "+").contains { $0.hasPrefix("dot") } ? "(a braille input chord)" : name
    }

    /// From the driver, on the main thread.
    public static func handle(_ key: BrailleKey) {
        guard display != nil else { return }
        let loggedKey: BrailleKey
        if case .key(let name) = key { loggedKey = .key(diagnosticKeyName(name)) } else { loggedKey = key }
        Log.io("braille key \(loggedKey)")
        // Input help (TurnOver 1): the key says what it does instead of doing it.
        if InputManager.isInputHelpActive { Speech.cancel(); BrailleHelp.explain(BrailleHelp.describe(key)); return }
        // A display key stops speech as a keyboard key does (NVDA: every gesture cancels speech first); the
        // joystick moved on while the last item was still being read (6 Oct 2026).
        // Panning keeps speech going if "Stop speech while panning" is off.
        let panning: Bool = { if case .key(let n) = key { return ["scrollBack", "scrollForward"].contains(keyMap[n] ?? "") }; return false }()
        if !panning || config.braille.interruptSpeechWhileScrolling {
            Speech.cancel()
            SayAll.stop(byGesture: true)
        }
        BrailleInput.flush()
        // The TurnOver menu open: the display's keys drive it, not the application behind (the joystick moved through
        // Mail's list while the menu was up, 6 Oct 2026). Panning still reads along a long item.
        if TurnOverMenu.shared.isOpen {
            let key: String? = {
                switch key {
                case .routing: return "enter"
                case .key(let name):
                    switch keyMap[name] {
                    case "previousLine": return "upArrow"
                    case "nextLine": return "downArrow"
                    case "activate": return "enter"
                    case "scrollBack", "scrollForward":
                        let next = keyMap[name] == "scrollForward" ? windows.first { $0 > windowStart } : windows.last { $0 < windowStart }
                        if let next { windowStart = next; show(); holdMessage(Double(max(1, config.braille.messageSeconds)) + 2); return nil }
                        return keyMap[name] == "scrollForward" ? "rightArrow" : "leftArrow"
                    default: return nil
                    }
                }
            }()
            if let key, let g = KeyboardGesture(identifier: "kb:\(key)") { TurnOverMenu.shared.handle(g) }
            return
        }
        // Screen recognition's result open: the display's keys move through it.
        if let mk = modalKey, modalShowing {
            switch key {
            case .routing(let i):
                let cell = windowStart + i
                mk("route:\(cell < cellMap.count ? cellMap[cell] : (text as NSString).length)")
            case .key(let name):
                switch keyMap[name] {
                case "previousLine": mk("upArrow")
                case "nextLine": mk("downArrow")
                case "activate": mk("enter")
                case "scrollBack", "scrollForward":
                    let fwd = keyMap[name] == "scrollForward"
                    if let next = fwd ? windows.first(where: { $0 > windowStart }) : windows.last(where: { $0 < windowStart }) { windowStart = next; show() }
                    else { mk(fwd ? "downArrow" : "upArrow") }
                default: break
                }
            }
            return
        }
        // In the announcement history: up and down move through it, panning reads along; anything else leaves.
        if historyIndex != nil, case .key(let name) = key {
            switch keyMap[name] {
            case "previousLine": historyIndex = min(history.count - 1, historyIndex! + 1); showHistory(); return
            case "nextLine": historyIndex = max(0, historyIndex! - 1); showHistory(); return
            case "scrollBack", "scrollForward": break
            default: historyIndex = nil; messageUntil = nil; refresh()
            }
        }
        // A message showing: panning reads on through it; any other key puts the display back.
        if messageUntil != nil {
            if case .key(let name) = key, let action = keyMap[name], action == "scrollBack" || action == "scrollForward" {
                let next = action == "scrollForward" ? windows.first { $0 > windowStart } : windows.last { $0 < windowStart }
                if let next { windowStart = next; show(); holdMessage(Double(max(1, config.braille.messageSeconds)) + 2) } else { Tones.edge() }
                return
            }
            messageUntil = nil; refresh(); return
        }
        switch key {
        case .routing(let i):
            route(to: windowStart + i)
        case .key(let name):
            switch keyMap[name] {
            case "scrollBack": pan(forward: false)
            case "scrollForward": pan(forward: true)
            case "previousLine": line(-1)
            case "nextLine": line(1)
            case "activate": activate()
            default:
                // VoiceOver's other display commands (Escape, the Dock, first item…): as its space-with-dots chord for
                // the same command does (BrailleCommands), so every key a display's table names does what it says.
                if let dots = voCommandChords[name] { _ = BrailleCommands.run(BrailleCommands.dots(dots)) }
                else if let run = voCommandActions[name] { run() }
                else { Log.io("braille: no command for \(diagnosticKeyName(name))") }
            }
        }
    }

    /// The display's own key names, for the shortcuts list.
    static func displayKeyNames() -> [String]? {
        if let a = display as? AppleBrailleDriver { return Array(Set(a.display.keyCommands.values)).sorted() }
        return ["d1", "d2", "d3", "d5", "joystickUp", "joystickDown", "joystickLeft", "joystickRight", "joystickPress"]
    }

    /// NVDA's BAUM gestures: d2 and d5 pan, d1 and d3 go up and down a line. Unbound keys are logged by name, so the
    /// rest can be mapped from a tester's log.
    static var keyMap: [String: String] = [
        // VoiceOver's commands, from Apple's key table for each display model.
        "SCRBraille.panLeft": "scrollBack", "SCRBraille.panRight": "scrollForward",
        "Global.interactUp": "previousLine", "Global.interactDown": "nextLine",
        "Global.interactLeft": "scrollBack", "Global.interactRight": "scrollForward",
        "Global.defaultAction": "activate",
        // TurnOver's own BAUM driver.
        "d2": "scrollBack", "d5": "scrollForward", "d1": "previousLine", "d3": "nextLine",
        "joystickLeft": "scrollBack", "joystickRight": "scrollForward", "joystickUp": "previousLine", "joystickDown": "nextLine",
        "joystickPress": "activate",
    ]

    /// VoiceOver's display commands (from Apple's key tables for every model, read 14 Nov 2026) that one of its
    /// space-with-dots chords also does, by the chord's dots.
    static let voCommandChords: [String: String] = [
        "Global.interactUpShift": "356", "Global.interactDownShift": "236",
        "SCRWorkspace.escapeKey": "12", "SCRWorkspace.menubar": "234", "Global.contextualMenu": "25",
        "Global.moveToFirstElement": "123", "Global.moveToLastElement": "456",
        "Global.moveToFirstVisibleElement": "123", "Global.moveToLastVisibleElement": "456",
        "Global.interactHomeCommand": "123", "Global.interactEndCommand": "456",
        "Global.interactUpCommand": "123", "Global.interactDownCommand": "456",
        "Global.interactUpCommandShift": "123", "Global.interactDownCommandShift": "456",
        "SCRBraille.announcementsOn": "1345", "Braille.announcementsOn": "1345",
        "Global.showRotor": "23", "Global.elementListMenu": "24", "Global.findText": "124",
        "SCRWorkspace.tabKey": "2345", "SCRWorkspace.deleteKey": "145",
        "SCRBraille.panPageUp": "3456", "SCRBraille.panPageDown": "1456",
        "Global.scrollUpByPage": "3456", "Global.scrollDownByPage": "1456",
        "VOTEventCommandScrollUpPage": "3456", "VOTEventCommandScrollDownPage": "1456",
        "VOTEventCommandPreviousElement": "1", "VOTEventCommandNextElement": "4",
        "Global.rightClickMouse": "25",
    ]
    /// The chords above that BrailleCommands has no command for (none, unless one is mistyped), for the tests.
    package static func unmappedVoCommandChords() -> [String] {
        voCommandChords.filter { (_, d) in !BrailleCommands.table.contains { $0.0 == BrailleCommands.dots(d) } }.map(\.key).sorted()
    }
    /// The rest, done directly.
    static let voCommandActions: [String: () -> Void] = [
        "SCRWorkspace.cancelSpeaking": { Speech.cancel() },
        "SCRWorkspace.dock": { runScript("focusDock") },
        "SCRWorkspace.desktop": { runScript("desktop") },
        "SCRApplication.focusedElementOverview": { runScript("reportCurrentFocus") },
        "Global.synchToKeyboardFocus": { runScript("reviewToFocus") },
        "Global.imageDescription": { runScript("describeImage") },
        "Global.clickMouse": { activate() },
        "SCRWorkspace.upArrowKey": { BrailleCommands.press("upArrow") }, "SCRWorkspace.downArrowKey": { BrailleCommands.press("downArrow") },
        "SCRWorkspace.leftArrowKey": { BrailleCommands.press("leftArrow") }, "SCRWorkspace.rightArrowKey": { BrailleCommands.press("rightArrow") },
        "SCRWorkspace.forwardDeleteKey": { BrailleCommands.press("forwardDelete") },
        "SCRBraille.toggleContractions": { toggleContracted() },
        "VOTEventCommandBraillePanLeft": { pan(forward: false) }, "VOTEventCommandBraillePanRight": { pan(forward: true) },
    ]

    /// One of TurnOver's commands by its script name, whatever the keyboard style.
    private static func runScript(_ name: String) {
        guard let s = ScriptHandler.findScript(named: name), let g = KeyboardGesture(identifier: "kb:turnover+f12") else { Tones.edge(); return }
        s.handler(g)
    }

    /// VoiceOver's contracted braille key: the output table between its contracted and uncontracted forms.
    public static func toggleContracted() {
        guard let id = BrailleOutput.tableIdentifier else { Tones.edge(); return }
        let other: String? = id.hasSuffix("_g2") ? String(id.dropLast(3)) + "_g1" : id.hasSuffix("_g1") ? String(id.dropLast(3)) + "_g2" : nil
        guard let other, TOBrailleTranslatorTablesCheck.exists(other) else { Tones.edge(); Speech.speakMessage(String(localized: "this table has no contracted form", comment: "Spoken message")); return }
        config.braille.table = other; config.save()
        Speech.speakMessage(other.hasSuffix("_g2") ? String(localized: "contracted braille", comment: "Spoken message") : String(localized: "uncontracted braille", comment: "Spoken message"))
        settingsChanged()
    }

    // MARK: NVDA's braille keys (the parity audit, 13 Oct 2026)

    /// NVDA+Control+T.
    public static func cycleTether() {
        let order = ["auto", "focus", "review"]
        let names = [String(localized: "braille tethered automatically", comment: "What braille follows"), String(localized: "braille tethered to focus", comment: "What braille follows"),
                     String(localized: "braille tethered to review", comment: "What braille follows")]
        let i = ((order.firstIndex(of: config.braille.tether) ?? 0) + 1) % order.count
        config.braille.tether = order[i]; config.save()
        Speech.speakMessage(names[i])
        refresh()
    }
    /// NVDA+Alt+T.
    public static func cycleMode() {
        config.braille.mode = config.braille.mode == "speechOutput" ? "followCursors" : "speechOutput"; config.save()
        Speech.speakMessage(config.braille.mode == "speechOutput" ? String(localized: "braille mode display speech output", comment: "NVDA's braille modes") : String(localized: "braille mode follow cursors", comment: "NVDA's braille modes"))
        refresh()
    }
    private static var autoScroll: Timer?
    /// NVDA+Alt+K: on to the next window by itself every few seconds; NVDA+Alt+L and J faster and slower.
    public static func toggleAutoScroll() {
        if let t = autoScroll { t.invalidate(); autoScroll = nil; Speech.speakMessage(String(localized: "auto scroll off", comment: "Spoken message")); return }
        guard display != nil else { Speech.speakMessage(String(localized: "no braille display", comment: "Spoken message")); return }
        startAutoScroll()
        Speech.speakMessage(String(localized: "auto scroll on", comment: "Spoken message"))
    }
    private static func startAutoScroll() {
        autoScroll?.invalidate()
        autoScroll = Timer.scheduledTimer(withTimeInterval: config.braille.autoScrollSeconds, repeats: true) { _ in
            MainActor.assumeIsolated { if display != nil { pan(forward: true) } else { autoScroll?.invalidate(); autoScroll = nil } }
        }
    }
    public static func autoScrollRate(faster: Bool) {
        config.braille.autoScrollSeconds = max(0.5, min(20, config.braille.autoScrollSeconds + (faster ? -0.5 : 0.5))); config.save()
        if autoScroll != nil { startAutoScroll() }
        Speech.speakMessage(String(localized: "\(String(format: "%.1f", config.braille.autoScrollSeconds)) seconds", comment: "Braille auto scroll's speed: %@ is seconds"))
    }

    private static func pan(forward: Bool) {
        if config.braille.interruptSpeechWhileScrolling { Speech.cancel() }
        if let next = forward ? windows.first(where: { $0 > windowStart }) : windows.last(where: { $0 < windowStart }) {
            windowStart = next; show(); caretToWindow(); return
        }
        // Off the end of the line: on to the next or previous line (NVDA's scrollForward and scrollBack). On an item,
        // panning stays on it (up and down move between items).
        guard case .text = source else { Tones.edge(); return }
        line(forward ? 1 : -1, toEnd: !forward)
    }

    /// The keyboard key a display key stands for, run as if pressed: TurnOver's own script for it, or the app's.
    private static func press(_ key: String) {
        guard let g = KeyboardGesture(identifier: "kb:\(key)") else { return }
        if let s = ScriptHandler.findScript(for: g) { ScriptHandler.executeScript(s, gesture: g) } else { g.send() }
    }

    /// Move the caret a line, and say it. On an item rather than
    /// text (Mail's message list, a menu), up and down move to the previous or next item, as VoiceOver's do.
    private static func line(_ direction: Int, toEnd: Bool = false) {
        guard case .text(let info, _) = source else { press(direction > 0 ? "downArrow" : "upArrow"); return }
        let r = info.copy()
        r.collapse()
        let unit: TextUnit = config.braille.readByParagraph ? .paragraph : .line
        guard r.move(unit, direction) != 0 else { Tones.edge(); return }
        // The caret follows the display (Panning moves the cursor), so the arrows carry on from the line read on the
        // display, not from where reading began (VoiceOver left the caret behind: a tester, 21 Oct 2026).
        switch panFollow(setting: config.braille.panMovesCaret, tether: config.braille.tether) {
        case .review: TextReview.set(r)
        case .caret: r.updateCaret(); heldLine = nil
        case .hold: if let c = API.caretObject.flatMap({ try? $0.makeTextInfo(.caret) })?.start { heldLine = (r.copy(), c) }
        }
        // The line is spoken as well as shown, as VoiceOver does (the display moved on silently, 6 Oct 2026).
        SayAll.stop()
        Speech.cancel()
        let spoken = r.copy(); spoken.expand(unit)
        Speech.speakTextInfo(spoken, unit: unit, reason: .caret)
        refresh()
        if toEnd { windowStart = windows.last ?? 0; show(); caretToWindow() }
    }

    /// The line reached by panning with "Panning moves the cursor" off, and the caret then: shown until the caret moves.
    private static var heldLine: (info: TextInfo, caret: Int)?

    /// What panning on to another line moves. Tethered to review, the review cursor only, as NVDA's braille does, and
    /// the caret stays where it is; otherwise the caret, unless "Panning moves the cursor" is off, when the display
    /// holds the line reached until the caret moves.
    public enum PanFollow: Equatable { case review, caret, hold }
    public static func panFollow(setting: String, tether: String) -> PanFollow {
        if tether == "review" { return .review }
        return setting == "off" ? .hold : .caret
    }

    /// "Panning moves the cursor" set to the text shown: the caret goes to the start of each display's width of the
    /// line as it is panned to, so the arrows and typing carry on from exactly what was read.
    private static func caretToWindow() {
        guard config.braille.panMovesCaret == "window", case .text(let info, let lineStart) = source,
              windowStart < cellMap.count else { return }
        let r = info.copy()
        r.start = lineStart + cellMap[windowStart]; r.end = r.start
        if panFollow(setting: config.braille.panMovesCaret, tether: config.braille.tether) == .review { TextReview.set(r) } else { r.updateCaret() }
    }

    private static func onActionable(_ e: AXUIElement?) -> Bool {
        var x = e; var hops = 0
        while let y = x, hops < 3 {
            if ["AXLink", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton"].contains(y.role) { return true }
            if y.role == "AXWebArea" { return false }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    /// The display's action key: Enter on a link or button in browse mode, else press the focused item.
    private static func activate() {
        if let d = API.focusTreeInterceptor, !d.passThrough, let s = ScriptHandler.findScript(named: "activatePosition") {
            s.handler(KeyboardGesture(keyCode: 36, modifiers: [], characters: "\r", timestamp: 0, isRepeat: false, flags: []))
        } else if let f = API.focusObject {
            _ = AXUIElementPerformAction(f.element, kAXPressAction as CFString)
        }
        refreshSoon()
    }

    /// A routing key: in text, put the caret on the character (and in browse mode, activate what is there, as
    /// NVDA does); on an object, press it.
    private static func route(to cell: Int) {
        switch source {
        case .text(let info, let lineStart):
            let r = info.copy()
            let offset = cell < cellMap.count ? cellMap[cell] : (text as NSString).length
            r.start = lineStart + offset; r.end = r.start
            // Tethered to review, the review cursor goes there; the caret too only if wanted (NVDA's "move system
            // caret when routing review cursor", never by default).
            if cursorIsReview {
                TextReview.set(r)
                if config.braille.routingMovesCaret == "always" { r.updateCaret() }
            } else { r.updateCaret() }
            // The character routed to is said (NVDA's "speak character when routing cursor in text").
            if config.braille.speakOnRouting {
                let c = r.copy(); c.expand(.character)
                Speech.cancel()
                Speech.speakTextInfo(c, unit: .character, reason: .caret)
            }
            // Only on a link or button: plain text has nothing to press, and saying so at every routing key would wear.
            if let d = API.focusTreeInterceptor, !d.passThrough, let b = r as? BufferTextInfo, onActionable(b.element(at: r.start)),
               let s = ScriptHandler.findScript(named: "activatePosition") {
                _ = d
                s.handler(KeyboardGesture(keyCode: 36, modifiers: [], characters: "\r", timestamp: 0, isRepeat: false, flags: []))
            }
            refresh()
        case .object(let obj):
            _ = AXUIElementPerformAction(obj.element, kAXPressAction as CFString)
        case .item:
            // TurnOver's cursor item: a routing key opens or presses it, as Return does.
            press("enter")
        default:
            break
        }
    }
}
