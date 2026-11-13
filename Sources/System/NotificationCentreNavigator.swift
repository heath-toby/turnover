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
            script(name, desc, gestures: ["kb:\(key)"], category: cat) { _ in run() }.isAvailable = { NotificationCentreNavigator.active }
        }
        script("nc_leaveWidget", String(localized: "In a Notification Centre widget: back out of it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: cat) { _ in
            NotificationCentreNavigator.leaveWidget()
        }.isAvailable = { NotificationCentreNavigator.active && NotificationCentreNavigator.inWidget }
    }
}

enum NotificationCentreNavigator {
    enum Kind { case notification, stack, button, widget }
    struct Item { let element: AXUIElement; let kind: Kind; let words: String }
    struct Group { let name: String; var items: [Item]; var collapsed: Bool }

    /// The app (group) and the notification within it TurnOver is on, kept by their words so a rebuilt list (the
    /// panel changes as notifications come and go) finds them again.
    private static var groupName: String?
    private static var itemWords: String?
    /// Inside a widget (Return or Space on it): its lines, read with Up and Down, as on the desktop; Return or Space
    /// opens its app at the line, Escape comes back out (a tester, 13 Nov 2026).
    private static var widget: (name: String, lines: [DesktopNavigator.Line], index: Int)?
    static var inWidget: Bool { widget != nil }

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
        return ObjectNavigator.shared.reviewElement?.pid == NotificationCentrePanel.centrePid()
            || API.focusObject?.pid == NotificationCentrePanel.centrePid()
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

    /// Where TurnOver is in the groups now: by the remembered names, else the first notification's app.
    private static func place(in gs: [Group]) -> (Int, Int) {
        let g = groupName.flatMap { n in gs.firstIndex { $0.name == n } } ?? min(gs.count - 1, gs.count > 1 && gs[0].items.first?.kind == .button ? 1 : 0)
        let i = itemWords.flatMap { w in gs[g].items.firstIndex { $0.words == w } } ?? firstNotification(gs[g])
        return (g, i)
    }

    /// The panel has opened: its summary, and TurnOver on the first app's newest notification.
    static func enter() {
        let gs = groups()
        groupName = nil; itemWords = nil
        let apps = gs.filter { $0.items.first?.kind == .notification || $0.items.first?.kind == .stack }.count
        guard !gs.isEmpty else { return }
        let (g, i) = place(in: gs)
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
                    if let ng = now.firstIndex(where: { $0.name == gs[g].name }) { itemWords = nil; land(now, ng, 0, announceGroup: false, interrupt: false) }
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
        let (g, i) = place(in: gs)
        let item = gs[g].items[min(i, gs[g].items.count - 1)]
        let action = item.kind == .stack ? "Clear All" : "Close"
        guard item.kind == .notification || item.kind == .stack, let full = customAction(item.element, named: action) else { Tones.edge(); return }
        let r = AXUIElementPerformAction(item.element, full as CFString)
        Log.io("notification centre: \(action) on a \(item.kind == .stack ? "collapsed app" : "notification") → \(describeError(r))")
        guard r == .success else { Speech.speakMessage(String(localized: "could not close it", comment: "Spoken message")); return }
        Tones.press()
        Speech.speakMessage(item.kind == .stack ? String(localized: "\(gs[g].name) cleared", comment: "An app's notifications cleared: %@ is the app") : String(localized: "closed", comment: "A notification closed"))
        itemWords = nil
        // On to what is there now, once the panel has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let now = groups()
            guard !now.isEmpty else { Speech.speakMessage(String(localized: "no notifications", comment: "Spoken message")); return }
            let (ng, ni) = place(in: now)
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
        groupName = nil; itemWords = nil
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
            itemWords = nil
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
        groupName = group.name; itemWords = item.words
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
