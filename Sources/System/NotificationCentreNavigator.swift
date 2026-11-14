// SPDX-License-Identifier: GPL-3.0-or-later
// Notification Centre by its apps (a tester's design, 11 Nov 2026): Left and Right go from app to app, Up and Down
// through that app's notifications, Space opens a collapsed app's stack, Return opens a notification, Delete closes
// one (on a collapsed stack: the whole stack). The panel's own buttons (Clear All, the older notifications) are the
// first group, and the widgets the last. Tab still goes round everything as before (Dialog).
//
// Measured 11 Nov 2026, macOS 27.2: the list (AXNotificationListItems) holds, in order, single notifications
// (AXNotificationCenterAlert: press opens; custom actions Show Details, Close), collapsed apps
// (AXNotificationCenterBannerStack: description "App, title, body, stacked"; custom actions Show, Clear All), an
// opened app's notifications (AXNotificationCenterBanner), a heading "Notification Centre" with its "Clear All"
// button (every notification) and the "N more notifications" button. The widgets sit in AXOpaqueProviderGrid beside
// it, a group each. Each notification's description starts with its app's name.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

final class NotificationCentreNavigatorPlugin: GlobalPlugin {
    required init() {
        super.init()
        let cat = "Notification Centre"
        let keys: [(String, String, String, () -> Void)] = [
            ("nc_nextApp", String(localized: "In Notification Centre: the next app's notifications", comment: "A command, as the key list and keyboard help say it"), "rightArrow", { NotificationCentreNavigator.moveGroup(1) }),
            ("nc_previousApp", String(localized: "In Notification Centre: the previous app's notifications", comment: "A command, as the key list and keyboard help say it"), "leftArrow", { NotificationCentreNavigator.moveGroup(-1) }),
            ("nc_next", String(localized: "In Notification Centre: the next notification of this app (a collapsed app opens)", comment: "A command, as the key list and keyboard help say it"), "downArrow", { NotificationCentreNavigator.moveItem(1) }),
            ("nc_previous", String(localized: "In Notification Centre: the previous notification of this app", comment: "A command, as the key list and keyboard help say it"), "upArrow", { NotificationCentreNavigator.moveItem(-1) }),
            ("nc_expand", String(localized: "In Notification Centre: opens a collapsed app's notifications, or presses the button", comment: "A command, as the key list and keyboard help say it"), "space", { NotificationCentreNavigator.space() }),
            ("nc_open", String(localized: "In Notification Centre: opens the notification", comment: "A command, as the key list and keyboard help say it"), "enter", { NotificationCentreNavigator.open() }),
            ("nc_close", String(localized: "In Notification Centre: closes the notification (a collapsed app: all of its)", comment: "A command, as the key list and keyboard help say it"), "backspace", { NotificationCentreNavigator.close() }),
            ("nc_clearApp", String(localized: "In Notification Centre: clears all of this app's notifications", comment: "A command, as the key list and keyboard help say it"), "command+backspace", { NotificationCentreNavigator.clearApp() }),
        ]
        for (name, desc, key, run) in keys {
            // (Delete and Command Delete held down close one each, not one per repeat: a review, 13 Nov 2026.)
            let destructive = key.hasSuffix("backspace")
            script(name, desc, gestures: ["kb:\(key)"], category: cat) { g in if destructive, g.isRepeat { return }; run() }.isAvailable = { NotificationCentreNavigator.active }
        }
        script("nc_leaveWidget", String(localized: "In a Notification Centre widget: back out of it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: cat) { _ in
            NotificationCentreNavigator.leaveWidget()
        }.isAvailable = { NotificationCentreNavigator.active && NotificationCentreNavigator.inWidget }
        API.focusChangeHandlers.append { _, new in
            guard NotificationCentreNavigator.inWidget, !NotificationCentrePanel.isOpen,
                  new?.pid != NotificationCentrePanel.centrePid() else { return }
            NotificationCentreNavigator.forgetWidget()
        }
    }
}

package enum NotificationCentreNavigator {
    enum Kind { case notification, stack, button, widget }
    struct Item { let element: AXUIElement; let kind: Kind; let words: String }
    struct Group { let name: String; var items: [Item]; var collapsed: Bool }

    /// The app (group) and the notification within it TurnOver is on, kept by their words so a rebuilt list (the
    /// panel changes as notifications come and go) finds them again.
    private static var groupName: String?
    private static var itemWords: String?
    /// The item's place in its app, so one of two notifications with the same words is told apart (both used to
    /// resolve to the first, and Down stuck there: a review, 13 Nov 2026), and a closed one's neighbour is next.
    private static var itemIndex: Int?
    /// Until a close's landing (half a second after it): the remembered place is where TurnOver is, as the review
    /// element has gone and Notification Centre's moved focus isn't the next one. A second Delete in that time closed
    /// whatever the focus moved to (a review, 13 Nov 2026).
    private static var closeLandingUntil = Date.distantPast
    /// Inside a widget (Return or Space on it): its lines, read with Up and Down, as on the desktop; Return or Space
    /// opens its app at the line, Escape comes back out (a tester, 13 Nov 2026).
    private static var widget: (name: String, lines: [DesktopNavigator.Line], index: Int)?
    static var inWidget: Bool { widget != nil }
    /// The panel closed, or the focus went elsewhere with it closed: out of any widget, so the next opening isn't still
    /// inside the last one's lines (a review, 13 Nov 2026).
    static func forgetWidget() {
        guard widget != nil else { return }
        Log.io("notification centre: out of the widget (the panel closed)")
        widget = nil
    }

    private static func enterWidget(_ item: Item, name: String) -> Bool {
        let ls = DesktopNavigator.widgetLines(item.element)
        guard !ls.isEmpty else { return false }
        // The widget's own name (Calendar, Weather), not its group's ("Widgets").
        let own = item.element.string(kAXDescriptionAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let name = own
        widget = (name, ls, 0)
        Tones.press()
        Log.io("notification centre: into a widget, \(ls.count) lines")
        Speech.cancel()
        Speech.speakMessage(String(localized: "in \(name)", comment: "Gone into a widget: its name"))
        sayWidgetLine(interrupt: false)
        return true
    }
    private static func sayWidgetLine(interrupt: Bool = true) {
        guard let w = widget, w.lines.indices.contains(w.index) else { return }
        let l = w.lines[w.index]
        ObjectNavigator.shared.place(l.element)
        Tones.focusTick()
        if interrupt { Speech.cancel() }
        var words = l.words
        if l.heading { words += ", " + String(localized: "heading", comment: "A role: a heading") }
        // (A widget's words are the user's: events, messages. Their length only in the log.)
        Speech.redactedInLog("widget") { Speech.speakItem(words + ", " + Phrases.position(w.index + 1, of: w.lines.count)) }
    }
    static func leaveWidget() {
        guard widget != nil else { return }
        widget = nil
        let gs = groups()
        guard !gs.isEmpty else { return }
        let (g, i) = place(in: gs)
        land(gs, g, i, announceGroup: false)
    }

    /// While the panel is open and TurnOver's cursor is in it, and no menu is open over it: a notification's own menu
    /// (Dismiss, Notification Settings…) had its arrows and Return taken, and Return pressed the notification instead
    /// (a tester, 13 Nov 2026: "pushing Dismiss does nothing").
    static var active: Bool {
        guard NotificationCentrePanel.isOpen, !AXHandler.shared.isMenuOpen else { return false }
        guard ObjectNavigator.shared.reviewElement?.pid == NotificationCentrePanel.centrePid()
            || API.focusObject?.pid == NotificationCentrePanel.centrePid() else { return false }
        return listShowing()
    }

    /// The list is on a screen with a size: the open flag is set by foreground news, and a closing that was missed left
    /// the arrows, Return, Space and Delete taken in every app (a review, 13 Nov 2026). The list stays in the tree when
    /// the panel is closed (NotificationCentrePanel.list), so its frame is what's asked. Kept half a second: this is
    /// asked for every key (only a yes is kept: a panel still opening is asked again).
    private static var shownCheck: (at: Date, shown: Bool)?
    private static func listShowing() -> Bool {
        if let c = shownCheck, c.shown, Date().timeIntervalSince(c.at) < 0.5 { return true }
        let shown = NotificationCentrePanel.list().flatMap { TurnOverObject.frame($0) }.map(Self.onScreen) ?? false
        if !shown { Log.io("notification centre: the open flag is set but the list isn't on screen; keys left to the app") }
        shownCheck = (Date(), shown)
        return shown
    }
    private static func onScreen(_ r: CGRect) -> Bool {
        guard r.width >= 1, r.height >= 1 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success, n > 0 else { return true }   // (displays unknown: as before)
        return ids.prefix(Int(n)).contains { CGDisplayBounds($0).intersects(r) }
    }

    /// The panel as groups: its own buttons, each app's notifications (an opened app's own buttons, Show Less and
    /// Clear, at its top), the widgets.
    static func groups() -> [Group] {
        guard let list = NotificationCentrePanel.list() else { return [] }
        var buttons: [Item] = []
        var apps: [Group] = []
        let panelName = String(localized: "Notification Centre", comment: "The Mac's Notification Centre")
        // The heading the buttons that follow belong to: an opened app's, or the panel's own.
        var heading: String?
        for e in list.elements(kAXChildrenAttribute) {
            let sub = e.string(kAXSubroleAttribute) ?? ""
            let desc = (e.string(kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespaces)
            if e.role == "AXHeading" {
                heading = desc
                // (An opened app's first notification comes before its heading: the heading joins it.)
                if desc != panelName, !desc.isEmpty, apps.last?.name != desc { apps.append(Group(name: desc, items: [], collapsed: false)) }
            } else if sub.hasPrefix("AXNotificationCenter") {
                let stacked = sub == "AXNotificationCenterBannerStack"
                var words = desc
                if stacked, words.hasSuffix(", stacked") { words = String(words.dropLast(", stacked".count)) }
                let app = words.components(separatedBy: ", ").first ?? words
                let item = Item(element: e, kind: stacked ? .stack : .notification, words: words)
                if let last = apps.indices.last, apps[last].name == app, !apps[last].collapsed, !stacked { apps[last].items.append(item) }
                else { apps.append(Group(name: app, items: [item], collapsed: stacked)) }
                heading = nil
            } else if e.role == "AXButton" {
                let t = desc.isEmpty ? (e.string(kAXTitleAttribute) ?? "") : desc
                guard !t.isEmpty else { continue }
                let b = Item(element: e, kind: .button, words: t.replacingOccurrences(of: "Confirm ", with: ""))
                if let h = heading, h != panelName, let last = apps.indices.last, apps[last].name == h {
                    // The app's own buttons at its top, before its notifications.
                    let at = apps[last].items.prefix { $0.kind == .button }.count
                    apps[last].items.insert(b, at: at)
                }
                else { buttons.append(b) }
            }
        }
        apps.removeAll { $0.items.isEmpty }
        var out: [Group] = []
        if !buttons.isEmpty { out.append(Group(name: String(localized: "Notification Centre", comment: "The Mac's Notification Centre"), items: buttons, collapsed: false)) }
        out += apps
        // The widgets beside the list: each one's words.
        if let scroll = list.element(kAXParentAttribute)?.element(kAXParentAttribute),
           let grid = scroll.elements(kAXChildrenAttribute).first(where: { $0.string(kAXSubroleAttribute) == "AXOpaqueProviderGrid" })
            ?? list.element(kAXParentAttribute)?.elements(kAXChildrenAttribute).first(where: { $0.string(kAXSubroleAttribute) == "AXOpaqueProviderGrid" }) {
            let widgets = grid.elements(kAXChildrenAttribute).map { w -> Item in
                let words = widgetWords(w)
                let name = w.string(kAXDescriptionAttribute) ?? ""
                return Item(element: w, kind: .widget, words: words.isEmpty ? name : (name.isEmpty || words.hasPrefix(name) ? words : name + ", " + words))
            }.filter { !$0.words.isEmpty }
            if !widgets.isEmpty { out.append(Group(name: String(localized: "Widgets", comment: "Notification Centre's widgets"), items: widgets, collapsed: false)) }
        }
        return out
    }

    /// A widget's words: what each part inside it says (its parts keep their words in descriptions: the clock's
    /// cities, the weather's hours), in order, each once.
    static func widgetWords(_ w: AXUIElement) -> String {
        var out: [String] = []
        var queue = w.elements(kAXChildrenAttribute), seen = 0
        while !queue.isEmpty, seen < 120 {
            let e = queue.removeFirst(); seen += 1
            let t = [e.string(kAXDescriptionAttribute), e.string(kAXTitleAttribute), e.string(kAXValueAttribute)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            if let t, !out.contains(t) { out.append(t) }
            queue.insert(contentsOf: e.elements(kAXChildrenAttribute), at: 0)
        }
        return out.joined(separator: ", ")
    }

    /// Where TurnOver is in the groups now: the item TurnOver's review cursor or the focus is on (Tab and object
    /// navigation move them, not the remembered place: Delete closed, and Command-Delete cleared, the app last arrowed
    /// to, a review, 13 Nov 2026), else the remembered app and place, else the first notification's app.
    private static func place(in gs: [Group], useCursor: Bool = true) -> (Int, Int) {
        var hit: (Int, Int)?
        if useCursor {
            let centre = NotificationCentrePanel.centrePid()
            let candidates = [ObjectNavigator.shared.reviewElement, API.focusObject?.element].compactMap { $0 }.filter { $0.pid == centre }
            search: for start in candidates {
                var e: AXUIElement? = start; var hops = 0
                while let x = e, hops < 4 {
                    for (g, group) in gs.enumerated() {
                        if let i = group.items.firstIndex(where: { $0.element.isSame(x) }) { hit = (g, i); break search }
                    }
                    e = x.element(kAXParentAttribute); hops += 1
                }
            }
        }
        return resolvePlace(groupNames: gs.map(\.name), itemWords: gs.map { $0.items.map(\.words) }, hit: hit,
                            group: groupName, index: itemIndex, words: itemWords,
                            defaultGroup: min(gs.count - 1, gs.count > 1 && gs[0].items.first?.kind == .button ? 1 : 0),
                            firstNotifications: gs.map { firstNotification($0) })
    }

    /// The place from what's known (pure, for the tests): the cursor's item; else in the remembered app, the remembered
    /// place if its words still match, the same words nearest it, or (no words: the one there was closed) the place
    /// itself; else the app's first notification.
    package nonisolated static func resolvePlace(groupNames: [String], itemWords words: [[String]], hit: (Int, Int)?, group: String?, index: Int?,
                                                 words remembered: String?, defaultGroup: Int, firstNotifications: [Int]) -> (Int, Int) {
        func firstNotification(_ g: Int) -> Int { firstNotifications.indices.contains(g) ? firstNotifications[g] : 0 }
        if let hit, words.indices.contains(hit.0), words[hit.0].indices.contains(hit.1) { return hit }
        guard let name = group, let g = groupNames.firstIndex(of: name), !words[g].isEmpty else { return (defaultGroup, firstNotification(defaultGroup)) }
        let items = words[g]
        if let i = index, items.indices.contains(i), remembered == nil || items[i] == remembered { return (g, i) }
        if let w = remembered {
            let at = index ?? 0
            if let j = items.indices.filter({ items[$0] == w }).min(by: { abs($0 - at) < abs($1 - at) }) { return (g, j) }
            return (g, firstNotification(g))
        }
        if let i = index { return (g, min(max(0, i), items.count - 1)) }
        return (g, firstNotification(g))
    }

    /// The panel has opened: its summary, and TurnOver on the first app's newest notification.
    static func enter() {
        let gs = groups()
        groupName = nil; itemWords = nil; itemIndex = nil
        let apps = gs.filter { $0.items.first?.kind == .notification || $0.items.first?.kind == .stack }.count
        guard !gs.isEmpty else { return }
        let (g, i) = place(in: gs, useCursor: false)
        Speech.cancel()
        let head = apps == 0 ? String(localized: "Notification Centre, no notifications", comment: "Spoken message")
            : String(localized: "Notification Centre, \(apps) apps. Left and Right go between apps, Up and Down through their notifications.", comment: "Notification Centre opened: %lld is how many apps have notifications")
        Speech.speakMessage(head)
        land(gs, g, i, announceGroup: true, interrupt: false)
    }

    static func moveGroup(_ delta: Int) {
        let gs = groups()
        guard !gs.isEmpty else { Tones.edge(); return }
        widget = nil
        let (g, _) = place(in: gs)
        let n = g + delta
        guard gs.indices.contains(n) else { Tones.edge(); return }
        land(gs, n, firstNotification(gs[n]), announceGroup: true)
    }

    /// An app's first notification (its own buttons come before it), or its first item.
    static func firstNotification(_ g: Group) -> Int { g.items.firstIndex { $0.kind != .button } ?? 0 }

    static func moveItem(_ delta: Int) {
        if var w = widget {
            let n = w.index + delta
            guard w.lines.indices.contains(n) else { Tones.edge(); return }
            w.index = n; widget = w
            sayWidgetLine(); return
        }
        let gs = groups()
        guard !gs.isEmpty else { Tones.edge(); return }
        let (g, i) = place(in: gs)
        let group = gs[g]
        // Down on a collapsed app: it opens, and TurnOver goes to its first notification.
        if delta > 0, group.collapsed, let stack = group.items.first?.element { expand(stack, app: group.name); return }
        let n = i + delta
        guard group.items.indices.contains(n) else { Tones.edge(); return }
        land(gs, g, n, announceGroup: false)
    }

    static func space() {
        if let w = widget { if DesktopNavigator.pressLine(w.lines[w.index].element) { widget = nil } else { Tones.edge() }; return }
        let gs = groups()
        guard !gs.isEmpty else { return }
        let (g, i) = place(in: gs)
        let item = gs[g].items[min(i, gs[g].items.count - 1)]
        switch item.kind {
        case .stack: expand(item.element, app: gs[g].name)
        case .widget: if !enterWidget(item, name: gs[g].name) { press(item) }
        case .button: press(item)
        case .notification:
            // In an opened app: Space closes it up again (its Show Less button), as it opened.
            if let less = gs[g].items.first(where: { $0.kind == .button && $0.words.lowercased().contains("show less") }) {
                press(less)
                Speech.speakMessage(String(localized: "\(gs[g].name) collapsed", comment: "An app's notifications closed up in Notification Centre"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let now = groups()
                    if let ng = now.firstIndex(where: { $0.name == gs[g].name }) { itemWords = nil; itemIndex = nil; land(now, ng, 0, announceGroup: false, interrupt: false) }
                }
            } else { press(item) }
        }
    }

    static func open() {
        if let w = widget { if DesktopNavigator.pressLine(w.lines[w.index].element) { widget = nil } else { Tones.edge() }; return }
        let gs = groups()
        guard !gs.isEmpty else { return }
        let (g, i) = place(in: gs)
        let item = gs[g].items[min(i, gs[g].items.count - 1)]
        if item.kind == .widget, enterWidget(item, name: gs[g].name) { return }
        press(item)
    }

    static func close() {
        let gs = groups()
        guard !gs.isEmpty else { return }
        let (g, i) = place(in: gs, useCursor: Date() >= closeLandingUntil)
        let item = gs[g].items[min(i, gs[g].items.count - 1)]
        let action = item.kind == .stack ? "Clear All" : "Close"
        guard item.kind == .notification || item.kind == .stack, let full = customAction(item.element, named: action) else { Tones.edge(); return }
        let r = AXUIElementPerformAction(item.element, full as CFString)
        Log.io("notification centre: \(action) on a \(item.kind == .stack ? "collapsed app" : "notification") → \(describeError(r))")
        guard r == .success else { Speech.speakMessage(String(localized: "could not close it", comment: "Spoken message")); return }
        Tones.press()
        Speech.speakMessage(item.kind == .stack ? String(localized: "\(gs[g].name) cleared", comment: "An app's notifications cleared: %@ is the app") : String(localized: "closed", comment: "A notification closed"))
        // The closed one's place: what moved up into it is next. The cursor's element has gone, so it isn't found.
        groupName = gs[g].name; itemIndex = i; itemWords = nil
        closeLandingUntil = Date().addingTimeInterval(0.6)   // past the landing: it remembers where it landed
        // On to what is there now, once the panel has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let now = groups()
            guard !now.isEmpty else { Speech.speakMessage(String(localized: "no notifications", comment: "Spoken message")); return }
            // The remembered place alone: Notification Centre moves its own focus as the item goes, and the cursor
            // or that focus took the closed one's place over (a review, 13 Nov 2026).
            let (ng, ni) = place(in: now, useCursor: false)
            land(now, ng, ni, announceGroup: groupName != now[ng].name, interrupt: false)
        }
    }

    /// Command Delete: all of this app's notifications (its Clear button, a stack's Clear All, or each one closed).
    static func clearApp() {
        let gs = groups()
        guard !gs.isEmpty else { return }
        let (g, _) = place(in: gs)
        let group = gs[g]
        guard group.items.contains(where: { $0.kind == .notification || $0.kind == .stack }) else { Tones.edge(); return }
        var done = false
        if let clear = group.items.first(where: { $0.kind == .button && $0.words == "Clear" }) {
            done = AXUIElementPerformAction(clear.element, kAXPressAction as CFString) == .success
        } else if let stack = group.items.first(where: { $0.kind == .stack }), let all = customAction(stack.element, named: "Clear All") {
            done = AXUIElementPerformAction(stack.element, all as CFString) == .success
        } else {
            for it in group.items where it.kind == .notification { if let c = customAction(it.element, named: "Close"), AXUIElementPerformAction(it.element, c as CFString) == .success { done = true } }
        }
        Log.io("notification centre: \(group.name) cleared → \(done)")
        guard done else { Speech.speakMessage(String(localized: "could not clear it", comment: "Spoken message")); return }
        Tones.press()
        Speech.speakMessage(String(localized: "\(group.name) cleared", comment: "An app's notifications cleared: %@ is the app"))
        groupName = nil; itemWords = nil; itemIndex = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let now = groups()
            guard !now.isEmpty else { return }
            let ng = min(g, now.count - 1)
            land(now, ng, firstNotification(now[ng]), announceGroup: true, interrupt: false)
        }
    }

    private static func expand(_ stack: AXUIElement, app: String) {
        // A press opens the stack in place (measured 11 Nov 2026); its "Show" action opens the app instead.
        let r = AXUIElementPerformAction(stack, kAXPressAction as CFString)
        Log.io("notification centre: \(app) opened → \(describeError(r))")
        Tones.press()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let gs = groups()
            guard let g = gs.firstIndex(where: { $0.name == app }) else { return }
            itemWords = nil; itemIndex = nil
            land(gs, g, firstNotification(gs[g]), announceGroup: true, interrupt: false)
        }
    }

    private static func press(_ item: Item) {
        let r = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        Log.io("notification centre: pressed a \(item.kind) → \(describeError(r))")
        if r == .success { Tones.press() }
    }

    /// A custom action by its name ("Close", "Show", "Clear All"): the action's full string as the element gives it.
    private static func customAction(_ e: AXUIElement, named name: String) -> String? {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return ((names as? [String]) ?? []).first { ($0.components(separatedBy: "\n").first ?? "") == "Name:" + name }
    }

    /// On an item: TurnOver's review cursor there (so its other keys and the context menu act on it), and it said.
    private static func land(_ gs: [Group], _ g: Int, _ i: Int, announceGroup: Bool, interrupt: Bool = true) {
        widget = nil   // (an item landed on: out of any widget)
        let group = gs[g]
        let item = group.items[i]
        groupName = group.name; itemWords = item.words; itemIndex = i
        ObjectNavigator.shared.place(item.element)   // without a word: said below
        Tones.focusTick()
        if interrupt { Speech.cancel() }
        var parts: [String] = []
        if announceGroup {
            let notes = group.items.filter { $0.kind == .notification }.count
            let count = group.collapsed ? String(localized: "collapsed, Space or Down opens it", comment: "A collapsed app in Notification Centre")
                : notes == 0 ? Phrases.items(group.items.count)
                : notes == 1 ? String(localized: "1 notification", comment: "An app with one notification")
                : String(localized: "\(notes) notifications", comment: "How many notifications an app has: %lld")
            parts.append("\(group.name), \(count), \(Phrases.position(g + 1, of: gs.count))")
        }
        // The app's name is said with the group; the item's own words without it.
        var words = item.words
        if item.kind == .notification || item.kind == .stack, words.hasPrefix(group.name + ", ") { words = String(words.dropFirst(group.name.count + 2)) }
        if item.kind == .button { words += ", " + Role.button.displayString }
        parts.append(words)
        if !group.collapsed, group.items.count > 1 { parts.append(Phrases.position(i + 1, of: group.items.count)) }
        // Joined as sentences, without a second full stop after one the words already end with.
        var said = ""
        for p in parts where !p.isEmpty {
            if said.isEmpty { said = p; continue }
            said += (said.last.map { ".!?…".contains($0) } ?? false) ? " " + p : ". " + p
        }
        // The words are someone's messages: in the log only their length (a tester, 13 Nov 2026).
        Speech.redactedInLog("\(item.kind)") { Speech.speakItem(said) }
    }
}
