// SPDX-License-Identifier: GPL-3.0-or-later
// Chat apps (Messages, WhatsApp, 7 Oct 2026): one model of a chat window, with a small description per app.
// A chat window is three parts: the conversations, the messages of the open one, and the box to type in. The keyboard
// lives in the box; the other two are TurnOver's to move through (as Finder's sidebar), so typing is never disturbed.
//
// Measured 7 Oct 2026 (macOS 27):
// - Messages: the conversations are AXStaticTexts in "ConversationList" (description: name, preview, time); the
//   messages are AXGroups in "TranscriptCollectionView" (description: sender, text, time), with nameless groups between
//   for the time stamps; the box is the AXTextField "messageBodyField". Each item has its own actions (reply, tapback,
//   copy, pin, mark as read…), as custom actions.
// - WhatsApp: the chats are AXButtons in "ChatListView_TableView" (description: name; value: preview); the messages are
//   AXStaticTexts "WAMessageBubbleTableViewCell" in "ChatMessagesTableView" (description: text, time, status), with
//   AXHeadings for the days; the box is the AXTextArea "ChatBar_ComposerTextView".
// - Both keep only the messages near the screen: older ones come as the list scrolls up.
//
// Keys (the app module's): in the box, Tab goes to the messages (on the newest) and Shift Tab to the conversations;
// there, Up and Down move, Home and End go to the ends, Return opens a conversation, the shortcut menu (VO Shift M,
// Shift F10, the Applications key) lists the item's actions, and Tab, Shift Tab or Escape move on or go back to the
// box. TurnOver Command 1 to 9 read the latest messages (1 the newest) from anywhere in the window. New messages that arrive
// in the open conversation are read as they come.
import Foundation
import AppKit
import ApplicationServices

public final class ChatView {
    /// What tells one chat app's parts apart.
    public struct Spec {
        public var conversationsID: String
        public var transcriptID: String
        public var composerID: String
        /// The open conversation's title (Messages "ConversationTitle", WhatsApp "NavigationBar_HeaderViewButton"):
        /// when it changes, the messages shown are not new ones.
        public var titleID: String
        /// A bar of sections beside the conversations (WhatsApp's Chats, Updates, Communities, Calls, Archived,
        /// Starred: AXStaticTexts "SidebarButton_…" that can be pressed but never take the keyboard). Nil: none.
        public var sectionsPrefix: String? = nil
        /// The app's own search field (WhatsApp's "TokenizedSearchBar_TextView"): Tab and Down go to its results.
        public var searchFieldID: String? = nil
        /// The start of the identifiers of its search results (WhatsApp's "ChatListSearchView_"). While they show, they
        /// are the conversations: the usual list stays in the tree beneath them.
        public var resultsPrefix: String? = nil
        /// The app says "Message Sent" itself (WhatsApp); otherwise TurnOver says "sent".
        public var saysSent = false
        /// Parts found by a match rather than by identifier (a web page's chat: Discord), keyed by the part's id string.
        /// Empty for Messages and WhatsApp, whose parts are found by identifier exactly as before.
        public var partMatch: [String: (AXUIElement) -> Bool] = [:]
        /// A child of the transcript that is a message (or a day heading) worth reading.
        public var isMessage: (AXUIElement) -> Bool
        /// A child of the conversation list that is a conversation.
        public var isConversation: (AXUIElement) -> Bool
        public init(conversationsID: String, transcriptID: String, composerID: String, titleID: String,
                    isMessage: @escaping (AXUIElement) -> Bool, isConversation: @escaping (AXUIElement) -> Bool) {
            self.conversationsID = conversationsID; self.transcriptID = transcriptID; self.composerID = composerID; self.titleID = titleID
            self.isMessage = isMessage; self.isConversation = isConversation
        }
    }

    /// `control`: a button TurnOver holds, in the toolbar or beside the message box.
    public enum Pane { case composer, transcript, conversations, sections, control }

    public let pid: pid_t
    public let spec: Spec
    public private(set) var pane: Pane = .composer
    private var index: [Pane: Int] = [:]
    private var items: [AXUIElement] = []

    public init(pid: pid_t, spec: Spec) { self.pid = pid; self.spec = spec }

    // MARK: Finding the parts

    private var windowCache: (w: AXUIElement?, at: Date) = (nil, .distantPast)
    private var window: AXUIElement? {
        // Half a second's cache: a dozen scripts share each key and every one asked the app for its window first
        // (a code review, 14 Oct 2026).
        if Date().timeIntervalSince(windowCache.at) < 0.5 { return windowCache.w }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let w = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute)
        windowCache = (w, Date())
        return w
    }

    /// A sheet is up (WhatsApp's Settings): the window's own keys and TurnOver's usual ones work there, not the chat's.
    public var inSheet: Bool {
        // Or a page's own dialog over the chat (Discord's What's New: Tab said "no conversations", 12 Nov 2026).
        if let f = API.focusObject, f.pid == pid, BrowseModeDocument.inWebDialog(f.element) { return true }
        guard let w = window else { return false }
        return w.role == "AXSheet" || w.string(kAXSubroleAttribute) == "AXDialog"
    }

    /// The open conversation's name (the title's description: WhatsApp keeps who is in it in the value).
    public func openTitle() -> String? {
        guard let t = find(spec.titleID) else { return nil }
        let d = (t.string(kAXDescriptionAttribute) ?? t.string(kAXTitleAttribute) ?? "").replacingOccurrences(of: "\u{200E}", with: "")
        return d.isEmpty ? nil : d
    }

    /// The title of the page showing in a sheet: the heading in its navigation bar ("WDSNavigationBar").
    public func sheetTitle() -> String? { inSheet ? pageTitle() : nil }

    /// The heading of the first navigation bar ("WDSNavigationBar") in the window: WhatsApp's section ("Calls") or
    /// a sheet's page.
    public func pageTitle() -> String? {
        guard let w = window else { return nil }
        var stack = [w], visited = 0
        while let e = stack.popLast(), visited < 400 {
            visited += 1
            if e.string(kAXIdentifierAttribute) == "WDSNavigationBar" {
                for k in e.elements(kAXChildrenAttribute) where k.role == "AXHeading" {
                    let t = Self.words(k)
                    if !t.isEmpty { return t }
                }
            }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        return nil
    }

    /// Escape in a sheet (WhatsApp's Settings ignores Escape and Command W): its Back button, or else its Close.
    @discardableResult
    public func closeSheetPage() -> Bool {
        guard inSheet, let w = window else { return false }
        var back: AXUIElement?, close: AXUIElement?
        var stack = [w], visited = 0
        while let e = stack.popLast(), visited < 400 {
            visited += 1
            if e.role == "AXButton" {
                let id = e.string(kAXIdentifierAttribute) ?? ""
                let d = Self.words(e).lowercased()
                if back == nil, id == "BackButton" || d == "back" { back = e }
                if close == nil, id.hasSuffix("CloseButton") || ["close", "done", "cancel"].contains(d) { close = e }
            }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        guard let b = back ?? close else { return false }
        Log.io("chat: Escape in a sheet presses \(back != nil ? "Back" : "Close")")
        return AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
    }

    /// Elements found by identifier, kept and checked before each use (one question: does it still carry the
    /// identifier?) rather than walked for again: the watcher asked for the title and the transcript every second,
    /// three walks of the window each (8 Oct 2026).
    private var found: [String: AXUIElement] = [:]
    /// Whether an element is the part with this id: by its match where the recipe gives one, else its identifier.
    public func isPart(_ e: AXUIElement, _ id: String) -> Bool {
        if let m = spec.partMatch[id] { return m(e) }
        return e.string(kAXIdentifierAttribute) == id
    }
    /// The window holds the conversations list: a window that doesn't (Messages Settings, a standard window, not a
    /// sheet) isn't a chat with none open (a review, 14 Nov 2026).
    public var hasConversations: Bool { find(spec.conversationsID) != nil }
    private func find(_ id: String) -> AXUIElement? {
        if spec.partMatch[id] != nil { return findByMatch(id) }
        guard let w = window else { found = [:]; return nil }
        if let e = found[id] {
            if e.string(kAXIdentifierAttribute) == id, let ew = e.element(kAXWindowAttribute), ew.isSame(w) { return e }
            found[id] = nil
        }
        var stack = [w], visited = 0
        while let e = stack.popLast(), visited < 3000 {
            visited += 1
            if e.string(kAXIdentifierAttribute) == id { found[id] = e; return e }
            if e.role == "AXTable" || e.role == "AXOutline" { continue }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        return nil
    }

    /// A part found by its match (a web page's chat), kept while it still matches and is in the window. Web pages
    /// are deep: up to 6000 elements are walked, and nothing inside a part already found is entered again.
    private func findByMatch(_ id: String) -> AXUIElement? {
        guard let w = window, let m = spec.partMatch[id] else { found = [:]; return nil }
        if let e = found[id] {
            if m(e), let ew = e.element(kAXWindowAttribute), ew.isSame(w) { return e }
            found[id] = nil
        }
        var stack = [w], visited = 0
        while let e = stack.popLast(), visited < 6000 {
            visited += 1
            if m(e) { found[id] = e; return e }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        return nil
    }

    private func messages() -> [AXUIElement] {
        guard let t = find(spec.transcriptID) else { return [] }
        return items(in: t, spec.isMessage)
    }

    /// The newest messages only, for the watcher: in a web page's chat (Discord) the whole transcript was walked
    /// every second on the main thread, up to 3000 elements (a review, 13 Nov 2026); only its last few children are
    /// looked in. Native chats keep their list of children, as before.
    private func recentMessages() -> [AXUIElement] {
        guard let t = find(spec.transcriptID) else { return [] }
        guard !spec.partMatch.isEmpty else { return items(in: t, spec.isMessage) }
        var n: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(t, kAXChildrenAttribute as CFString, &n) == .success, n > 0 else { return [] }
        let take = min(n, Self.recentChildren)
        var v: CFArray?
        guard AXUIElementCopyAttributeValues(t, kAXChildrenAttribute as CFString, n - take, take, &v) == .success,
              let tail = v as? [AXUIElement] else { return [] }
        var out: [AXUIElement] = []
        for c in tail {
            if spec.isMessage(c) { out.append(c); continue }
            var stack = Array(c.elements(kAXChildrenAttribute).reversed()), visited = 0
            while let e = stack.popLast(), visited < 60 {
                visited += 1
                if spec.isMessage(e) { out.append(e); continue }
                stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
            }
        }
        return out
    }
    /// Enough of the transcript's end for a burst of five, with day dividers between.
    static let recentChildren = 8

    /// A part's items: its children that match (Messages, WhatsApp), or, in a web page's chat, the matching elements
    /// anywhere inside it (Discord's channel links sit two groups down in each list item), in the page's order.
    private func items(in container: AXUIElement, _ isItem: (AXUIElement) -> Bool) -> [AXUIElement] {
        guard !spec.partMatch.isEmpty else { return container.elements(kAXChildrenAttribute).filter(isItem) }
        var out: [AXUIElement] = []
        var stack = Array(container.elements(kAXChildrenAttribute).reversed()), visited = 0
        while let e = stack.popLast(), visited < 3000 {
            visited += 1
            if isItem(e) { out.append(e); continue }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        return out
    }

    /// The container the conversations were last found in: each Up or Down searched the whole window again (up to
    /// 600 calls, 120 to 170 ms a move in WhatsApp's Archived; 13 Oct 2026: "not quite as snappy").
    /// Kept only while the arrows are moving (3 s from the last move), and dropped whenever a part is entered afresh:
    /// another section or search results come from a full search.
    private var conversationsParent: AXUIElement?
    private var conversationsCacheUntil = Date.distantPast
    /// The test the full search used to pick the list's items, so the cache picks the same ones (code review, 13 Oct:
    /// re-reading with the plain test added headers to Archived's list, and Calls' cells never matched it).
    private var conversationsFilter: (AXUIElement) -> Bool = { _ in false }

    private func conversations() -> [AXUIElement] {
        // The same container as last time, if it is still in this window and still holds conversations.
        if spec.partMatch.isEmpty, Date() < conversationsCacheUntil, let p = conversationsParent, let w = window, let pw = p.element(kAXWindowAttribute), pw.isSame(w) {
            let list = p.elements(kAXChildrenAttribute).filter(conversationsFilter)
            if !list.isEmpty { conversationsCacheUntil = Date().addingTimeInterval(3); return list }
        }
        conversationsParent = nil
        let list = searchConversations()
        conversationsParent = list.first?.element(kAXParentAttribute)
        conversationsCacheUntil = Date().addingTimeInterval(3)
        return list
    }

    private func searchConversations() -> [AXUIElement] {
        if let prefix = spec.resultsPrefix, let w = window {
            var stack = [w], visited = 0
            while let e = stack.popLast(), visited < 3000 {
                visited += 1
                if spec.partMatch.isEmpty ? e.string(kAXIdentifierAttribute) == spec.transcriptID : isPart(e, spec.transcriptID) { continue }
                let kids = e.elements(kAXChildrenAttribute)
                if kids.contains(where: { ($0.string(kAXIdentifierAttribute) ?? "").hasPrefix(prefix) }) {
                    let list = kids.filter(spec.isConversation)
                    if !list.isEmpty { conversationsFilter = spec.isConversation; return list }
                }
                stack.append(contentsOf: kids.reversed())
            }
        }
        if let l = find(spec.conversationsID) {
            let list = items(in: l, spec.isConversation)
            if !list.isEmpty { conversationsFilter = spec.isConversation; return list }
        }
        // Another section's list (WhatsApp's Archived is "WAArchivedChatsViewController", 7 Oct 2026; Starred and Calls
        // have their own): the container holding the most items with their own actions, outside the messages.
        guard let w = window else { return [] }
        var best: [AXUIElement] = []
        var stack = [w], visited = 0
        while let e = stack.popLast(), visited < 3000 {
            visited += 1
            let id = e.string(kAXIdentifierAttribute) ?? ""
            // (Identifier-found parts compare the id already fetched: no extra question per element for WhatsApp.)
            let isTranscript = spec.partMatch.isEmpty ? id == spec.transcriptID : isPart(e, spec.transcriptID)
            if isTranscript || id.hasPrefix(spec.sectionsPrefix ?? "\u{0}") { continue }
            let kids = e.elements(kAXChildrenAttribute)
            let withActions = kids.filter(hasNameAction)
            if withActions.count > best.count { best = withActions }
            stack.append(contentsOf: kids)
        }
        // A section that isn't chats (WhatsApp's Calls): its cells. The app won't take the keyboard into them.
        if !best.isEmpty { conversationsFilter = { [weak self] k in self?.hasNameAction(k) ?? false }; return best }
        conversationsFilter = Self.isSectionCell
        return sectionContent()
    }

    private func hasNameAction(_ k: AXUIElement) -> Bool {
        var a: CFArray?; AXUIElementCopyActionNames(k, &a)
        return ((a as? [String]) ?? []).contains { $0.hasPrefix("Name:") } && spec.isConversation(k)
    }
    private static func isSectionCell(_ k: AXUIElement) -> Bool {
        k.role == "AXButton" && (k.string(kAXIdentifierAttribute) ?? "").hasSuffix("Cell")
    }

    /// The cells of a section that isn't a list of chats (WhatsApp's Calls: buttons "CallHistoryView_…Cell"): the
    /// container with the most of them, outside the bar and the messages.
    private func sectionContent() -> [AXUIElement] {
        guard let w = window else { return [] }
        var best: [AXUIElement] = []
        var stack = [w], visited = 0
        while let e = stack.popLast(), visited < 3000 {
            visited += 1
            let id = e.string(kAXIdentifierAttribute) ?? ""
            let isPartHere = spec.partMatch.isEmpty ? (id == spec.transcriptID || id == spec.conversationsID)
                : (isPart(e, spec.transcriptID) || isPart(e, spec.conversationsID))
            if isPartHere || id.hasPrefix(spec.sectionsPrefix ?? "\u{0}") { continue }
            let kids = e.elements(kAXChildrenAttribute)
            let cells = kids.filter(Self.isSectionCell)
            if cells.count > best.count { best = cells }
            stack.append(contentsOf: kids)
        }
        return best
    }

    public var composer: AXUIElement? { find(spec.composerID) }

    /// The bar of sections, in order, with the group headings among them (WhatsApp's "Lists").
    private func sections() -> [AXUIElement] {
        guard let prefix = spec.sectionsPrefix, let w = window else { return [] }
        var out: [AXUIElement] = []
        var stack = [w], visited = 0
        while let e = stack.popLast(), visited < 2000 {
            visited += 1
            if (e.string(kAXIdentifierAttribute) ?? "").hasPrefix(prefix) {
                // Its siblings are the bar: the sections and the headings between them.
                if let bar = e.element(kAXParentAttribute) {
                    // (WhatsApp's Media has no identifier: any text in the bar is a section.)
                    return bar.elements(kAXChildrenAttribute).filter { ($0.string(kAXIdentifierAttribute) ?? "").hasPrefix(prefix) || ["AXHeading", "AXStaticText"].contains($0.role) }
                }
                out.append(e)
            }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        return out
    }

    /// The words of an item: its description, and its value when that adds (WhatsApp's chat preview).
    public static func words(_ e: AXUIElement) -> String {
        var parts: [String] = []
        for k in [kAXDescriptionAttribute, kAXTitleAttribute] { if let t = e.string(k)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) } }
        if let v = e.attr(kAXValueAttribute) as? String, !v.isEmpty, !parts.contains(v) { parts.append(v) }
        if parts.isEmpty {
            // A time stamp or a day heading: its text is in a child.
            for c in e.elements(kAXChildrenAttribute) {
                if let t = c.string(kAXDescriptionAttribute) ?? c.string(kAXValueAttribute), !t.isEmpty { parts.append(t) }
            }
        }
        if parts.isEmpty {
            // A web page's message: a list item holding an article titled "who, what" (Discord). Only where nothing
            // above found words, so Messages and WhatsApp read as before.
            for c in e.elements(kAXChildrenAttribute) {
                if let t = c.string(kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) }
            }
        }
        // WhatsApp marks its words with invisible direction marks; they are noise to speech.
        return parts.joined(separator: ", ").replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{200F}", with: "")
    }

    // MARK: Moving between the parts

    /// Tab from the box: to the messages, on the newest. Shift Tab: to the conversations, on the open one.
    /// Whether an element is one of the sections (WhatsApp's own focus lands on them).
    public func isSection(_ e: AXUIElement) -> Bool { sections().contains { CFEqual($0, e) } }

    /// keepList: Tab and Shift Tab between the parts keep the conversation list last found (if it's still in the window
    /// and still holds conversations): a fresh search of WhatsApp's window took 170 ms and 650 questions on every Tab
    /// (15 Oct 2026: "should all be snappy"). A section pressed, or search results, look afresh.
    public func enter(_ p: Pane, at element: AXUIElement? = nil, keepList: Bool = false) {
        leftParts = false
        if keepList, conversationsParent != nil { conversationsCacheUntil = Date().addingTimeInterval(3) }
        else { conversationsCacheUntil = .distantPast }   // entering a part looks again (another section, search results)
        loading = false; exhausted = nil
        if !(keepList && p == .conversations) { listShift = 0 }   // back to the same list: its numbers stay
        let list = p == .transcript ? messages() : p == .sections ? sections() : conversations()
        guard !list.isEmpty else {
            Speech.speakMessage(p == .transcript ? String(localized: "no messages", comment: "A chat app's list is empty") : p == .sections ? String(localized: "no sections", comment: "A chat app's list is empty") : String(localized: "no conversations", comment: "A chat app's list is empty"))
            return
        }
        pane = p
        items = list
        var i = list.count - 1
        if p == .conversations || p == .sections {
            i = list.firstIndex { ($0.attr(kAXSelectedAttribute) as? Bool) == true } ?? (p == .sections ? (index[p] ?? 0) : 0)
        }
        if let element, let at = list.firstIndex(where: { CFEqual($0, element) }) { i = at }
        index[p] = min(i, list.count - 1)
        Speech.speakOnly(p == .transcript ? String(localized: "messages", comment: "A part of the chat window") : p == .sections ? String(localized: "sections", comment: "A part of the chat window") : String(localized: "conversations", comment: "A part of the chat window"))
        announce()
    }

    /// Back to the box (Escape, or Tab round from the conversations).
    public func toComposer(quietly: Bool = false) {
        // No conversation open: Escape says so and leaves the cursor where it is. Dropping out left the keyboard
        // on WhatsApp's own focus, where the arrows wandered the sections and Return did nothing (10 Oct 2026).
        guard let c = composer else { Speech.speakMessage(String(localized: "no conversation open", comment: "Spoken message")); return }
        pane = .composer
        Braille.releaseItem()
        SettingsPanePlugin.noteToolbar(c)
        // The box usually still has the keyboard (TurnOver only moved its cursor), so no focus event comes: say it.
        let had = (c.attr(kAXFocusedAttribute) as? Bool) == true
        _ = c.set(kAXFocusedAttribute, kCFBooleanTrue)
        Log.io("chat: to the box (quietly \(quietly), had the focus \(had), last said \(Speech.sinceFocusSpoken) s ago)")
        // TurnOver's focus follows, said or not: typing is echoed where TurnOver thinks the focus is (13 Oct 2026).
        if quietly { API.setFocusObject(ObjectFactory.make(c), ancestors: API.focusAncestors); return }
        if had { Speech.speakObject(ObjectFactory.make(c), reason: .focus) } else { AXHandler.shared.refocus(pid: pid) }
    }

    /// The button held now (pane `control`).
    private var heldControl: AXUIElement?
    /// The toolbar's items when the stops were last worked out.
    private var toolbarHeld: [AXUIElement] = []
    private enum Stop { case part(Pane), control(AXUIElement) }

    /// The toolbar's items, left to right: the AXToolbar's and what sits in its strip (Messages' Conversation Details
    /// and FaceTime). One Tab stop, the arrows along it, as every toolbar (a tester, 12 Nov 2026).
    private func toolbarControls() -> (toolbar: AXUIElement, items: [AXUIElement])? {
        guard let w = window, let anchor = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }) else { return nil }
        return SettingsPanePlugin.toolbarItems(around: anchor)
    }

    /// The named buttons in the message box's row (Messages: add; Record audio, Emoji picker).
    private func boxRow(_ box: AXUIElement) -> [AXUIElement] {
        guard let bf = TurnOverObject.frame(box), let parent = box.element(kAXParentAttribute) else { return [] }
        return parent.elements(kAXChildrenAttribute).filter { e in
            guard ["AXButton", "AXMenuButton", "AXPopUpButton"].contains(e.role), !ObjectFactory.make(e).name.isEmpty,
                  let f = TurnOverObject.frame(e) else { return false }
            return abs(f.midY - bf.midY) < max(20, bf.height)
        }.sorted { (TurnOverObject.frame($0)?.minX ?? 0) < (TurnOverObject.frame($1)?.minX ?? 0) }
    }

    /// Every stop of Tab, in the screen's order (a tester, 12 Nov 2026: "Conversation list, the toolbar with compose,
    /// start call, info, … the message list, then add button, message edit, then … the emoji picker and the
    /// dictate/record audio buttons"): the toolbar and the box's own buttons were never reached.
    private func stops(box: AXUIElement) -> [Stop] {
        toolbarHeld = []
        var out: [Stop] = spec.sectionsPrefix != nil ? [.part(.sections)] : []
        out.append(.part(.conversations))
        if let (tb, items) = toolbarControls(), let stop = SettingsPanePlugin.toolbarStop(tb, items) {
            out.append(.control(stop))
            toolbarHeld = items
        }
        // The conversation's title where it is a button (Messages' Conversation Details): under the toolbar, not in
        // it, so a stop of its own.
        if let t = find(spec.titleID), t.role == "AXButton", !toolbarHeld.contains(where: { CFEqual($0, t) }) { out.append(.control(t)) }
        out.append(.part(.transcript))
        let row = boxRow(box), mid = TurnOverObject.frame(box)?.midX ?? 0
        out += row.filter { (TurnOverObject.frame($0)?.midX ?? 0) < mid }.map { .control($0) }
        out.append(.part(.composer))
        out += row.filter { (TurnOverObject.frame($0)?.midX ?? 0) > mid }.map { .control($0) }
        return out
    }

    private func hold(_ e: AXUIElement) {
        pane = .control; heldControl = e
        Braille.releaseItem()
        // Space and Return press it, and its actions (VO-Command-Space) are the cursor's: the tab trap's held place.
        SettingsPanePlugin.holdVirtual(e, speak: true, ownTab: false)
    }

    /// Tab and Shift Tab round the parts in the screen's order (13 Oct 2026: the box comes after the
    /// conversation): sections, conversations, the toolbar, messages, the box with its buttons, and round; Shift Tab
    /// the other way.
    public func cycle(forward: Bool) {
        if let box = composer {
            let all = stops(box: box)
            let at = all.firstIndex { stop in
                switch stop {
                case .part(let p): return p == pane
                // Any of the toolbar's items stands for its stop (the arrows moved along it).
                case .control(let e): return pane == .control && heldControl.map { h in CFEqual(h, e) || (toolbarHeld.contains { CFEqual($0, h) } && toolbarHeld.contains { CFEqual($0, e) }) } == true
                }
            } ?? all.firstIndex { if case .part(.composer) = $0 { return true }; return false } ?? 0
            switch all[(at + (forward ? 1 : -1) + all.count) % all.count] {
            case .part(.composer): toComposer()
            case .part(let p): enter(p, keepList: true)
            case .control(let e): hold(e)
            }
            return
        }
        let hasSections = spec.sectionsPrefix != nil
        switch (pane, forward) {
        case (.sections, true): enter(.conversations, keepList: true)
        case (.sections, false): composer == nil ? enter(.conversations, keepList: true) : toComposer()
        // No conversation open and no sections: Tab goes on to the rest of the window, the app's own Tab from where its
        // focus is (Discord's Friends page: Tab went round the conversations alone, 12 Nov 2026).
        case (.conversations, true) where composer == nil && !hasSections: leaveParts(forward: true)
        case (.conversations, false) where composer == nil && !hasSections: leaveParts(forward: false)
        case (.conversations, true): composer == nil ? enter(hasSections ? .sections : .conversations, keepList: true) : enter(.transcript)
        case (.conversations, false): hasSections ? enter(.sections) : (composer == nil ? enter(.conversations, keepList: true) : toComposer())
        case (.transcript, true): composer == nil ? enter(.conversations, keepList: true) : toComposer()
        case (.transcript, false): enter(.conversations, keepList: true)
        case (.composer, true): enter(hasSections ? .sections : .conversations, keepList: true)
        case (.composer, false): enter(.transcript)
        case (.control, _): enter(.conversations, keepList: true)   // (no box: no buttons were held)
        }
    }

    public var isBrowsing: Bool { pane != .composer && pane != .control }

    /// Out of the parts, with no conversation open: the app's own Tab carries on, and Tab is the app's until the
    /// conversations are entered again (TurnOver Shift F6 and the arrows still reach them).
    public private(set) var leftParts = false
    private func leaveParts(forward: Bool) {
        pane = .composer; leftParts = true
        Braille.releaseItem()
        Log.io("chat: no conversation open; Tab goes on to the rest of the window")
        KeyboardGesture(identifier: forward ? "kb:tab" : "kb:shift+tab")?.send()
    }

    /// The keyboard went elsewhere (a click, a sheet): the parts are left as they are.
    public func focusLeft() { pane = .composer; Braille.releaseItem() }

    public func move(_ delta: Int) {
        refreshItems()
        guard !items.isEmpty else { return }
        let cur = index[pane] ?? 0
        let next = cur + delta
        if next < 0, pane == .transcript, loadOlder() { return }
        // Down past the last conversation held: the list may hold only what has been loaded (WhatsApp's Archived,
        // Discord's channels and DMs); scroll it on and carry on (15 Oct 2026: "hits the end before I think it
        // is the end"). Where nothing more comes, the edge as before.
        if next >= items.count, pane == .conversations, loadMore(forward: true) { return }
        // Up past the first row held: the list may have dropped rows off its top as it scrolled (WhatsApp's Archived
        // came back at "1 of 13" mid-list, and Up bonked, 15 Oct 2026). Bring them back the same way; at the
        // real top the scroll bar says so and the edge comes at once.
        if next < 0, pane == .conversations, loadMore(forward: false) { return }
        guard items.indices.contains(next) else { Tones.edge(); return }
        index[pane] = next
        announce()
    }

    public func toEnd(_ last: Bool) {
        refreshItems()
        guard !items.isEmpty else { return }
        index[pane] = last ? items.count - 1 : 0
        announce()
    }

    /// The lists change under us (a message arrives, the list scrolls): read them again, keeping the place by its words.
    private func refreshItems() {
        let keep = currentItem().map(Self.words)
        let fresh = pane == .transcript ? messages() : pane == .conversations ? conversations() : pane == .sections ? sections() : []
        items = fresh
        // The match nearest the old place: short replies ("ok") repeat, and the first of them pulled the cursor back,
        // so Down looped and actions went to an earlier message (a review, 14 Nov 2026).
        let old = index[pane] ?? 0
        if let k = keep, let i = fresh.indices.filter({ Self.words(fresh[$0]) == k }).min(by: { abs($0 - old) < abs($1 - old) }) {
            // The list slid under us (rows dropped or added above): the numbers keep their place.
            if pane == .conversations, let j = index[pane] { listShift = max(0, listShift + j - i) }
            index[pane] = i
        }
        else if let i = index[pane] { index[pane] = min(i, max(0, fresh.count - 1)) }
    }

    /// Up at the oldest message held: scroll the conversation back and carry on from the message before.
    private func loadOlder() -> Bool { loadMore(forward: false) }

    /// At the first (or last) item held: ask the list to load more, and carry on from the item before (after) it.
    /// The scroll area's page action where it has one (Messages, WhatsApp, as before); otherwise the edge item is
    /// scrolled into view, which is what makes a web page's list (Discord) load the next lot. Up to 1.5 s for them.
    /// A load under way (held keys repeat: each started another, and another search), and the edge where the last
    /// load found nothing more, so the next key there bumps at once instead of waiting again.
    private var loading = false
    private var exhausted: (pane: Pane, forward: Bool, key: String)?

    private func loadMore(forward: Bool) -> Bool {
        if loading { return true }   // the one under way answers
        guard let edge = forward ? items.last : items.first else { return false }
        let key = Self.words(edge)
        if let x = exhausted, x.pane == pane, x.forward == forward, x.key == key { return false }
        let keyIndex = forward ? items.count - 1 : 0
        let action = forward ? "AXScrollDownByPage" : "AXScrollUpByPage"
        var scroller: AXUIElement? = pane == .transcript ? find(spec.transcriptID) : edge.element(kAXParentAttribute)
        var hops = 0
        while let s = scroller, hops < 6 {
            var a: CFArray?; AXUIElementCopyActionNames(s, &a)
            if ((a as? [String]) ?? []).contains(action) { break }
            scroller = s.element(kAXParentAttribute); hops += 1
        }
        // Already at that end of the scroll (its bar at 0 or 1): nothing more to load; the caller bumps at once.
        // (The bar is on the scroll area, which may be the list's parent.)
        if let s = scroller, let bar = s.element(kAXVerticalScrollBarAttribute) ?? s.element(kAXParentAttribute)?.element(kAXVerticalScrollBarAttribute),
           let v = (bar.attr(kAXValueAttribute) as? NSNumber)?.doubleValue, forward ? v >= 0.999 : v <= 0.001 {
            exhausted = (pane, forward, key)
            return false
        }
        // A web page's list (Discord) loads more as its edge comes into view; the page's own scroll area isn't the
        // list's. Native lists (Messages, WhatsApp) by the page action, as before.
        if !spec.partMatch.isEmpty, AXUIElementPerformAction(edge, "AXScrollToVisible" as CFString) == .success {
            Log.io("chat: at the \(forward ? "end" : "start") of what's loaded; scrolled its edge into view for more")
        } else if let s = scroller, AXUIElementPerformAction(s, action as CFString) == .success {
            Log.io("chat: at the \(forward ? "end" : "start") of what's loaded; scrolled a page for more")
        } else if AXUIElementPerformAction(edge, "AXScrollToVisible" as CFString) == .success {
            Log.io("chat: at the \(forward ? "end" : "start") of what's loaded; scrolled its edge into view for more")
        } else {
            Tones.edge(); return true
        }
        let p = pane
        loading = true
        func look(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, pane == p, loading else { return }
                items = p == .transcript ? messages() : conversations()
                if let i = items.firstIndex(where: { Self.words($0) == key }), forward ? i < items.count - 1 : i > 0 {
                    // (Rows found above the first ever held: the numbers start from those, never below 1.)
                    if p == .conversations { listShift = max(0, listShift + keyIndex - i) }
                    index[p] = forward ? i + 1 : i - 1
                    loading = false
                    announce(); return
                }
                if tries < 7 { look(tries + 1); return }   // up to 1.2 s for a slow list, looked at every 0.15 s
                if let i = items.firstIndex(where: { Self.words($0) == key }) { index[p] = i }
                loading = false
                exhausted = (p, forward, key)
                Tones.edge()   // nothing more
            }
        }
        // (The list's container is kept: it's the same list, grown. Searching the window again on each look cost
        // 650 questions a time in WhatsApp.)
        look(0)
        return true
    }

    /// Rows the conversation list dropped off its top as more were loaded at the bottom, so the numbers carry on
    /// ("11 of 11", then "12 of 22", not "3 of 13"). Reset whenever a part is entered afresh.
    private var listShift = 0

    private func currentItem() -> AXUIElement? {
        guard let i = index[pane], items.indices.contains(i) else { return nil }
        return items[i]
    }

    private func announce() {
        guard let e = currentItem(), let i = index[pane] else { return }
        var parts = [Self.words(e)]
        if parts[0].isEmpty { parts[0] = Phrases.blank }
        if pane == .conversations, (e.attr(kAXSelectedAttribute) as? Bool) == true { parts.append(State.selected.displayString) }
        // A list that drops rows as it scrolls (WhatsApp's Archived) keeps its numbering from before the load.
        let shift = pane == .conversations ? listShift : 0
        parts.append(Phrases.position(i + 1 + shift, of: items.count + shift))
        // Messages and conversations (their last message, a name) are someone's words: in the log only their length,
        // as new messages are (a review, 13 Nov 2026: browsing logged them whole). A section's name is the app's.
        let said = parts.joined(separator: ", ")
        if pane == .sections { Speech.speakItem(said, processed: true) }
        else { Speech.redactedInLog(pane == .transcript ? "message" : "conversation") { Speech.speakItem(said, processed: true) } }
        // Object navigation starts from here, as from any focus (a tester, 12 Nov 2026: Tab showed one part while the
        // review cursor stayed where it was left).
        ObjectNavigator.shared.focusMoved(to: e, pid: pid)
        SettingsPanePlugin.noteToolbar(e)   // off the toolbar: the arrows are the list's
        Hints.schedule(pane == .transcript
            ? String(localized: "Up and Down move through the messages; the shortcut menu has reply, tapback and copy. Escape goes back to the message box.", comment: "A hint in a chat app")
            : pane == .sections ? String(localized: "Return shows that section. Tab goes on.", comment: "A hint in a chat app") : String(localized: "Return opens the conversation. Escape goes back to the message box.", comment: "A hint in a chat app"))
    }

    /// For the test tool: how many of each part were found (no words, as they are private).
    public func debugCounts() -> String {
        let m = messages(), c = conversations()
        let latest = latestWords() ?? ""
        return "messages \(m.count), conversations \(c.count), box \(composer != nil), newest message \(latest.count) characters, title \(find(spec.titleID) != nil)"
    }

    // MARK: Acting

    /// Return: open the conversation (and go to its box), or press the message (a link, a photo).
    public func activate() {
        refreshItems()
        guard let e = currentItem() else { return }
        // (A search result is a group with its pressable text inside.)
        var target = e
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        if !((names as? [String]) ?? []).contains(kAXPressAction as String),
           let inner = MediaView.first(in: e, depth: 3, where: { x in var a: CFArray?; AXUIElementCopyActionNames(x, &a); return ((a as? [String]) ?? []).contains(kAXPressAction as String) }) {
            target = inner
        }
        let r = AXUIElementPerformAction(target, kAXPressAction as CFString)
        Log.io("chat: press \(pane) item → \(r.rawValue)")
        if pane == .sections, r == .success {
            // A section shows its own list (Archived, Starred): on to it.
            Tones.press()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                if !conversations().isEmpty { enter(.conversations); return }
                // A section with nothing TurnOver can list: the app's arrows are left to work, from its focus.
                pane = .composer
                var v: AnyObject?
                if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &v) == .success,
                   let v, CFGetTypeID(v) == AXUIElementGetTypeID() {
                    ObjectFactory.make(v as! AXUIElement).reportFocus()
                }
            }
            return
        }
        if pane == .conversations, r == .success {
            Tones.press()
            // The press answered success and opened nothing: Return on "Mum, Dad and Ollie" went to the box of the
            // conversation already open, and the link pasted there went to the wrong person (the maintainer, 26 Oct
            // 2026). So the open conversation's title is checked against the item pressed before the box is entered;
            // on a mismatch the row is selected instead, and if that fails too, TurnOver says which conversation is
            // open and stays in the list, never in a box that isn't the one chosen.
            let wanted = Self.words(e).lowercased()
            var tries = 0
            func settle() {
                let open = openTitle()
                let matches = open.map { $0.isEmpty || wanted.contains($0.lowercased()) } ?? true   // no title: nothing to check against
                if !matches, tries == 0 {
                    tries += 1
                    Log.io("chat: the open conversation is \(Log.words(open ?? "")), not the one pressed; selecting the row")
                    _ = e.set(kAXSelectedAttribute, kCFBooleanTrue)
                    if let list = e.element(kAXParentAttribute) { _ = list.set(kAXSelectedRowsAttribute, [e] as CFArray) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settle() }
                    return
                }
                if !matches {
                    Log.io("chat: still open: \(Log.words(open ?? "")); staying in the list")
                    Tones.edge()
                    Speech.speakMessage(open.map { String(localized: "\($0) is open, not the one chosen. Press Return again.", comment: "Spoken message: %@ is the conversation open") }
                        ?? String(localized: "Another conversation is open, not the one chosen. Press Return again.", comment: "Spoken message"))
                    return
                }
                // The app puts its focus in the box as the conversation opens, and that is said; only if it didn't, say it.
                // (WhatsApp flicks its focus to a nameless group after the box: the box said just now is enough.)
                let inBox = API.focusObject.map { isPart($0.element, spec.composerID) } == true
                    || ((composer?.attr(kAXFocusedAttribute) as? Bool) == true && Speech.sinceFocusSpoken < 1.0)
                toComposer(quietly: inBox)
                // WhatsApp moves its focus to the chat's content a moment after opening it (7 Oct 2026): back to the
                // box, quietly, once it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard let self, pane == .composer, let c = composer, (c.attr(kAXFocusedAttribute) as? Bool) != true else { return }
                    Log.io("chat: the app moved the focus off the message box; putting it back")
                    _ = c.set(kAXFocusedAttribute, kCFBooleanTrue)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle() }
        }
    }

    /// The shortcut menu: the item's own actions (reply, tapback, copy, pin, mark as read…), by name.
    /// Messages' Tapback (Command T) as a TurnOver list: the picker is opened for the message TurnOver is on (or the
    /// app's own selection), its buttons become a list, Return reacts (a tester, 9 Oct 2026). VoiceOver users had to find
    /// the picker and VO Space each emoji.
    public func reactionChooser() {
        // The message TurnOver's cursor is on, given the app's focus so Command T acts on it.
        if pane == .transcript, let e = currentItem() {
            _ = e.set(kAXFocusedAttribute, kCFBooleanTrue)
            _ = e.set(kAXSelectedAttribute, kCFBooleanTrue)
        }
        let before = Set(Self.pickerButtons(pid: pid).map { $0.0 })
        KeyboardGesture(identifier: "kb:command+t")?.send()   // marked: the tap lets it by
        let pid = pid
        Poll.until(every: 0.08, limit: 1.5, { Self.pickerButtons(pid: pid).count >= 4 }) { found in
            let buttons = Self.pickerButtons(pid: pid)
            guard found, !buttons.isEmpty else {
                Log.io("chat: the Tapback picker did not appear (\(before.count) buttons before)")
                Speech.speakMessage(String(localized: "no reactions offered for this message", comment: "Spoken message")); return
            }
            Log.io("chat: Tapback picker with \(buttons.count) reactions")
            let items = buttons.map { b in MenuItem(verbatim: b.0, .action { _ = AXUIElementPerformAction(b.1, kAXPressAction as CFString) }) }
            TurnOverMenu.shared.openList("React", items: items)
            // The list closed without a choice (Escape): Messages' own picker would stay open on the message. Close it
            // too, with Escape to Messages (marked, so TurnOver lets it by). Tried live, 10 Oct 2026.
            Self.closePickerWhenListCloses(pid: pid)
        }
    }

    private static func closePickerWhenListCloses(pid: pid_t) {
        // Looked at every 0.2 s on the main thread, for up to two minutes.
        func check(_ n: Int) {
            guard n < 600 else { return }
            guard !TurnOverMenu.shared.isOpen else { onMain(after: 0.2) { check(n + 1) }; return }
            onMain(after: 0.3) {
                guard pickerButtons(pid: pid).count >= 4, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                Log.io("chat: the reaction list closed without a choice; closing Messages' picker")
                KeyboardGesture(identifier: "kb:escape")?.send()
            }
        }
        onMain(after: 0.2) { check(0) }
    }

    /// The Tapback picker's buttons, by name: the picker group (or a popover) of at least four buttons in the window.
    nonisolated static func pickerButtons(pid: pid_t) -> [(String, AXUIElement)] {
        let app = AXUIElementCreateApplication(pid)
        guard let w = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) else { return [] }
        var queue = [w], n = 0
        while !queue.isEmpty, n < 1500 {
            let e = queue.removeFirst(); n += 1
            // Messages (macOS 27): a group in the window, identifier TapbackPickerCollectionView, with one button per
            // reaction, each named by its description (Heart, Thumbs up… and recent emoji). Measured 10 Oct 2026.
            if e.role == "AXPopover" || (e.string(kAXIdentifierAttribute) ?? "").contains("TapbackPicker") {
                var out: [(String, AXUIElement)] = []
                var q2 = e.elements(kAXChildrenAttribute), m = 0
                while !q2.isEmpty, m < 200 {
                    let x = q2.removeFirst(); m += 1
                    if ["AXButton", "AXRadioButton", "AXCheckBox"].contains(x.role) {
                        let name = (x.string(kAXDescriptionAttribute) ?? x.string(kAXTitleAttribute) ?? x.string(kAXHelpAttribute) ?? "")
                            .replacingOccurrences(of: "\u{200E}", with: "")
                        if !name.isEmpty, !out.contains(where: { $0.0 == name }) { out.append((name, x)) }
                    }
                    q2.append(contentsOf: x.elements(kAXChildrenAttribute))
                }
                if out.count >= 4 { return out }
            }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return []
    }

    public func actionsMenu() {
        refreshItems()
        guard let e = currentItem() else { return }
        // The item's own, and its parts' (Messages keeps a message's actions on the bubble inside its row), each once.
        var found: [(owner: AXUIElement, action: String, title: String)] = []
        func collect(_ x: AXUIElement, _ depth: Int) {
            var names: CFArray?
            AXUIElementCopyActionNames(x, &names)
            for a in ((names as? [String]) ?? []) where a.hasPrefix("Name:") {
                let title = String(a.dropFirst(5).components(separatedBy: "\n").first ?? a).replacingOccurrences(of: "\u{200E}", with: "")
                if !found.contains(where: { $0.title == title }) { found.append((x, a, title)) }
            }
            if depth < 3 { for c in x.elements(kAXChildrenAttribute) { collect(c, depth + 1) } }
        }
        collect(e, 0)
        guard !found.isEmpty else {
            // No named actions (WhatsApp's messages): the item's own context menu, as a right click would open it.
            var names: CFArray?
            AXUIElementCopyActionNames(e, &names)
            if ((names as? [String]) ?? []).contains("AXShowMenu") {
                TurnOverObject.contextMenuRequestedAt = Date()
                let r = AXUIElementPerformAction(e, "AXShowMenu" as CFString)
                Log.io("chat: the item's context menu → \(r.rawValue)")
                if r == .success { return }
            }
            Speech.speakMessage(String(localized: "no actions", comment: "Spoken message")); return
        }
        let menu = found.map { f in MenuItem(verbatim: f.title, .action { _ = AXUIElementPerformAction(f.owner, f.action as CFString) }) }
        TurnOverMenu.shared.openList("Actions", items: menu)
    }

    /// TurnOver Command 1 to 9: the latest messages, 1 the newest, without moving.
    public func readLatest(_ n: Int) {
        let list = messages().filter { !Self.words($0).isEmpty && $0.role != "AXHeading" && !Self.isTimeStamp($0) }
        guard list.count >= n else { Speech.speakMessage(list.isEmpty ? String(localized: "no messages", comment: "A chat app's list is empty") : String(localized: "only \(String(list.count)) messages", comment: "Fewer messages than asked for: how many there are")); return }
        // Each press the one heard now, not queued behind the last (a review, 13 Nov 2026); in the log, its length.
        Speech.cancel()
        Speech.redactedInLog("message") { Speech.speakText(Self.words(list[list.count - n])) }
    }

    /// Messages' nameless groups that hold only a time stamp.
    static func isTimeStamp(_ e: AXUIElement) -> Bool {
        isTimeStamp(role: e.role, description: e.string(kAXDescriptionAttribute) ?? "", title: e.string(kAXTitleAttribute) ?? "",
                    subrole: e.string(kAXSubroleAttribute) ?? "")
    }

    /// A group with neither description nor title. Discord's messages are groups too, articles named by their title
    /// with no description: every one was taken for a time stamp, so "no messages" was said and none arriving was
    /// read (a review, 13 Nov 2026).
    package static func isTimeStamp(role: String, description: String, title: String, subrole: String) -> Bool {
        role == "AXGroup" && subrole != "AXDocumentArticle"
            && description.trimmingCharacters(in: .whitespaces).isEmpty && title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: New messages

    private var watch: Timer?
    private var lastSeen: String?
    private var lastTitle: String?
    /// What the box last held, and what it held when it emptied (sent): a message is the user's own only if it holds
    /// those words, sent a moment ago. Any message within 3 s of the box having text was taken as one's own, so a
    /// message that came in while the user typed was never said (a review, 13 Nov 2026).
    private var composerText = ""
    private var justSent: (text: String, at: Date)?

    /// A message sent from the box with Return, its words taken before the key went: the watcher, looking once a
    /// second (every three while typing on the web), saw a short message sent between two looks never in the box, and
    /// read it back as one that came in (a review, 13 Nov 2026).
    public func noteSent(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        justSent = (t, Date()); composerText = ""
    }

    /// While the app is in front: read each new message that arrives in the open conversation (not the one just sent).
    public func startWatching() {
        stopWatching()
        lastSeen = latestWords()
        lastTitle = find(spec.titleID).map(Self.words)
        watch = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkNew() } }
    }

    public func stopWatching() { watch?.invalidate(); watch = nil }

    private func latestWords() -> String? { recentWords().last }

    /// The words of the newest messages, time stamps and headings left out.
    private func recentWords() -> [String] {
        recentMessages().filter { !Self.isTimeStamp($0) && $0.role != "AXHeading" }.map(Self.words)
    }

    /// When the watcher last looked, so a web page's chat is looked at less often while the user types.
    private var lastCheck = Date.distantPast

    /// Whether the watcher looks now: a web page's chat, while a key went down in the last second, every three
    /// seconds rather than every one, so typing in Discord isn't slowed by its walks (a review, 13 Nov 2026).
    /// A message that comes in meanwhile is still read, a little later.
    package static func watcherLooks(web: Bool, sinceKey: TimeInterval, sinceLastLook: TimeInterval) -> Bool {
        !web || sinceKey > 1 || sinceLastLook >= 3
    }

    private func checkNew() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        guard Self.watcherLooks(web: !spec.partMatch.isEmpty, sinceKey: Date().timeIntervalSince(InputManager.lastKeyDownAt),
                                sinceLastLook: Date().timeIntervalSince(lastCheck)) else { return }
        lastCheck = Date()
        let title = find(spec.titleID).map(Self.words)
        if title != lastTitle { lastTitle = title; lastSeen = latestWords(); return }   // another conversation opened
        let boxText = (composer?.attr(kAXValueAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !boxText.isEmpty { composerText = boxText }
        else if !composerText.isEmpty { justSent = (composerText, Date()); composerText = "" }
        let all = recentWords()
        guard let now = all.last, now != lastSeen else { return }
        let previous = lastSeen
        lastSeen = now
        guard let previous else { return }   // a conversation just opened: nothing new in it
        // The same message with a new status (Sent, then Delivered, then Read: WhatsApp read your own message back,
        // 7 Oct 2026) is not news.
        if Self.withoutStatus(now) == Self.withoutStatus(previous) { return }
        // Every message after the one last heard, up to five: a burst was only its last (a review, 13 Nov 2026).
        let from = all.lastIndex { Self.withoutStatus($0) == Self.withoutStatus(previous) }.map { $0 + 1 } ?? max(0, all.count - 1)
        var fresh = Array(all[min(from, all.count)...].suffix(5))
        if fresh.isEmpty { fresh = [now] }
        fresh.removeAll { $0.hasPrefix("Your message") }
        // Sent from here a moment ago: the box emptied, and one message holds its words whole. Only that one, and then
        // no other: after "ok", a reply holding "ok" in the next five seconds was dropped (a review, 13 Nov 2026).
        if let js = justSent, Date().timeIntervalSince(js.at) < 5, let i = fresh.firstIndex(where: { Self.isOwnMessage($0, sent: js.text) }) {
            fresh.remove(at: i); justSent = nil
        }
        if fresh.isEmpty { Log.io("chat: a message was sent"); justSent = nil; return }
        if SayAll.isRunning { return }
        Log.io("chat: \(fresh.count) new message(s) arrived")
        Speech.redactedInLog("message") { for m in fresh { Speech.speakText(m) } }
    }

    /// Whether a message's words are the text just sent: whitespace and line breaks run together on both sides (a
    /// message of two lines is read with them joined), the text the whole message or whole parts of it ("Alex, ok,
    /// 14:53": "ok", not the "ok" in "ok thanks"). A long text the app may shorten: its first 40 characters at the start
    /// of a part. Pure.
    package static func isOwnMessage(_ message: String, sent: String) -> Bool {
        func normal(_ t: String) -> String {
            t.replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{200F}", with: "")
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        }
        let m = normal(message), t = normal(sent)
        guard !t.isEmpty else { return false }
        if m == t || m.hasSuffix(", " + t) || m.hasPrefix(t + ", ") || m.contains(", " + t + ", ") { return true }
        guard t.count > 40 else { return false }
        let head = String(t.prefix(40))
        return m.hasPrefix(head) || m.contains(", " + head)
    }

    /// A message's words without its delivery status at the end ("…, 14:53, Sent to Alex, Delivered").
    static func withoutStatus(_ t: String) -> String {
        var parts = t.components(separatedBy: ", ")
        let statuses: Set<String> = ["Sent", "Delivered", "Read", "Seen", "Pending", "Not Delivered", "Played", "Edited"]
        while let last = parts.last, statuses.contains(last) || last.hasPrefix("Sent to") || last.hasPrefix("Read by") || last.hasPrefix("Delivered to") { parts.removeLast() }
        return parts.joined(separator: ", ")
    }

    /// Another conversation opened: what is in it is not news.
    public func conversationChanged() { lastSeen = latestWords() }
}
