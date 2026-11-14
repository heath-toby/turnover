// SPDX-License-Identifier: GPL-3.0-or-later
// Browse mode (NVDA: browseMode.BrowseModeDocumentTreeInterceptor + cursorManager).
//
// In a web document the reader owns a virtual caret: arrows read by line, word
// and character without the page seeing the keys; single letters jump to the
// next heading, link, button, list…; Enter activates what the caret is on. A
// focusable control that gains focus (an edit field) switches to focus mode,
// where keys pass through again; Caps+Space switches by hand; Escape returns.
//
// A browse mode document is a tree interceptor: it answers scripts and sees
// events for every object inside its web area, before the object itself.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

/// A key the page should answer (Tab), and no news from the application after it: the page is stuck (the freeze
/// tests, 4 Oct 2026: runs of silent Tabs). Says "page not responding", at most every 5 s.
public enum PageWatch {
    static var lastSpoken = Date.distantPast
    /// The first key since the page last sent news, and how many have gone unanswered since. One key alone can be
    /// dropped by a page that is fine (a false "not responding", 4 Oct 2026): two in a row, with no news, is stuck.
    static var waitingSince: Date?
    static var unanswered = 0
    public static func keySent(to pid: pid_t) {
        let now = Date()
        let news = AXHandler.shared.lastNewsAt[pid] ?? .distantPast
        if let since = waitingSince, news < since { unanswered += 1 } else { waitingSince = now; unanswered = 1 }
        let since = waitingSince ?? now
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard unanswered >= 2, (AXHandler.shared.lastNewsAt[pid] ?? .distantPast) < since,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  Date().timeIntervalSince(lastSpoken) > 5 else { return }
            lastSpoken = Date()
            Log.io("no news from pid \(pid) after \(unanswered) keys; the page seems stuck")
            Speech.speakMessage(String(localized: "please wait", comment: "Spoken message"))   // the page is busy; "not responding" overstated it
        }
    }
}

public final class BrowseModeDocument: ScriptableObject {
    /// When Tab last moved the focus from the reading position: a container the focus then enters is not announced,
    /// as VoiceOver does not on a page. Safari names a plain group after a heading nearby, and AppleVis's comment
    /// form read "Description of App, grouping" on every Tab into it (9 Oct 2026).
    public static var lastTabFromCaretAt = Date.distantPast
    public let webArea: AXUIElement
    public let bridge: WebDocumentBridge
    /// WebKit answers structural searches; other roots (Music's content pane) are searched in the buffer.
    public lazy var hasWebKitSearch: Bool = {
        if BrowseModeHandler.isChromium(pid: webArea.pid) { return false }   // Chromium answers searches, but TurnOver's buffer is the reliable path
        var names: CFArray?
        return AXUIElementCopyParameterizedAttributeNames(webArea, &names) == .success && ((names as? [String]) ?? []).contains("AXUIElementsForSearchPredicate")
    }()
    /// TurnOver's own copy of the page (NVDA's virtual buffer), rebuilt when the page changes.
    public let buffer: WebBuffer
    /// The virtual caret, an offset in the document. Remembered per page address, so returning to a page
    /// (Back after a link) lands where the reading was, as a file tree keeps its selection.
    public var position: Int = 0 {
        // Not while the page is empty (still arriving after Back): "the top of nothing" overwrote the place it was
        // left, so Back on MacRumors started at the top (3 Oct 2026).
        didSet {
            positionMovedAt = Date()
            // A read of the page again goes on at least this far (a long chat read on past its first part, issue 227).
            buffer.readingAt = position
            if buffer.text.length > 0 { BrowseModeHandler.shared.remember(url: url, position: position, text: lineText(at: position)) }
        }
    }
    /// When the reading position last moved: a keyboard focus that moved since (Tab onto a control the buffer does
    /// not hold yet) is what Enter and Space mean.
    var positionMovedAt = Date.distantPast
    /// The text of the buffer line at an offset (what Back looks for when the page comes back rearranged).
    func lineText(at offset: Int) -> String {
        guard let i = buffer.lineIndex(at: offset) else { return "" }
        let l = buffer.lines[i]
        guard l.end > l.start, l.end <= buffer.text.length else { return "" }
        return String(buffer.text.substring(with: NSRange(location: l.start, length: min(l.end - l.start, 120))))
    }
    /// WebKit's selection when the document last looked (to notice a find, or a selection the page made).
    var lastWebSelection: (Int, Int)?

    /// Put the virtual caret where WebKit's selection now is, if it moved since last time (NVDA: after Find, the caret
    /// is on the match). Safari's Find leaves the match selected; coming back to the page now reads it.
    @discardableResult
    public func followWebKitSelection(force: Bool = false) -> Bool {
        guard let sel = bridge.selection() else { return false }
        let first = lastWebSelection == nil
        if let last = lastWebSelection, last == sel, !force { return false }
        lastWebSelection = sel
        if first && !force { return false }
        // Find the match by its words in the buffer (WebKit's element at an index and the buffer disagree): the
        // match with what follows it on its line, nearest where it sits in proportion to the page.
        let line = bridge.unitRange("AXLineTextMarkerRangeForTextMarker", at: sel.0) ?? sel
        let lineEnd = max(line.1, sel.1)
        func webText(_ a: Int, _ b: Int) -> String { b > a ? (bridge.range(a, b).map { bridge.string($0) } ?? "") : "" }
        let pre = webText(max(line.0, sel.0 - 15), sel.0)
        let post = webText(sel.0, min(lineEnd, sel.1 + 25))
        let total = max(1, bridge.documentLength())
        let guess = Int(Double(sel.0) / Double(total) * Double(buffer.text.length))
        func occurrences(_ needle: String) -> [Int] {
            guard !needle.isEmpty, !needle.contains("\n") else { return [] }
            var out: [Int] = []; var from = 0
            while from < buffer.text.length {
                let r = buffer.text.range(of: needle, options: .literal, range: NSRange(location: from, length: buffer.text.length - from))
                if r.location == NSNotFound { break }
                out.append(r.location); from = r.location + 1
            }
            return out
        }
        var hits = occurrences(pre + post).map { $0 + (pre as NSString).length }
        if hits.isEmpty { hits = occurrences(post) }
        if hits.isEmpty { hits = occurrences(webText(sel.0, sel.1)) }
        guard let at = hits.min(by: { abs($0 - guess) < abs($1 - guess) }) else { Log.io("browse mode: WebKit's selection not found in the buffer"); return false }
        position = at
        Log.io("browse mode: to WebKit's selection at \(at)")
        return true
    }

    /// The page address now: Safari reuses one web area across navigations, so this is read each time.
    public var url: String { (webArea.attr("AXURL") as? URL)?.absoluteString ?? (webArea.attr("AXURL") as? String) ?? "" }
    var lastURL = ""

    /// After Back, Forward or a link: a new page in the same web area. Rebuild, and resume where this page was left.
    /// `byKey`: asked by a key (an arrow, a letter, Tab), not by the focus or the page's news. A new page found so is
    /// not announced later: its address taken as announced, the focus arriving on the web area much later announced it
    /// and read it all out, long after the key had read its line (a review, 13 Nov 2026).
    @discardableResult
    public func refreshIfNavigated(announce: Bool = false, byKey: Bool = true) -> Bool {
        let now = url
        guard now != lastURL else { return false }
        let first = lastURL.isEmpty
        // The same page, another anchor (a contents link, a footnote, "Jump to content"): to the target, read there,
        // not the page again from the top with its title (a review, 13 Nov 2026; NVDA moves to the target). Its anchor
        // gone again (Back from page#a to page) is the same page too: it was taken for a new one, the reading put at
        // the top and the page announced again (a review, 13 Nov 2026).
        if !first, Self.isSamePage(now, lastURL) {
            lastURL = now
            // Back or Forward between anchors is used up here too: left, it made a link followed within 10 s resume part
            // way down, as the new-page branch below says (a review, 13 Nov 2026).
            BrowseModeHandler.historyKeyAt = .distantPast
            if Self.urlBase(announcedURL) == Self.urlBase(now) { announcedURL = now }   // not announced again as a page when the focus follows
            // The page's own script moving its anchor under a say all of it: not read again there (its offsets would
            // mean other text); the next key reads it (a review, 13 Nov 2026).
            if !byKey, SayAll.isReading(self) { buffer.isDirty = true; return false }
            rebuildKeepingPlace()
            guard let frag = Self.samePageFragment(link: now, page: now) else {
                Log.io("browse mode: the same page without its anchor; the reading stays")
                return false
            }
            if let at = anchorOffset(frag) {
                // Gone to and read already as the link was pressed (followSamePageLink), its address spelt otherwise.
                if let m = samePageLinkMove, m.offset == at, Date().timeIntervalSince(m.at) < 5 {
                    // Already gone to as the link was pressed: the address catching up later must not put the reading
                    // back there (Command Up between: T said "wrapped to the top", 13 Nov 2026).
                    samePageLinkMove = nil; return false
                }
                position = at
                Log.io("browse mode: to the page's anchor")
                speakUnit(.line)
            } else if followWebKitSelection() {
                // Only if WebKit's selection moved (an anchor by name, not id: the browser went there). Forced, an
                // unchanged selection anywhere on the page was taken for the anchor and the reading jumped to it for a
                // fragment that names no anchor (a review, 13 Nov 2026).
                Log.io("browse mode: to the page's anchor, by WebKit's selection")
                speakUnit(.line)   // (moved silently before: a review, 13 Nov 2026)
            }
            return false
        }
        // A web app's view changed under focus mode (Gmail's o on a message: #inbox to #inbox/FM…): the user is working
        // in the app, so focus mode stays and the view is not announced or read from its top; only browse mode treats
        // it as a new page. Ended, focus mode was lost silently (a review, 13 Nov 2026).
        let keepFocusMode = !first && passThrough && Self.isRouteChange(now, lastURL)
        let wasEmpty = buffer.lines.isEmpty
        lastURL = now
        // Back or Forward counts for this arrival only: true for 10 s, it made a link followed after Back resume
        // part way down too (a review, 13 Nov 2026). The page still arriving resumes by it (historyURL).
        let byHistory = BrowseModeHandler.cameBackByHistory
        if byHistory { BrowseModeHandler.historyKeyAt = .distantPast }
        historyURL = byHistory ? now : ""
        if !first {
            // A say all of the page left reads a copy about to be replaced (its offsets meant other text).
            if SayAll.isReading(self) { SayAll.stop() }
            buffer.newPage()   // "page read in part" once per page, not per web area (Safari reuses one)
            buffer.build()
            // A new page starts in browse mode, as NVDA's new document does. Focus mode carried over from the page
            // before (Google's search box) kept the new page from being announced, and its keys went to the page
            // (a tester, 12 Oct 2026). A page that puts the focus in a field switches again by itself.
            if keepFocusMode {
                // The view taken as announced: leaving focus mode later does not read it from its top.
                Log.io("browse mode: a web app's view changed in focus mode; focus mode kept")
                announcedURL = now
                BrowseModeHandler.noteAnnounced(webArea, url: now)
            } else {
                if passThrough { Log.io("browse mode: a new page; focus mode from the last one ended") }
                passThrough = false; disableAutoPassThrough = false
                // The rest of what belonged to the page left: its letters turned off, the control the focus was last
                // on (a review, 13 Nov 2026).
                singleLetterNavigation = true; lastFocusElement = nil
            }
            selectionAnchor = nil
            // A mark of the page before found dead (read in the moment before this address came) is not a reload of
            // this one (a review, 14 Nov 2026).
            pageGone = nil
            // And the places kept for it: where it was before it emptied, a module's wish to enter it at its last
            // control, its line said instead of a say all. Left over, they placed or silenced the new page (a review,
            // 13 Nov 2026). A wish made in the last second, or while the page before was still empty (it never arrived:
            // about:blank to the message, or a message loading for longer), is for this arrival (Mail's Shift Tab, as
            // it moves on). startAtLastControl was cleared regardless, and a slow message lost the request too (a review,
            // 13 Nov 2026).
            let forThisArrival = { (at: Date) in wasEmpty || Date().timeIntervalSince(at) <= 1 }
            placeBeforeEmpty = nil; noAutoRead = false
            if startAtLastControl, !forThisArrival(startAtLastControlAt) { startAtLastControl = false }
            if let r = Self.lastControlRequest, r.area.isSame(webArea), !forThisArrival(r.at) { Self.lastControlRequest = nil }
            // Safari reuses one web area per tab: a page reached again by a link is a new arrival, read again; only
            // Back and Forward come back to one announced (a review, 13 Nov 2026).
            if !byHistory, !keepFocusMode { BrowseModeHandler.forgetAnnounced(webArea, url: now) }
        }
        let saved = byHistory ? BrowseModeHandler.shared.savedPosition(for: now) : nil
        let at = resumeOffset(saved)
        position = at
        Log.io("browse mode: page \(Log.words(BrowseModeHandler.shortURL(now))) — resuming at \(position)\(saved == nil ? "" : " (saved \(saved!.offset))")")
        if announce, !buffer.lines.isEmpty { announcePage() }
        else if !first, byKey, !buffer.lines.isEmpty { arrivedByKey() }
        GoogleDocs.checkSoon(self)
        if !first, buffer.lines.isEmpty, webArea.role != "AXWebArea" { followReplacedRoot(tries: 10) }
        return true
    }

    /// Whether `now` is the page at `last` with another anchor, or with its anchor added or gone: the same address
    /// before the "#". A fragment with "/" or "!" in it is a route, not an anchor: a web app's view (Gmail's #inbox to
    /// #inbox/FM…, app/#/a back to app/) is a new page, announced and read from its top; taken for the same page, the
    /// new view was neither (a review, 13 Nov 2026). Pure.
    package static func isSamePage(_ now: String, _ last: String) -> Bool {
        guard now != last, !now.isEmpty, !last.isEmpty, urlBase(now) == urlBase(last), now.contains("#") || last.contains("#") else { return false }
        return !isRoute(now) && !isRoute(last)
    }
    /// Whether `now` is another view of the web app at `last`: the same address before the "#", a route on either side.
    /// Pure.
    package static func isRouteChange(_ now: String, _ last: String) -> Bool {
        guard now != last, !now.isEmpty, !last.isEmpty, urlBase(now) == urlBase(last) else { return false }
        return isRoute(now) || isRoute(last)
    }
    /// The address's fragment is a web app's route (#/inbox, #!/a, #inbox/FM…). Pure.
    package static func isRoute(_ url: String) -> Bool {
        guard let hash = url.firstIndex(of: "#") else { return false }
        return url[url.index(after: hash)...].contains { $0 == "/" || $0 == "!" }
    }

    /// The address this page arrived at by Back or Forward, for the place it resumes at once it has loaded.
    var historyURL = ""
    /// The saved place to resume this page at: only a page come back to by Back or Forward has one.
    func historySaved() -> BrowseModeHandler.Saved? {
        historyURL == url && !url.isEmpty ? BrowseModeHandler.shared.savedPosition(for: url) : nil
    }

    /// Where a link to this page's anchor last took the reading, and when (followSamePageLink).
    var samePageLinkMove: (offset: Int, at: Date)?

    /// Where an element with this id (an anchor's target) begins: its line, or a line just inside it. Each element
    /// asked once (a wrapped paragraph's lines and a list's items share ancestors), and for a quarter of a second at
    /// most: on main, a long page asked up to twelve thousand questions (a review, 13 Nov 2026).
    func anchorOffset(_ id: String) -> Int? {
        let wanted = id.removingPercentEncoding ?? id
        let until = Date().addingTimeInterval(0.25)
        var timedOut = false
        let hit = Self.climbToMatch(buffer.lines.map(\.element), parent: { $0.element(kAXParentAttribute) },
                                    matches: { $0.string("AXDOMIdentifier") == wanted },
                                    stop: { if Date() > until { timedOut = true }; return timedOut })
        if timedOut { Log.io("browse mode: the anchor not found in the time") }
        return hit.map { buffer.lines[$0].start }
    }

    /// The first start (a line's element) that is, or has within three levels above it, an element that `matches`: its
    /// index. Each element is asked once, and remembered with the levels the climb still had above it then: a later
    /// climb stops at it only if it was asked with as many or more (those above it were asked too). Stopping at any
    /// element seen once missed ancestors when it had been the top of another line's climb: <div id=x><p>Some
    /// <a>link</a> more</p></div> (a review, 13 Nov 2026). At most 6000 elements, and `stop` asked before each start.
    /// Pure, for the tests.
    package static func climbToMatch<T: Hashable>(_ starts: [T?], parent: (T) -> T?, matches: (T) -> Bool, stop: () -> Bool = { false }) -> Int? {
        var asked: [T: Int] = [:]
        for (i, start) in starts.enumerated() {
            guard let e = start else { continue }
            if stop() { return nil }
            var x: T? = e
            for left in stride(from: 3, to: 0, by: -1) {
                guard let y = x, asked.count < 6000 else { break }
                let before = asked[y]
                if let before, before >= left { break }
                asked[y] = left
                if before == nil, matches(y) { return i }
                x = parent(y)
            }
        }
        return nil
    }

    /// A module's page emptied as it moved on (Kindle's sign-in steps: Continue empties the old frame and a new one
    /// comes a moment later): the window's new page is followed as soon as it is there, rather than at the next key
    /// (Tab after Tab was silent, and Tab bonked, until an arrow found it, 18 Oct 2026).
    func followReplacedRoot(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, API.focusTreeInterceptor === self, buffer.lines.isEmpty else { return }
            if buildIfEmpty() { return }
            if let fresh = currentWebArea(), !fresh.isSame(webArea) {
                Log.io("browse mode: the page moved on to another; following it")
                AXHandler.shared.focusChanged(fresh, pid: webArea.pid)
            } else if tries > 1 { followReplacedRoot(tries: tries - 1) }
        }
    }
    /// A module placed the reading itself as the page was entered (Mail's Shift Tab into a message, at its last
    /// control): no automatic say all from the top; the line there is said instead, once (placeOnArrival).
    public var noAutoRead = false
    /// The page was entered from below while still empty: when it arrives, the reading starts at its last control.
    public var startAtLastControl = false { didSet { if startAtLastControl { startAtLastControlAt = Date() } } }
    /// When startAtLastControl was last set, for a new page arriving just after (refreshIfNavigated).
    var startAtLastControlAt = Date.distantPast
    /// What Tab stops on in a page, for "its last control" (one set: Mail's Shift Tab too).
    public static let lastControlRoles: Set<String> = ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuButton", "AXDisclosureTriangle"]
    /// A web area about to be entered from below (Mail's Shift Tab into a message), asked before its document may
    /// exist: the document made for it, or found, starts at its last control.
    static var lastControlRequest: (area: AXUIElement, at: Date)?
    public static func enterAtLastControl(_ area: AXUIElement) { lastControlRequest = (area, Date()) }
    /// The page last announced (its title and its reading), so a page is announced once as it arrives.
    var announcedURL = ""

    /// The one place a page's arrival is placed by a module: at its last control if asked (startAtLastControl, or a
    /// request made before the document existed), which turns the say all from the top into its line. Used by every
    /// way a page is announced (the focus, its load, the watch for content): Mail's own placing ran after the
    /// announcement and said the line twice, and only one of those ways honoured the wish (a review, 13 Nov 2026).
    func placeOnArrival() {
        if let r = Self.lastControlRequest, r.area.isSame(webArea) {
            Self.lastControlRequest = nil
            if Date().timeIntervalSince(r.at) < 30 { startAtLastControl = true }
        }
        guard startAtLastControl, !buffer.lines.isEmpty else { return }
        startAtLastControl = false; noAutoRead = true
        position = buffer.find(from: buffer.text.length, forward: false, roles: Self.lastControlRoles)?.offset ?? position
    }

    /// NVDA: a page arriving says its title, then is read (automatic say all, on by default), or, with that off,
    /// its first line (or the line it resumes at).
    func announcePage() {
        placeOnArrival()
        announcedURL = url
        if noAutoRead {
            // Placed by a module: its line, once, not the page from the top (Mail's Shift Tab, 13 Nov 2026).
            noAutoRead = false
            BrowseModeHandler.noteAnnounced(webArea, url: url)
            Log.io("browse mode: the page was entered at a place set for it; its line is said")
            speakUnit(.line)
            return
        }
        if BrowseModeHandler.wasAnnounced(webArea, url: url), !reloadNoticed {
            Log.io("browse mode: back on a page announced before; its title and line are said, not a say all")
            let title = pageTitle()
            if !title.isEmpty { Speech.speakMessage(title) }
            if let info = makeTextInfo(.bookmark(Bookmark(start: position, end: position))) { info.expand(.line); speak(info, unit: .line) }
            return
        }
        BrowseModeHandler.noteAnnounced(webArea, url: url)
        let title = pageTitle()
        if !title.isEmpty { Speech.speakMessage(title) }
        if config.virtualBuffers.autoSayAllOnPageLoad {
            // Not a page the focus only passes through: Mail's message pane, on the way to the search field, had the
            // whole message read out (8 Oct 2026).
            // Nor over a key pressed in the moment before, or another page by then: the say all started over the key's
            // own answer (a review, 13 Nov 2026).
            let keyAt = InputManager.lastKeyDownAt, arrivedAt = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, API.focusTreeInterceptor === self, InputManager.lastKeyDownAt == keyAt, url == arrivedAt else { return }
                // A place asked for just after the announcement (the document made by the focus news it caused).
                placeOnArrival()
                if noAutoRead { noAutoRead = false; speakUnit(.line); return }
                SayAll.readText(from: rootObject)
            }
        } else if let info = makeTextInfo(.bookmark(Bookmark(start: position, end: position))) {
            info.expand(.line); speak(info, unit: .line)
            Hints.schedule(Hints.page)   // not over a say all: only when the page is not being read out
        }
    }

    func pageTitle() -> String {
        (webArea.string(kAXDescriptionAttribute) ?? webArea.element(kAXWindowAttribute)?.string(kAXTitleAttribute) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When a read of the page again found the copy's elements gone (`pageIsGone`), and the address then: the page was
    /// reloaded, if it is still at that address. Marked by any read that finds the copy dead, so also by a read in the
    /// moment before a new page's address arrives (Down while the next page loads, a press watch finishing as the page
    /// goes): by time alone, that page's AXLoadComplete was taken for a reload, its say all stopped and its title said
    /// twice, and Back to an announced page was read out whole (a review, 14 Nov 2026).
    var pageGone: (url: String, at: Date)?
    func markPageGone() { pageGone = (url, Date()) }
    /// A reload noticed in the last 30 s, at the address the page is at now.
    var reloadNoticed: Bool { Self.reloadMarkHolds(pageGone, url: url, now: Date()) }
    /// Whether a mark of the copy found dead (`pageGone`) means a reload of the page at `url`: made at that address, in
    /// the last 30 s. Pure, for the tests.
    package static func reloadMarkHolds(_ mark: (url: String, at: Date)?, url: String, now: Date) -> Bool {
        guard let mark, !url.isEmpty, mark.url == url else { return false }
        return now.timeIntervalSince(mark.at) < 30
    }

    /// The page finished loading at the same address (AXLoadComplete, from AXHandlerNotifications): read again keeping
    /// the place; and if it was a reload (Command R: the same address and web area, every element made anew), its title
    /// said, as a page arriving says it. A reload was silent, and the reading kept its old offset in the new copy
    /// (a review, 13 Nov 2026).
    public func pageLoadCompleted() {
        // A reload is told by the copy's elements gone, asked before anything is read again.
        if !buffer.lines.isEmpty, pageIsGone() { markPageGone() }
        guard reloadNoticed else {
            // Only changed: not read again under a say all of this page (its offsets would mean other text), nor more
            // often than a key may (a slow page held the main thread, a review, 13 Nov 2026). The next key reads it.
            if SayAll.isReading(self) || !mayRebuildNow() {
                buffer.isDirty = true
                // Its say all reads it again at its end (SayAll.finish), once: by this mark, not by isDirty, which every
                // layout, live region and frame sets, and which had nearly every say all read the page again for up to
                // 2 s before "end of document" (a review, 13 Nov 2026).
                if SayAll.isReading(self) { loadedUnderSayAll = SayAll.runID }
                Log.io("browse mode: page finished loading; read again at the next key")
                return
            }
            rebuildKeepingPlace()
            Log.io("browse mode: page finished loading; read again")
            return
        }
        // A reload: the copy a say all reads is of the page gone.
        if SayAll.isReading(self) { SayAll.stop() }
        rebuildKeepingPlace()
        sayReloaded()
    }

    /// The say all (SayAll.runID) under which the page finished loading, only marked (pageLoadCompleted): that say all
    /// reads the page again at its end, once, and clears this.
    var loadedUnderSayAll: Int?

    /// A reload noticed (pageGone): said by its title, as a page arriving says it.
    func sayReloaded() {
        pageGone = nil
        Log.io("browse mode: the page was reloaded; read again at \(position)")
        guard !passThrough else { return }
        let title = pageTitle()
        Speech.speakMessage(title.isEmpty ? String(localized: "page reloaded", comment: "Spoken message") : title)
    }

    /// Where to resume on a page: the place it was left, found by its line's text if the page came back rearranged
    /// (YouTube's recommendations), the occurrence nearest where it was.
    func resumeOffset(_ saved: BrowseModeHandler.Saved?) -> Int {
        var at = min(saved?.offset ?? 0, max(0, buffer.text.length - 1))
        if let saved, !saved.text.isEmpty, lineText(at: at) != saved.text {
            let matches = buffer.lines.filter { $0.end > $0.start && $0.end <= buffer.text.length &&
                String(buffer.text.substring(with: NSRange(location: $0.start, length: min($0.end - $0.start, 120)))) == saved.text }
            if let best = matches.min(by: { abs($0.start - saved.offset) < abs($1.start - saved.offset) }) { at = best.start }
        }
        return at
    }

    /// A page that was still empty when the document was made (a link just followed) has content now: read
    /// where it resumes, as NVDA reads a page once it has loaded, instead of leaving "document, blank" as the last word.
    @discardableResult
    public func loadedAfterBlank(announce: Bool) -> Bool {
        guard buffer.lines.isEmpty else { return false }
        buffer.build()
        guard !buffer.lines.isEmpty else { return false }
        let saved = historySaved()
        let kept = restorePlaceBeforeEmpty()
        if !kept { position = resumeOffset(saved) }
        placeOnArrival()   // entered from below before it had loaded (Mail's Shift Tab): its last control, not its top
        VoiceOverSounds.play("WebAreaLoaded.aiff")   // VoiceOver's "web area loaded", the sound its list has for a page
        Log.io("browse mode: page arrived — resuming at \(position)\(kept ? " (where it was before it emptied)" : saved == nil ? "" : " (saved \(saved!.offset))")")
        if announce, url != announcedURL { announcePage(); return true }
        if kept, announce, reloadNoticed { sayReloaded() }   // a reload read mid-way: said, not silent
        // Not announced here: the line-instead-of-say-all placeOnArrival may have set was for this arrival only; left
        // set, it silenced the say all of a later page (a review, 13 Nov 2026).
        noAutoRead = false
        return true
    }

    /// The place the reading had when a read of the page came back empty (read in the middle of a reload), at the
    /// address it was on: kept for the page coming back, rather than the top. The empty read put the reading at 0 and
    /// the page came back at its top, silently (a review, 13 Nov 2026).
    var placeBeforeEmpty: (url: String, line: String, into: Int, offset: Int)?
    /// An empty copy read again, and if that brought the page, the reading put back where it was before it emptied.
    /// True if the copy has content now. Every read of an empty copy goes through here: Tab's, the focus's and the
    /// replaced page's read bypassed the restore and left the reading at the top (a review, 13 Nov 2026).
    @discardableResult
    func buildIfEmpty() -> Bool {
        guard buffer.lines.isEmpty else { return true }
        buffer.build()
        guard !buffer.lines.isEmpty else { return false }
        restorePlaceBeforeEmpty()
        return true
    }

    /// A key's own read brought the page ("loading page", then an arrow, a letter or Tab): the key reads there, so the
    /// page is taken as announced and the watch for its content ends, as a new page found by a key is
    /// (refreshIfNavigated). The watch's next look announced it over the key's answer, its title and a say all
    /// (a review, 13 Nov 2026).
    func arrivedByKey() {
        let now = url
        guard !now.isEmpty else { return }
        announcedURL = now
        BrowseModeHandler.noteAnnounced(webArea, url: now)
        watchingFor = ""
        // Placed as every arrival is: entered from below while empty (Mail's Shift Tab), at its last control, before the
        // key reads. The key says its own line, so no line-instead-of-say-all is kept (a review, 13 Nov 2026).
        placeOnArrival()
        // Placed at its last control by the wish: that control is said, and the key that brought the page doesn't move
        // on past it (Down went past it, Shift Tab to the one before: the last control was never heard, a review).
        if noAutoRead { placedByArrival = Date() }
        noAutoRead = false
    }
    /// The key that brought the page found the reading placed for it (arrivedByKey): it says that line and stops.
    /// (Only for that key: a moment, then it is gone, so a later key never stops on it.)
    var placedByArrival: Date?
    func takePlacedByArrival() -> Bool {
        guard let at = placedByArrival else { return false }
        placedByArrival = nil
        guard Date().timeIntervalSince(at) < 1 else { return false }
        speakUnit(.line)
        return true
    }

    /// The page has content again at the same address: the reading back where it was before it emptied. True if so.
    @discardableResult
    func restorePlaceBeforeEmpty() -> Bool {
        guard let k = placeBeforeEmpty, !buffer.lines.isEmpty else { return false }
        placeBeforeEmpty = nil
        guard k.url == url else { return false }
        position = Self.placeAfterRebuild(oldLine: k.line, into: k.into, oldPosition: k.offset, in: buffer.text)
        return true
    }

    /// NVDA's passThrough: true is focus mode (keys go to the application).
    public var passThrough = false
    /// NVDA+Shift+Space: single-letter navigation on or off for this page (off: the letters go to the page).
    public var singleLetterNavigation = true
    public var disableAutoPassThrough = false
    var lastQuickNavTarget: AXUIElement?
    static let controlRoles: Set<String> = ["AXTextField", "AXTextArea", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXIncrementor", "AXMenuButton", "AXLink"]
    /// The containers the last reading was inside (NVDA: the control field stack between reads).
    var lastChain: [AXUIElement] = []

    func speak(_ info: TextInfo, unit: TextUnit) {
        if let w = info as? WebTextInfo { w.previousChain = lastChain }
        // (Measured from the last reading of this page only: a say all since has moved on, and its "out of" were said.)
        if let b = info as? BufferTextInfo { b.previousChain = lastChain; b.previousOffset = SayAll.endedSince(lastSpokenAt) ? nil : lastSpokenOffset }
        Speech.speakTextInfo(info, unit: unit, reason: .caret)
        if let w = info as? WebTextInfo { lastChain = w.chain }
        if let b = info as? BufferTextInfo { lastChain = b.chain; lastSpokenOffset = b.start; lastSpokenAt = Date(); followProgress(in: b) }
    }
    var lastSpokenAt = Date.distantPast
    /// Where the last reading began: the cell and containers the next move is measured from.
    var lastSpokenOffset: Int?

    /// A move that said its own words at `offset` (a table cell, by the table keys): taken as the last reading, so the
    /// next arrow's row, column and "out of" news start from it.
    func noteRead(at offset: Int) {
        lastSpokenOffset = offset; lastSpokenAt = Date()
        lastChain = buffer.lineIndex(at: offset).map { buffer.lines[$0].entering } ?? []
    }

    /// A progress bar read on the page is followed as it moves (ProgressWatch), as one the focus reads is. Known by its
    /// line's role, so the lines read ask the page nothing. (Say all reads by its own path, so a bar it passes isn't.)
    private func followProgress(in info: BufferTextInfo) {
        guard var i = buffer.lineIndex(at: info.start) else { return }
        while i < buffer.lines.count, buffer.lines[i].start < max(info.end, info.start + 1) {
            let line = buffer.lines[i]
            if line.isControl, line.fields.first == Role.progressBar.displayString, let e = line.element { ProgressWatch.watch(ObjectFactory.make(e)) }
            i += 1
        }
    }

    init(webArea: AXUIElement) {
        self.webArea = webArea
        bridge = WebDocumentBridge(webArea: webArea)
        buffer = WebBuffer(webArea: webArea)
        super.init()
        buffer.build()
        refreshIfNavigated()
        let nav = "Browse mode"
        // NVDA's cursor manager, on Mac modifiers.
        script("moveByLine_back", String(localized: "Moves to the previous line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:upArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.line, -1) }
        script("moveByLine_forward", String(localized: "Moves to the next line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:downArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.line, 1) }
        script("moveByCharacter_back", String(localized: "Moves to the previous character", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:leftArrow"], category: nav) { [weak self] _ in guard let self else { return }; move(.character, -1) }
        script("moveByCharacter_forward", String(localized: "Moves to the next character", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:rightArrow"], category: nav) { [weak self] _ in guard let self else { return }; move(.character, 1) }
        script("moveByWord_back", String(localized: "Moves to the previous word", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+leftArrow"], category: nav) { [weak self] _ in guard let self else { return }; move(.word, -1) }
        script("moveByWord_forward", String(localized: "Moves to the next word", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+rightArrow"], category: nav) { [weak self] _ in guard let self else { return }; move(.word, 1) }
        // The Windows style adds NVDA's Control Up and Down for paragraphs (a tester, 14 Oct 2026); the Mac style
        // keeps VoiceOver's Option arrows only.
        script("moveByParagraph_back", String(localized: "Moves to the previous paragraph", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+upArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.paragraph, -1) }
        script("moveByParagraph_forward", String(localized: "Moves to the next paragraph", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+downArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.paragraph, 1) }
        // (Bound always and gated by the style at each press, as the letters are: bound once at the document's
        // creation, a style switch left every open page with the old keys. code review, 16 Oct 2026.)
        script("moveByParagraph_back_nvda", String(localized: "Moves to the previous paragraph (NVDA's Control Up)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:control+upArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.paragraph, -1) }
            .isAvailable = { config.general.windowsKeys }
        script("moveByParagraph_forward_nvda", String(localized: "Moves to the next paragraph (NVDA's Control Down)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:control+downArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.paragraph, 1) }
            .isAvailable = { config.general.windowsKeys }
        script("moveByPage_back", String(localized: "Moves up a page", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:pageUp"], category: nav) { [weak self] _ in guard let self else { return }; move(.line, -20) }
        script("moveByPage_forward", String(localized: "Moves down a page", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:pageDown"], category: nav) { [weak self] _ in guard let self else { return }; move(.line, 20) }
        script("startOfLine", String(localized: "Moves to the start of the line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:home", "kb:command+leftArrow"], category: nav) { [weak self] _ in guard let self else { return }; edgeOfLine(start: true) }
        script("endOfLine", String(localized: "Moves to the end of the line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:end", "kb:command+rightArrow"], category: nav) { [weak self] _ in guard let self else { return }; edgeOfLine(start: false) }
        let sel = "Selecting"
        script("selectCharacter_back", String(localized: "Selects the previous character", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+leftArrow"], category: sel) { [weak self] _ in self?.select(.character, -1) }
        script("selectCharacter_forward", String(localized: "Selects the next character", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+rightArrow"], category: sel) { [weak self] _ in self?.select(.character, 1) }
        script("selectWord_back", String(localized: "Selects the previous word", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+option+leftArrow"], category: sel) { [weak self] _ in self?.select(.word, -1) }
        script("selectWord_forward", String(localized: "Selects the next word", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+option+rightArrow"], category: sel) { [weak self] _ in self?.select(.word, 1) }
        script("selectLine_back", String(localized: "Selects up a line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+upArrow"], category: sel) { [weak self] _ in self?.select(.line, -1) }
        script("selectLine_forward", String(localized: "Selects down a line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+downArrow"], category: sel) { [weak self] _ in self?.select(.line, 1) }
        // Paragraphs too (a tester, : Shift Option Down selected nothing that was said). Windows's Control Shift
        // Down is the same in the Windows style.
        script("selectParagraph_back", String(localized: "Selects up a paragraph", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+option+upArrow", "kb:shift+control+upArrow"], category: sel) { [weak self] _ in self?.select(.paragraph, -1) }
        script("selectParagraph_forward", String(localized: "Selects down a paragraph", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+option+downArrow", "kb:shift+control+downArrow"], category: sel) { [weak self] _ in self?.select(.paragraph, 1) }
        script("selectToLineStart", String(localized: "Selects to the start of the line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+home", "kb:shift+command+leftArrow"], category: sel) { [weak self] _ in
            guard let self, let info = caretInfo() else { return }; info.expand(.line); select(nil, 0, to: info.start)
        }
        script("selectToLineEnd", String(localized: "Selects to the end of the line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+end", "kb:shift+command+rightArrow"], category: sel) { [weak self] _ in
            guard let self, let info = caretInfo() else { return }; info.expand(.line); select(nil, 0, to: info.end)
        }
        script("selectToTop", String(localized: "Selects to the top of the document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+command+upArrow", "kb:shift+control+home"], category: sel) { [weak self] _ in self?.select(nil, 0, to: 0) }
        script("selectToBottom", String(localized: "Selects to the bottom of the document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+command+downArrow", "kb:shift+control+end"], category: sel) { [weak self] _ in
            guard let self else { return }; select(nil, 0, to: buffer.text.length)
        }
        script("selectAll", String(localized: "Selects the whole document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+a"], category: sel) { [weak self] _ in
            guard let self else { return }
            selectionAnchor = 0; position = buffer.text.length
            Speech.speakMessage(String(localized: "all selected", comment: "Spoken message"), remember: false)
        }
        script("copySelection", String(localized: "Copies what is selected in the document; with nothing selected, the application's own copy", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+c"], category: sel) { [weak self] g in
            self?.copySelection(g)
        }
        script("topOfDocument", String(localized: "Moves to the top of the document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+upArrow", "kb:control+home"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; position = 0; speakUnit(.line) }
        script("bottomOfDocument", String(localized: "Moves to the bottom of the document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+downArrow", "kb:control+end"], category: nav) { [weak self] _ in guard let self else { return }; toBottom() }
        script("activatePosition", String(localized: "Activates the element at the caret", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:numpadEnter", "kb:space"], category: nav) { [weak self] g in guard let self else { return }; activate(g) }
        // NVDA+F7 in the Windows style (the parity audit, 13 Oct 2026: it did nothing on a page); in the Mac style
        // VO-F7 stays VoiceOver's, and VO-U and VO-I reach this list.
        let elements = script("elementsList", String(localized: "Elements list; lists the page's headings, links, form fields, buttons and landmarks; Enter goes there (NVDA+F7, VoiceOver's Item Chooser)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+f7"], category: nav) { [weak self] _ in
            self?.elementsList()
        }
        elements.isAvailable = { [weak self] in config.general.windowsKeys && self?.passThrough == false }
        script("tabFromCaret", String(localized: "Next link or control; moves to the next link or control after the reading position (Shift: before it)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab", "kb:shift+tab"], category: nav) { [weak self] g in
            guard let self else { return }
            BrowseModeDocument.lastTabFromCaretAt = Date()
            // The copy of the page now, as the arrows have it: Tab just after a link was followed searched the copy of
            // the page left (a review, 13 Nov 2026).
            refreshIfNavigated()
            if buffer.lines.isEmpty, buildIfEmpty() { arrivedByKey(); if takePlacedByArrival() { return } }
            rebuildIfCheap()
            // From a field of a Safari page in focus mode (tabIsTurnOversInField): on from the field. Another field
            // takes the focus; a check box, button or link can't in Safari, so the reading position goes there and
            // browse mode comes back (Space and Return press it there).
            if passThrough, tabIsTurnOversInField, let f = API.focusObject, let from = buffer.offset(of: f.element) {
                let roles: Set<String> = ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuButton", "AXDisclosureTriangle"]
                guard let (at, el) = buffer.find(from: from, forward: !g.modifiers.contains(.shift), roles: roles) else { Tones.edge(); return }
                if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(el.role), el.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
                    Log.io("browse mode: Tab from a field to the next field at \(at)")
                    position = at; positionAtFocus = at; return
                }
                Log.io("browse mode: Tab from a field to \(el.role) at \(at): the reading position goes there")
                setPassThrough(false, announce: true)
                position = at
                speakUnit(.line)
                return
            }
            let movesReading = AppModuleHandler.shared.appModule(for: webArea.pid).browseTabMovesReadingPosition
            // (Not for an app whose controls take no focus: Shortcuts' button took the request and said nothing.)
            if !movesReading, focusFromCaret(forward: !g.modifiers.contains(.shift)) { return }
            if movesReading {
                guard ensureContent() else { return }
                let roles: Set<String> = ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider"]
                // Past the control the reading is on, its own further lines too: a field of several lines ("Describe
                // a change" in Shortcuts) was found again on each, empty, and eight Tabs said nothing (13 Nov 2026).
                var here = buffer.segment(at: position)?.element ?? buffer.lineIndex(at: position).flatMap { buffer.lines[$0].element }
                for _ in 0..<6 { guard let h = here, !roles.contains(h.role) else { break }; here = h.element(kAXParentAttribute) }
                if let h = here, !roles.contains(h.role) { here = nil }   // the reading is on no control: nothing to skip
                let forward = !g.modifiers.contains(.shift)
                var from = position, found: Int?
                for _ in 0..<1000 {   // (a field of many lines is passed whole: a review, 13 Nov 2026)
                    guard let (at, el) = buffer.find(from: from, forward: forward, roles: roles) else { break }
                    if let here, Self.within(el, here) { from = at; continue }
                    found = at; break
                }
                // Past the last control: round to the first, after the edge sound, as the app's own Tab does nothing
                // (Shortcuts: eight Tabs of edge sounds after its last field, 13 Nov 2026).
                if found == nil, let (at, _) = buffer.find(from: forward ? -1 : buffer.text.length, forward: forward, roles: roles) {
                    Tones.edge(); found = at
                }
                if let found { position = found; speakUnit(.line) } else { Tones.edge() }
                return
            }
            if AppModuleHandler.shared.appModule(for: webArea.pid).tabPastPage(webArea, forward: !g.modifiers.contains(.shift)) { return }
            g.send(); PageWatch.keySent(to: webArea.pid)
        }
        script("disablePassThrough", String(localized: "Switches back to browse mode", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: nav) { [weak self] g in
            guard let self else { return }
            // Inside a web dialog or application, Escape is the page's: NVDA keeps such places in focus mode. 1Password's
            // Quick Access, a dialog from end to end, never closed on Escape, and its next shortcut closed it rather
            // than opening it (a tester, 12 Nov 2026).
            if passThrough, let f = API.focusObject, Self.inWebDialog(f.element) {
                g.send()
                // Said once a page, the first time: with Escape the page's, nothing said how browse mode comes back
                // (a review, 13 Nov 2026).
                if escapeHintURL != url {
                    escapeHintURL = url
                    let words = Self.backToBrowseModeHint(keyName: config.general.turnOverKeyName, windowsKeys: config.general.windowsKeys)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self, API.focusTreeInterceptor === self else { return }
                        Speech.speakMessage(words)
                    }
                }
                return
            }
            if passThrough {
                // The virtual caret goes to the control that had focus (NVDA): on a page that was still arriving when
                // the field took focus, the field was not in the buffer yet and the caret stayed at the top.
                if let f = API.focusObject, f.pid == webArea.pid, !f.isSameElement(as: webArea) {
                    if let at = offsetReadingOnOrAgain(f.element) { position = at }
                }
                disableAutoPassThrough = false   // Escape ends the by-hand choice too: the next field switches by itself again
                setPassThrough(false, announce: true)
            } else { g.send() }
        }
        // NVDA's quick navigation keys. Shift goes backwards.
        // Each style its own reader's letters: NVDA's in the Windows style, VoiceOver's in the Mac style. A letter the
        // style's reader doesn't use goes to the page. NVDA+Shift+Space turns them off for a page (singleLetterNavigation).
        for (table, windows) in [(BrowseModeDocument.quickNav, true), (BrowseModeDocument.voiceOverQuickNav, false)] {
            let prefix = windows ? "" : "vo_"
            for q in table {
                let next = script("\(prefix)next\(q.name)", String(localized: "Moves to the next \(q.spoken)", comment: "A command: %@ is a kind of thing to find (heading)"), gestures: ["kb:\(q.key)"], category: "Quick navigation") { [weak self] g in
                    guard let self else { return }
                    if !singleLetterNavigation { g.send(); return }
                    quickNav(q, forward: true)
                }
                let previous = script("\(prefix)previous\(q.name)", String(localized: "Moves to the previous \(q.spoken)", comment: "A command: %@ is a kind of thing to find (heading)"), gestures: ["kb:shift+\(q.key)"], category: "Quick navigation") { [weak self] g in
                    guard let self else { return }
                    if !singleLetterNavigation { g.send(); return }
                    quickNav(q, forward: false)
                }
                next.isAvailable = { config.general.windowsKeys == windows }
                previous.isAvailable = { config.general.windowsKeys == windows }
            }
        }
        // NVDA's; VoiceOver has none, so the Mac style leaves comma to the page.
        script("pastEndOfContainer", String(localized: "Moves past the end of the list, table or other container (NVDA: comma)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:,"], category: "Quick navigation") { [weak self] g in
            guard let self else { return }
            if !singleLetterNavigation { g.send(); return }
            moveToContainerEdge(end: true)
        }.isAvailable = { config.general.windowsKeys }
        script("startOfContainer", String(localized: "Moves to the start of the list, table or other container (NVDA: Shift comma)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+,"], category: "Quick navigation") { [weak self] g in
            guard let self else { return }
            if !singleLetterNavigation { g.send(); return }
            moveToContainerEdge(end: false)
        }.isAvailable = { config.general.windowsKeys }
    }

    /// The page Escape in a web dialog last said how to get back to browse mode on (once a page).
    var escapeHintURL = ""
    /// How to get back to browse mode, in the keyboard style's words: NVDA's TurnOver Space, VoiceOver's VO-Q.
    package static func backToBrowseModeHint(keyName: String, windowsKeys: Bool) -> String {
        let keys = windowsKeys ? "\(keyName) Space" : "\(keyName) Q"
        return String(localized: "\(keys) returns to browse mode", comment: "Said once a page, when Escape in a web dialog in focus mode goes to the page: %@ is the key")
    }

    public struct QuickNavType { public let name: String; public let key: String; public let spoken: String; let searchKey: String; let roles: Set<String>? }
    public static let quickNav: [QuickNavType] = [
        .init(name: "Heading", key: "h", spoken: String(localized: "heading", comment: "A kind of thing to find, after next or previous"), searchKey: "AXHeadingSearchKey", roles: nil),
        .init(name: "Heading1", key: "1", spoken: Phrases.headingLevel(1), searchKey: "AXHeadingLevel1SearchKey", roles: nil),
        .init(name: "Heading2", key: "2", spoken: Phrases.headingLevel(2), searchKey: "AXHeadingLevel2SearchKey", roles: nil),
        .init(name: "Heading3", key: "3", spoken: Phrases.headingLevel(3), searchKey: "AXHeadingLevel3SearchKey", roles: nil),
        .init(name: "Heading4", key: "4", spoken: Phrases.headingLevel(4), searchKey: "AXHeadingLevel4SearchKey", roles: nil),
        .init(name: "Heading5", key: "5", spoken: Phrases.headingLevel(5), searchKey: "AXHeadingLevel5SearchKey", roles: nil),
        .init(name: "Heading6", key: "6", spoken: Phrases.headingLevel(6), searchKey: "AXHeadingLevel6SearchKey", roles: nil),
        .init(name: "Heading7", key: "7", spoken: Phrases.headingLevel(7), searchKey: "", roles: nil),
        .init(name: "Heading8", key: "8", spoken: Phrases.headingLevel(8), searchKey: "", roles: nil),
        .init(name: "Heading9", key: "9", spoken: Phrases.headingLevel(9), searchKey: "", roles: nil),
        .init(name: "Link", key: "k", spoken: String(localized: "link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXLinkSearchKey", roles: nil),
        .init(name: "VisitedLink", key: "v", spoken: String(localized: "visited link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXVisitedLinkSearchKey", roles: nil),
        .init(name: "UnvisitedLink", key: "u", spoken: String(localized: "unvisited link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXUnvisitedLinkSearchKey", roles: nil),
        .init(name: "FormField", key: "f", spoken: String(localized: "form field", comment: "A kind of thing to find, after next or previous"), searchKey: "AXControlSearchKey", roles: nil),
        .init(name: "List", key: "l", spoken: String(localized: "list", comment: "A kind of thing to find, after next or previous"), searchKey: "AXListSearchKey", roles: nil),
        .init(name: "Button", key: "b", spoken: String(localized: "button", comment: "A kind of thing to find, after next or previous"), searchKey: "AXButtonSearchKey", roles: nil),
        .init(name: "Edit", key: "e", spoken: String(localized: "edit field", comment: "A kind of thing to find, after next or previous"), searchKey: "AXTextFieldSearchKey", roles: nil),
        .init(name: "Frame", key: "m", spoken: String(localized: "frame", comment: "A kind of thing to find, after next or previous"), searchKey: "AXFrameSearchKey", roles: nil),
        .init(name: "RadioButton", key: "r", spoken: String(localized: "radio button", comment: "A kind of thing to find, after next or previous"), searchKey: "AXRadioGroupSearchKey", roles: nil),
        .init(name: "ComboBox", key: "c", spoken: String(localized: "combo box", comment: "A kind of thing to find, after next or previous"), searchKey: "AXControlSearchKey", roles: ["AXPopUpButton", "AXComboBox"]),
        .init(name: "CheckBox", key: "x", spoken: String(localized: "check box", comment: "A kind of thing to find, after next or previous"), searchKey: "AXCheckBoxSearchKey", roles: nil),
        .init(name: "Graphic", key: "g", spoken: String(localized: "graphic", comment: "A kind of thing to find, after next or previous"), searchKey: "AXGraphicSearchKey", roles: nil),
        .init(name: "BlockQuote", key: "q", spoken: String(localized: "block quote", comment: "A kind of thing to find, after next or previous"), searchKey: "AXBlockquoteSearchKey", roles: nil),
        .init(name: "Landmark", key: "d", spoken: String(localized: "landmark", comment: "A kind of thing to find, after next or previous"), searchKey: "AXLandmarkSearchKey", roles: nil),
        .init(name: "Table", key: "t", spoken: String(localized: "table", comment: "A kind of thing to find, after next or previous"), searchKey: "AXTableSearchKey", roles: nil),
        .init(name: "Annotation", key: "a", spoken: String(localized: "annotation", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "SpellingError", key: "w", spoken: String(localized: "spelling error", comment: "A kind of thing to find, after next or previous"), searchKey: "AXMisspelledWordSearchKey", roles: nil),
        // Text kinds: no WebKit search key; found in the buffer (BrowseModeDocument.quickNav).
        .init(name: "Paragraph", key: "p", spoken: String(localized: "paragraph", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "NotLinkBlock", key: "n", spoken: String(localized: "text after links", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "ListItem", key: "i", spoken: String(localized: "list item", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "Separator", key: "s", spoken: String(localized: "separator", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "EmbeddedObject", key: "o", spoken: String(localized: "embedded object", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
    ]

    /// The Mac style's letters: VoiceOver's own single-key Quick Nav, as its defaults on the Mac set them
    /// (ScreenReaderConfiguration, SCRQuickNavSingleLetterCommander; the parity audit, 13 Oct 2026). "mac keys
    /// should do what voiceover keys are expected to do, and windows mode should do what NVDA keys are expected to do."
    public static let voiceOverQuickNav: [QuickNavType] = [
        .init(name: "Heading", key: "h", spoken: String(localized: "heading", comment: "A kind of thing to find, after next or previous"), searchKey: "AXHeadingSearchKey", roles: nil),
        .init(name: "Heading1", key: "1", spoken: Phrases.headingLevel(1), searchKey: "AXHeadingLevel1SearchKey", roles: nil),
        .init(name: "Heading2", key: "2", spoken: Phrases.headingLevel(2), searchKey: "AXHeadingLevel2SearchKey", roles: nil),
        .init(name: "Heading3", key: "3", spoken: Phrases.headingLevel(3), searchKey: "AXHeadingLevel3SearchKey", roles: nil),
        .init(name: "Heading4", key: "4", spoken: Phrases.headingLevel(4), searchKey: "AXHeadingLevel4SearchKey", roles: nil),
        .init(name: "Heading5", key: "5", spoken: Phrases.headingLevel(5), searchKey: "AXHeadingLevel5SearchKey", roles: nil),
        .init(name: "Heading6", key: "6", spoken: Phrases.headingLevel(6), searchKey: "AXHeadingLevel6SearchKey", roles: nil),
        .init(name: "SameLevelHeading", key: "m", spoken: String(localized: "heading at the same level", comment: "A kind of thing to find, after next or previous"), searchKey: "AXHeadingSameLevelSearchKey", roles: nil),
        .init(name: "Link", key: "l", spoken: String(localized: "link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXLinkSearchKey", roles: nil),
        .init(name: "VisitedLink", key: "v", spoken: String(localized: "visited link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXVisitedLinkSearchKey", roles: nil),
        .init(name: "TextField", key: "f", spoken: String(localized: "text field", comment: "A kind of thing to find, after next or previous"), searchKey: "AXTextFieldSearchKey", roles: nil),
        .init(name: "Control", key: "j", spoken: String(localized: "control", comment: "A kind of thing to find, after next or previous"), searchKey: "AXControlSearchKey", roles: nil),
        .init(name: "List", key: "x", spoken: String(localized: "list", comment: "A kind of thing to find, after next or previous"), searchKey: "AXListSearchKey", roles: nil),
        .init(name: "Button", key: "b", spoken: String(localized: "button", comment: "A kind of thing to find, after next or previous"), searchKey: "AXButtonSearchKey", roles: nil),
        .init(name: "Table", key: "t", spoken: String(localized: "table", comment: "A kind of thing to find, after next or previous"), searchKey: "AXTableSearchKey", roles: nil),
        .init(name: "Graphic", key: "g", spoken: String(localized: "graphic", comment: "A kind of thing to find, after next or previous"), searchKey: "AXGraphicSearchKey", roles: nil),
        .init(name: "Landmark", key: "n", spoken: String(localized: "landmark", comment: "A kind of thing to find, after next or previous"), searchKey: "AXLandmarkSearchKey", roles: nil),
        .init(name: "CheckBox", key: "c", spoken: String(localized: "check box", comment: "A kind of thing to find, after next or previous"), searchKey: "AXCheckBoxSearchKey", roles: nil),
        .init(name: "RadioGroup", key: "r", spoken: String(localized: "radio group", comment: "A kind of thing to find, after next or previous"), searchKey: "AXRadioGroupSearchKey", roles: nil),
        .init(name: "DifferentItem", key: "d", spoken: String(localized: "different item", comment: "A kind of thing to find, after next or previous"), searchKey: "AXDifferentTypeSearchKey", roles: nil),
    ]

    // MARK: The document object and its text

    /// A fresh object for the root, so TextInfos read the live page (any root: a web area, or a content pane).
    public var rootObject: WebArea { WebArea(element: webArea) }
    public func makeTextInfo(_ p: TextPosition) -> TextInfo? { try? rootObject.makeTextInfo(p) }
    public var isAlive: Bool { webArea.role != "?" }

    func caretInfo() -> TextInfo? { makeTextInfo(.caret) }

    func speakUnit(_ unit: TextUnit) {
        guard let info = caretInfo() else { return }
        info.expand(unit)
        speak(info, unit: unit)
    }

    /// Find (NVDA's browse-mode find, VoiceOver's VO-F): the next or previous match from the reading position,
    /// ignoring case; the reading position goes there and the line is read. False when there is none.
    public func find(_ s: String, forward: Bool) -> Bool {
        refreshIfNavigated()
        clearSelection()
        guard buffer.text.length > 0, !s.isEmpty else { return false }
        func search() -> NSRange? {
            let text = buffer.text, n = text.length
            let from = min(position + 1, n)
            let r = forward
                ? text.range(of: s, options: .caseInsensitive, range: NSRange(location: from, length: n - from))
                : text.range(of: s, options: [.caseInsensitive, .backwards], range: NSRange(location: 0, length: min(position, n)))
            return r.location == NSNotFound ? nil : r
        }
        var hit = search()
        // Nothing ahead in a page read only in part (a long chat): read on, as the letters do, before "not found"; the
        // match past the part read was never found (a review, 13 Nov 2026).
        if hit == nil, forward, buffer.isPartial, buffer.canReadOn { hit = readingOn { search() } }
        guard let r = hit else { return false }
        position = r.location
        guard let info = makeTextInfo(.bookmark(Bookmark(start: r.location, end: r.location))) else { return true }
        info.expand(.line)
        speak(info, unit: .line)
        return true
    }

    /// The copy of the page is empty (read while it was still loading, or while Safari was not answering): look
    /// again now, and keep looking for half a minute, reading the page when it comes. A tester's report (6 Oct
    /// 2026): after a reload the copy stayed empty and every arrow said "bottom" or "top", then "blank".
    @discardableResult
    /// `e` is `c` or inside it (a few levels up).
    static func within(_ e: AXUIElement, _ c: AXUIElement) -> Bool {
        var x: AXUIElement? = e, hops = 0
        while let y = x, hops < 6 { if y.isSame(c) { return true }; x = y.element(kAXParentAttribute); hops += 1 }
        return false
    }

    func ensureContent() -> Bool {
        // An empty address too: Safari not answering reports none (6 Oct 2026, playtestcloud: "page  —", 0 lines,
        // and every key said "no next heading").
        guard buffer.lines.isEmpty, url != "about:blank" else { return true }
        if buildIfEmpty() { Log.io("browse mode: the page has arrived"); arrivedByKey(); return true }
        // Safari can swap in a new web area on a reload (6 Oct 2026, fast.com: after Command R the copy was
        // of the old one, one element and no address, while the page was there and Tab reached it). The window's
        // web area now, if it is another one, is the page: move there, as Tab did.
        if let fresh = currentWebArea(), !fresh.isSame(webArea) {
            Log.io("browse mode: this web area was replaced (a reload); moving to the window's current one")
            let pid = webArea.pid
            DispatchQueue.main.async { AXHandler.shared.focusChanged(fresh, pid: pid) }
            return false
        }
        Speech.speakMessage(String(localized: "nothing on this page yet; it may still be loading", comment: "Spoken message"))
        watchForContent()
        return false
    }

    /// The web area in the focused window of this document's application now (nil if there is none).
    func currentWebArea() -> AXUIElement? {
        let app = AXUIElementCreateApplication(webArea.pid)
        guard let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) else { return nil }
        return window.firstDescendant(role: "AXWebArea", maxVisited: 400) ?? AppModuleHandler.shared.appModule(for: webArea.pid).browseRoot(inWindow: window)
    }

    var watchingFor = ""
    /// Look again every second for 30 s while the copy is empty; when the page comes, say so and read it.
    func watchForContent() {
        let waiting = url
        guard watchingFor != waiting else { return }
        watchingFor = waiting
        func look(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, url == waiting, watchingFor == waiting else { return }
                if buffer.lines.isEmpty { buffer.build() }
                if buffer.lines.isEmpty, API.focusTreeInterceptor === self, let fresh = currentWebArea(), !fresh.isSame(webArea) {
                    watchingFor = ""
                    Log.io("browse mode: this web area was replaced while waiting; moving to the window's current one")
                    AXHandler.shared.focusChanged(fresh, pid: webArea.pid)
                    return
                }
                if !buffer.lines.isEmpty {
                    watchingFor = ""
                    let kept = restorePlaceBeforeEmpty()
                    // Once: AXLoadComplete may have announced it already (the title was said twice, 12 Oct 2026).
                    guard url != announcedURL else { Log.io("browse mode: the page arrived after \(n + 1) s (already announced)"); return }
                    Log.io("browse mode: the page arrived after \(n + 1) s")
                    if API.focusTreeInterceptor === self, !passThrough { if !kept { position = resumeOffset(historySaved()) }; announcePage() }
                    return
                }
                if n < 29 { look(n + 1) } else { watchingFor = ""; Log.io("browse mode: still nothing on the page after 30 s") }
            }
        }
        look(0)
    }

    /// One rule for the arrows, the letters and the container keys (code review, 16 Oct 2026, item 28: the letters
    /// rebuilt on any dirty flag, up to 2 s on main): a dirty page is rebuilt when the last build was cheap, and a
    /// page older than `stale` seconds is rebuilt whatever it cost.
    func rebuildIfCheap(stale: TimeInterval? = nil) {
        let age = Date().timeIntervalSince(buffer.builtAt)
        // Not for its age a page read on past its first part (a long chat, issue 227): read again from the top, it
        // could take two seconds a key and still not get back to the reader. Its end is read on instead.
        // (Keeping the place: a bare read and a clamp left the reading position at its old offset, in other text.)
        if let stale, age > stale, buffer.passes == 1 { rebuildKeepingPlace(); return }
        // A page that said it changed is read again even when its last read was slow, at most every 1.5 s: only cheap
        // pages were, so on real sites an accordion opened, results that came, a dialog closed never reached the
        // arrows (a review, 13 Nov 2026).
        if buffer.isDirty, Self.mayRebuild(lastBuildMs: buffer.lastBuildMs, age: age, cheapAfter: 1) { rebuildKeepingPlace(); return }
        // A control pressed a moment ago and still watched (up to 3 s): what it showed may not have been said by the
        // browser yet. "Show more" pressed, then Down, read past the text it added (13 Nov 2026). Once per press in this
        // page (takeUnreadWatches), not on every key while any press anywhere is watched (a review, 13 Nov 2026).
        if buffer.lastBuildMs < 250, age > 0.2, takeUnreadWatches() { rebuildKeepingPlace() }
    }

    /// Whether a key may read the whole page again now: a page cheap to read (under 250 ms) after `cheapAfter`
    /// seconds, any other only once its last read is 1.5 s old, so a slow page is never read again on every key
    /// (each read up to 2 s on the main thread, where the watchdog trips at 4; a review, 13 Nov 2026). Pure.
    package static func mayRebuild(lastBuildMs: Int, age: TimeInterval, cheapAfter: TimeInterval = 0) -> Bool {
        lastBuildMs < 250 ? age >= cheapAfter : age > 1.5
    }
    func mayRebuildNow(cheapAfter: TimeInterval = 0) -> Bool {
        Self.mayRebuild(lastBuildMs: buffer.lastBuildMs, age: Date().timeIntervalSince(buffer.builtAt), cheapAfter: cheapAfter)
    }

    /// An element the buffer doesn't hold (WebKit's search found it, the focus went to it): on a page read only in
    /// part, read on toward it (it is most likely past the part read); otherwise the page read again, if a key may
    /// (mayRebuildNow). Its offset, or nil. Read again in full on every such key, a big page held the main thread for
    /// seconds a key (a review, 13 Nov 2026).
    func offsetReadingOnOrAgain(_ element: AXUIElement, cheapAfter: TimeInterval = 0) -> Int? {
        if let at = buffer.offset(of: element) { return at }
        if buffer.isPartial, buffer.canReadOn { return readingOn { buffer.offset(of: element) } }
        guard mayRebuildNow(cheapAfter: cheapAfter) else { return nil }
        rebuildKeepingPlace()
        return buffer.offset(of: element)
    }

    /// At the end of a page that loads more as it scrolls (YouTube said "bottom" before the end): the last
    /// element scrolled into view, the page read again with a fresh deadline, and true if there is more now.
    /// A page read only in part is read on instead (issue 227), and an unchanged one with more after its end since has
    /// that added. All of it within two seconds, and by `deadline`.
    func reachForMore(deadline: Date = .distantFuture) -> Bool {
        guard buffer.isDirty || buffer.isPartial || buffer.lastBuildMs >= 250 || Date().timeIntervalSince(buffer.builtAt) > 1 else { return false }
        let until = min(deadline, Date().addingTimeInterval(2))
        let before = buffer.text.length
        // A page read only in part (a long chat): on from where the copy stopped, pass after pass while they find no
        // text (a stretch of empty containers), until the time is up. Read again from the top, the same first part
        // came back, and the end was never reached.
        if buffer.isPartial, buffer.canReadOn {
            repeat {
                if buffer.buildMore(until: until) {
                    Log.io("browse mode: at the end of the part read, read on: \(buffer.text.length - before) characters more")
                    return true
                }
            } while buffer.isPartial && buffer.canReadOn && Date() < until
            Log.io("browse mode: at the end of the part read, read on: nothing more\(buffer.isPartial ? " in the time" : ", to the end")")
            return false
        }
        if let last = buffer.lines.last?.element { _ = AXUIElementPerformAction(last, "AXScrollToVisible" as CFString) }
        // An unchanged page with more after its end since it was read (a reply added at its foot) has it added; one that
        // said it changed is read again, so what changed in it is not kept beside what was added.
        if !buffer.isPartial, !buffer.isDirty, buffer.buildMore(until: until) {
            Log.io("browse mode: at the end, more after it: \(buffer.text.length - before) characters")
            return true
        }
        rebuildKeepingPlace(until: until)
        let more = buffer.text.length > before
        Log.io("browse mode: at the end, the page read again: \(more ? "more now (\(buffer.text.length - before) characters)" : "nothing more")")
        return more
    }

    /// Nothing more ahead in the copy: read on (a long page) or read the page again from its end, once, and then,
    /// while the page is read only in part, on again for up to two seconds, until `found` finds what was wanted.
    func readingOn<T>(_ found: () -> T?) -> T? {
        let until = Date().addingTimeInterval(2)
        guard reachForMore(deadline: until) else { return nil }
        if let hit = found() { return hit }
        while buffer.isPartial, buffer.canReadOn, Date() < until {
            if buffer.buildMore(until: until), let hit = found() { return hit }
        }
        return nil
    }

    /// Command Down: the bottom of the page. A page read only in part (a long chat, issue 227) is read on first, for
    /// up to two seconds; if there is more even then, that is said, and the key again reads on.
    func toBottom() {
        if buffer.isPartial {
            let until = Date().addingTimeInterval(2)
            while buffer.isPartial, buffer.canReadOn, Date() < until { buffer.buildMore(until: until) }
            if buffer.isPartial { Speech.speakMessage(String(localized: "page read in part, it is very long", comment: "Spoken message")) }
        }
        position = max(0, buffer.text.length - 1)
        speakUnit(.line)
    }

    /// A paged document (Preview's PDF): the page is said as the reading position crosses onto another one, as
    /// VoiceOver says it. Web pages have no pages, so this costs them one string compare.
    var lastPageIndex: Int?
    lazy var isPaged: Bool = webArea.string(kAXSubroleAttribute) == PreviewAppModule.containerSubrole
    func announcePageIfChanged() {
        guard isPaged, let el = buffer.segment(at: position)?.element, let page = PreviewAppModule.page(of: el) else { return }
        defer { lastPageIndex = page.index }
        if let last = lastPageIndex, last != page.index { Speech.speakMessage(page.words) }
    }

    /// Preview's comments and highlights on the line just read, after it (PreviewAppModule.marks).
    func sayMarksOnLine() {
        guard isPaged, let i = buffer.lineIndex(at: position), let el = buffer.segment(at: position)?.element,
              let page = PreviewAppModule.page(of: el) else { return }
        let l = buffer.lines[i]
        let text = buffer.text.substring(with: NSRange(location: l.start, length: l.end - l.start))
        let marks = PreviewAppModule.marks(for: webArea, page: page.index, line: text)
        guard !marks.isEmpty else { return }
        switch PreviewAppModule.markReport {
        case .off: return
        case .speech: for words in marks { Speech.speakMessage(words) }
        case .tone:
            Tones.comment()
            for words in marks { if let w = PreviewAppModule.wordsWithTone(words) { Speech.speakMessage(w) } }
        }
    }

    func move(_ unit: TextUnit, _ direction: Int) {
        refreshIfNavigated()
        clearSelection()
        guard ensureContent() else { return }
        if takePlacedByArrival() { return }
        rebuildIfCheap()
        guard var info = caretInfo() else { return }
        // NVDA's _caretMovementScriptHelper: expand to the unit and collapse to its start before moving, so Up from
        // the middle of a line (where Find left the caret) goes to the line above, not the start of this one.
        if unit != .character { info.expand(unit); info.collapse() }
        var moved = info.move(unit, direction)
        if moved != 0, unit == .line || unit == .paragraph {
            // HTML mail is full of empty lines: a run of them is one "blank", not four presses of it.
            var hops = 0
            while hops < 30 {
                let probe = info.copy(); probe.expand(unit)
                guard probe.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                let next = info.copy()
                guard next.move(unit, direction) != 0 else { break }
                let look = next.copy(); look.expand(unit)
                guard look.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }   // the next line has text: stop on this blank
                info.start = next.start; info.end = next.end; hops += 1
            }
            if hops > 0 { moved += hops * (direction > 0 ? 1 : -1) }
        }
        if moved == 0, direction > 0, reachForMore(), let again = caretInfo() {
            if unit != .character { again.expand(unit); again.collapse() }
            moved = again.move(unit, direction)
            if moved != 0 { info = again }
        }
        // Not "bottom" with more of a long page still to read (its reading on ran out of time): the key again reads on.
        if moved == 0 {
            Speech.speakMessage(direction < 0 ? String(localized: "top", comment: "Spoken message")
                : buffer.isPartial ? String(localized: "page read in part, it is very long", comment: "Spoken message")
                : String(localized: "bottom", comment: "Spoken message"))
        }
        position = info.start
        // Say all carries on from here and reads this line itself (NVDA's willSayAllResume).
        if SayAll.resuming { return }
        announcePageIfChanged()
        speakUnit(unit == .character ? .character : unit)
        if unit == .line || unit == .paragraph { sayMarksOnLine() }
    }

    // (An override cannot live in an extension: the pass-through decision itself is in FocusModePolicy.swift.)
    /// In a one-line field of a Safari page, Tab is TurnOver's even in focus mode: Safari's own Tab skips check boxes,
    /// buttons and links (Press Tab to highlight each item off, its default) and went from a form's name field to the
    /// address bar (the test page, 11 Nov 2026). Not a text area or a combo box, where Tab may mean something to the page.
    var tabIsTurnOversInField: Bool {
        guard let f = API.focusObject, f.pid == webArea.pid,
              ["AXTextField", "AXSearchField", "AXCheckBox", "AXRadioButton", "AXButton", "AXPopUpButton"].contains(f.axRole),
              let id = NSRunningApplication(processIdentifier: webArea.pid)?.bundleIdentifier, id.hasPrefix("com.apple.Safari") else { return false }
        return true
    }

    /// Scripts answer only in browse mode (NVDA: passThrough filters the tree interceptor's scripts).
    public override func script(for gesture: KeyboardGesture) -> Script? {
        // NVDA's way, in both styles (Oliver, 23 Oct 2026, issue 82): in browse mode a letter is always a command. A
        // field is typed into after Return or Tab has entered it (focus mode), or after the switch by hand. Until then
        // a letter typed while the reading position was on a field went into it (Mac style, 9 Oct 2026), and a letter
        // typed while a page field still had the keyboard resumed focus mode quietly (8 Oct 2026); the Safari stress
        // test of 23 Oct 2026 showed both typing h into a field the user had just left with Escape, on four pages.
        if let s = super.script(for: gesture) {
            if passThrough && s.name != "disablePassThrough" && !(s.name == "tabFromCaret" && tabIsTurnOversInField) { return nil }
            return s
        }
        // A letter or digit with no command of its own (z, 0) is kept from the page in browse mode, as NVDA's trap
        // non-command gestures does: otherwise it would reach a field that still has the keyboard after Escape.
        // Punctuation and Backspace still reach the page (a page's own ? for its shortcut help). Not with single-letter
        // navigation off, when the page's own letter keys are wanted (a second reviewer, 23 Oct 2026).
        let inBrowseMode = !passThrough
        let lettersAreCommands = singleLetterNavigation
        let isLetterOrDigit = gesture.typedCharacter.map { $0.isLetter || $0.isNumber } ?? false
        let isPlainKey = gesture.modifiers.subtracting(.shift).isEmpty
        if inBrowseMode, lettersAreCommands, isLetterOrDigit, isPlainKey {
            return Script(name: "browseModeTrap", description: String(localized: "A letter or digit with no command in browse mode: nothing", comment: "A command, as the key list and keyboard help say it"), category: "navigation", owner: self) { _ in
                Log.io("browse mode: a letter or digit with no command; kept from the page")
            }
        }
        return nil
    }

    /// The text field, text area or combo box at the reading position, if that is what is there.
    /// The element at the reading position (a picture to describe, a field to type into).
    public func elementAtPosition() -> AXUIElement? {
        buffer.segment(at: position)?.element ?? buffer.lineIndex(at: position).flatMap { buffer.lines[$0].element }
    }

    func editableAtPosition() -> AXUIElement? {
        let e: AXUIElement? = buffer.segment(at: position)?.element ?? buffer.lineIndex(at: position).flatMap { buffer.lines[$0].element }
        guard let e, ["AXTextField", "AXTextArea", "AXComboBox"].contains(e.role) else { return nil }
        return e
    }

    // Stored properties of the parts in the other files (an extension cannot hold them).
    /// Where the selection started; nil when nothing is selected.
    public internal(set) var selectionAnchor: Int?
    /// Where the virtual caret was when the focus last moved (followed or set). Tab from there is the browser's own.
    var positionAtFocus = -1
    /// The control the virtual caret last followed the focus to, and whether the focus now arriving comes from outside
    /// the document (set as the focus is presented): back from outside onto that control, the reading position stays.
    var lastFocusElement: AXUIElement?
    public var focusFromOutside = false
}

extension BrowseModeDocument {
    /// Whether `e` sits in an ARIA dialog or application inside its web area.
    static func inWebDialog(_ e: AXUIElement) -> Bool {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 25, x.role != "AXWebArea" {
            if ["AXApplicationDialog", "AXApplicationAlertDialog", "AXWebApplication"].contains(x.string(kAXSubroleAttribute) ?? "") || x.role == "AXWebApplication" { return true }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }
}
