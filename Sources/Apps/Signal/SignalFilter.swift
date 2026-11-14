// SPDX-License-Identifier: GPL-3.0-or-later
// Signal Desktop's events, said by TurnOver itself (14 Nov 2026): a port of the tester's VoiceOver Signal Filter
// (VoiceOverSignalFilter's TimelineScanner, TimelineParser and helper wiring; it mirrors their NVDA and Orca Signal
// Filter add-ons). "Message sent.", a message received ("Message received: …", or "Name: …" in a group), someone
// typing and stopping. The wording, de-duplication, priming and typing timing are in SignalFilterLogic.swift.
//
// How it looks (as the filter did): Chromium sends little news for changes inside Signal's page, so the timeline is
// scanned once a second and, a moment after Signal's own notifications (taken from TurnOver's observer for Signal,
// AXHandler.notificationTaps, not a second observer). Each scan reads the last eight message rows and looks for the
// typing bubble; the walk runs off the main thread (AXWalkRunner) and its result is applied on main.
// Received messages are said with Signal in front or behind, as the filter did; sent and typing only with Signal in
// front. Message words and names are never written to the log (Speech.redactedInLog).
import Foundation
import AppKit
import ApplicationServices

/// One scan of Signal's tree, made off the main thread. Holds the message words only until they are spoken.
nonisolated struct SignalScan: Sendable {
    struct Row: Sendable { let uuid: String; let direction: SignalDOMMarkers.Direction; let text: String?; let author: String? }
    struct Typing: Sendable, Equatable { let id: String; let names: [String] }
    var timeline: AXUIElement?
    /// From the "conversation-<id>" element above the timeline (checked on Signal Beta, 14 Nov 2026: seven levels
    /// up), else above the focus as the filter read it. Nil: not known, the last one stands.
    var conversation: String?
    /// Message rows seen (with or without a uuid): none means the timeline wants finding again.
    var rowsSeen = 0
    var rows: [Row] = []
    var typing: Typing?
}

final class SignalFilter {
    let pid: pid_t
    private var dedup = SignalMessageDedup()
    private var state = SignalConversationState()
    private var typing = SignalTypingState()
    private var typingSnapshot: SignalScan.Typing?
    private var timeline: AXUIElement?
    private var heartbeat: Timer?
    private var debounce = SignalDebounce()
    private var debounceGeneration = 0
    private let runner = AXWalkRunner<SignalScan>()

    init(pid: pid_t) { self.pid = pid }

    var isRunning: Bool { heartbeat != nil }

    /// From the first time Signal comes to the front until it quits or TurnOver stops (the module's terminate).
    func start() {
        guard heartbeat == nil, pid > 0 else { return }
        AXHandler.shared.notificationTaps[pid] = { [weak self] name in self?.notified(name) }
        // The filter's heartbeat: a message arriving while nobody touches anything sends no news (VoiceOver Signal
        // Filter, TimelineScanner.startHeartbeat).
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.scan() } }
        scan()   // primes the open conversation silently
        Log.io("signal: watching for messages and typing")
    }

    func stop() {
        heartbeat?.invalidate(); heartbeat = nil
        if AXHandler.shared.notificationTaps[pid] != nil { AXHandler.shared.notificationTaps[pid] = nil }
        runner.cancel()
        debounceGeneration += 1
        typing.cancel(); typingSnapshot = nil; timeline = nil
    }

    /// Signal's notifications that can mean a change in the conversation. Not value changes: the message box sends
    /// one at every key, and the filter left them alone.
    private static let news: Set<String> = [
        kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
        kAXMainWindowChangedNotification, kAXLayoutChangedNotification, kAXCreatedNotification, kAXRowCountChangedNotification,
        "AXLiveRegionChanged", "AXLiveRegionCreated",
    ]

    private func notified(_ name: String) {
        guard isRunning, Self.news.contains(name) else { return }
        let delay = debounce.schedule(now: Date())
        debounceGeneration += 1
        let g = debounceGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, g == debounceGeneration else { return }
            debounce.fired()
            scan()
        }
    }

    private func scan() {
        guard isRunning, Core.active else { return }
        let pid = pid, cached = timeline
        runner.submit(collect: { request in Self.collect(pid: pid, cached: cached, request: request) },
                      publish: { [weak self] scan in self?.apply(scan) })
    }

    // MARK: Applying a scan (main)

    private func apply(_ scan: SignalScan) {
        guard isRunning, Core.active else { return }
        timeline = scan.rowsSeen > 0 ? scan.timeline : nil   // no rows: look for the timeline afresh next time
        if state.switchTo(scan.conversation) {
            // Another conversation: its typing is not this one's, and its messages are primed silently below.
            typing.cancel(); typingSnapshot = nil
        }
        guard let convo = state.current else { return }
        let now = Date()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let settings = config.signal

        if let t = scan.typing {
            if typingSnapshot != t {
                typingSnapshot = t
                if typing.start(conversation: convo, names: t.names, current: convo, now: now), front, settings.announceTyping {
                    say(SignalAnnouncement.typingStarted(names: t.names), label: "typing")
                }
            }
        } else {
            typingSnapshot = nil
        }
        if let names = typing.poll(present: scan.typing != nil, now: now), front, settings.announceTypingStopped {
            say(SignalAnnouncement.typingStopped(names: names), label: "typing")
        }

        guard scan.rowsSeen > 0 else { return }
        let primed = state.isPrimed(convo)
        var fresh = 0
        for row in scan.rows where !dedup.contains(uuid: row.uuid, conversation: convo) {
            dedup.insert(uuid: row.uuid, conversation: convo)
            guard primed else { continue }
            fresh += 1
            announce(row, front: front, settings: settings)
        }
        if !primed { state.markPrimed(convo); Log.io("signal: conversation primed (\(scan.rows.count) messages showing, none said)") }
        if fresh > 0 {
            Log.io("signal: \(fresh) new message(s)")
            typing.messageArrived(present: scan.typing != nil, now: now)
        }
    }

    private func announce(_ row: SignalScan.Row, front: Bool, settings: Config.Signal) {
        switch row.direction {
        case .outgoing:
            if front, settings.announceSent { Speech.speakMessage(SignalAnnouncement.messageSent()) }
        case .incoming, .unknown:
            if settings.announceReceived {
                say(SignalAnnouncement.incomingMessage(text: row.text, author: row.author), label: "message")
            }
        }
    }

    /// Someone's words or names: spoken and shown, kept out of the log. Not over a say all, as TurnOver's other chat
    /// reading does.
    private func say(_ text: String, label: String) {
        guard !SayAll.isRunning else { return }
        Speech.redactedInLog(label) { Speech.speakNews(text) }
    }

    // MARK: Reading Signal's tree (off the main thread)

    private nonisolated static func classes(_ e: AXUIElement) -> [String] {
        (e.attr(SignalDOMMarkers.domClassList) as? [String]) ?? []
    }

    private nonisolated static func domID(_ e: AXUIElement) -> String? { e.string(SignalDOMMarkers.domIdentifier) }

    /// Depth first, at most `maxNodes` looked at (the filter's axFirstDescendant); `skip` leaves a subtree out.
    private nonisolated static func firstDescendant(_ root: AXUIElement, maxNodes: Int, request: AXWalkRequest,
                                                    skip: (([String]) -> Bool)? = nil, where match: ([String], AXUIElement) -> Bool) -> AXUIElement? {
        var stack = [root], visited = 0
        while let node = stack.popLast(), visited < maxNodes, !request.isCancelled {
            visited += 1
            let c = classes(node)
            if match(c, node) { return node }
            if let skip, skip(c) { continue }
            stack.append(contentsOf: node.elements(kAXChildrenAttribute).reversed())
        }
        return nil
    }

    private nonisolated static func conversationAbove(_ e: AXUIElement) -> String? {
        var current: AXUIElement? = e, steps = 0
        while let c = current, steps < 64 {
            if let id = SignalDOMMarkers.conversationID(fromID: domID(c)) { return id }
            current = c.element(kAXParentAttribute); steps += 1
        }
        return nil
    }

    nonisolated static func collect(pid: pid_t, cached: AXUIElement?, request: AXWalkRequest) -> SignalScan {
        var scan = SignalScan()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        // A dead element answers no role: the filter's cheap staleness check.
        let timeline = cached.flatMap { $0.role == "?" ? nil : $0 }
            ?? firstDescendant(app, maxNodes: 6000, request: request) { c, _ in c.contains(SignalDOMMarkers.timelineMessages) }
        guard let timeline, !request.isCancelled else { return scan }
        scan.timeline = timeline
        scan.conversation = conversationAbove(timeline) ?? app.element(kAXFocusedUIElementAttribute).flatMap(conversationAbove)
        scan.typing = typingBubble(app: app, timeline: timeline, request: request)
        guard !request.isCancelled else { return scan }
        let rows = trailingRows(timeline, limit: 8, request: request)
        scan.rowsSeen = rows.count
        for row in rows where !request.isCancelled {
            guard let uuid = SignalDOMMarkers.messageUUID(fromID: domID(row)) else { continue }   // the typing bubble
            scan.rows.append(.init(uuid: uuid, direction: SignalDOMMarkers.direction(classes: classes(row)),
                                   text: messageText(row, request: request), author: messageAuthor(row, request: request)))
        }
        return scan
    }

    /// The last `limit` message rows, oldest first. Each is a child of the timeline or (Signal Beta, 14 Nov 2026:
    /// every one) one level inside it.
    private nonisolated static func trailingRows(_ timeline: AXUIElement, limit: Int, request: AXWalkRequest) -> [AXUIElement] {
        var rows: [AXUIElement] = []
        for child in timeline.elements(kAXChildrenAttribute).reversed() {
            if request.isCancelled { break }
            if classes(child).contains(SignalDOMMarkers.messageContainer) { rows.append(child) }
            else if let inner = firstDescendant(child, maxNodes: 30, request: request, where: { c, _ in c.contains(SignalDOMMarkers.messageContainer) }) { rows.append(inner) }
            if rows.count >= limit { break }
        }
        return rows.reversed()
    }

    private nonisolated static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// The body ("module-message__text"): its value, description, or the words inside it; else the row's description.
    private nonisolated static func messageText(_ row: AXUIElement, request: AXWalkRequest) -> String? {
        if let body = firstDescendant(row, maxNodes: 400, request: request, where: { c, _ in c.contains(SignalDOMMarkers.messageText) }) {
            if let t = nonEmpty(body.string(kAXValueAttribute)) ?? nonEmpty(body.string(kAXDescriptionAttribute)) { return t }
            var pieces: [String] = []
            gather(body, depth: 0, into: &pieces)
            if !pieces.isEmpty { return pieces.joined(separator: " ") }
        }
        return nonEmpty(row.string(kAXDescriptionAttribute))
    }

    private nonisolated static func gather(_ e: AXUIElement, depth: Int, into pieces: inout [String]) {
        guard depth <= 6 else { return }
        if let v = nonEmpty(e.string(kAXValueAttribute)) { pieces.append(v); return }
        if let d = nonEmpty(e.string(kAXDescriptionAttribute)) { pieces.append(d); return }
        for c in e.elements(kAXChildrenAttribute) { gather(c, depth: depth + 1, into: &pieces) }
    }

    /// The sender's name, in a group only ("module-message__author"); a conversation with one person has none.
    private nonisolated static func messageAuthor(_ row: AXUIElement, request: AXWalkRequest) -> String? {
        guard let author = firstDescendant(row, maxNodes: 400, request: request, where: { c, _ in c.contains(SignalDOMMarkers.messageAuthor) }),
              let raw = nonEmpty(author.string(kAXValueAttribute)) ?? nonEmpty(author.string(kAXDescriptionAttribute)) ?? nonEmpty(author.string(kAXTitleAttribute))
        else { return nil }
        let name = SignalContactName.clean(raw)
        return name.isEmpty ? nil : name
    }

    /// The typing bubble, as the filter found it: the timeline's last children, then beside the timeline, then the
    /// whole window. The whole-window sweep leaves out the conversation list (14 Nov 2026, a change from the filter):
    /// a list item of another conversation with a typing class would be taken for this one's, and the list is most of
    /// the tree to walk each second.
    private nonisolated static func typingBubble(app: AXUIElement, timeline: AXUIElement, request: AXWalkRequest) -> SignalScan.Typing? {
        let isTyping: ([String], AXUIElement) -> Bool = { c, _ in SignalDOMMarkers.isTyping(classes: c) }
        var found: AXUIElement?
        for child in timeline.elements(kAXChildrenAttribute).reversed().prefix(12) where found == nil {
            found = firstDescendant(child, maxNodes: 120, request: request, where: isTyping)
        }
        if found == nil, let parent = timeline.element(kAXParentAttribute) {
            for sibling in parent.elements(kAXChildrenAttribute) where found == nil {
                found = firstDescendant(sibling, maxNodes: 120, request: request, where: isTyping)
            }
        }
        if found == nil {
            found = firstDescendant(app, maxNodes: 8000, request: request,
                                    skip: { c in c.contains { $0.hasPrefix(SignalDOMMarkers.conversationList) } }, where: isTyping)
        }
        guard let bubble = found, !request.isCancelled else { return nil }
        let names = typingNames(bubble, app: app, request: request)
        return .init(id: domID(bubble) ?? names.joined(separator: ","), names: names)
    }

    /// The avatars' names in a group; in a conversation with one person, the name in the header. "others" for an
    /// overflow count.
    private nonisolated static func typingNames(_ bubble: AXUIElement, app: AXUIElement, request: AXWalkRequest) -> [String] {
        var names: [String] = [], overflow = false
        var stack = [bubble], visited = 0
        while let node = stack.popLast(), visited < 200, !request.isCancelled {
            visited += 1
            let c = classes(node)
            if c.contains(where: { $0.contains(SignalDOMMarkers.typingOverflowSuffix) }) { overflow = true; continue }
            if c.contains(SignalDOMMarkers.typingAvatarSpacer) { continue }
            if c.contains(SignalDOMMarkers.typingAvatar) { if let n = bestName(node) { names.append(n) }; continue }
            stack.append(contentsOf: node.elements(kAXChildrenAttribute))
        }
        if names.isEmpty, let header = headerName(app: app, request: request) { names.append(header) }
        if overflow { names.append("others") }
        return names
    }

    private nonisolated static func bestName(_ e: AXUIElement) -> String? {
        for raw in [e.string(kAXTitleAttribute), e.string(kAXValueAttribute), e.string(kAXDescriptionAttribute)].compactMap({ $0 }) {
            let name = SignalContactName.clean(raw)
            if !name.isEmpty { return name }
        }
        return nil
    }

    private nonisolated static func headerName(app: AXUIElement, request: AXWalkRequest) -> String? {
        let tests: [([String]) -> Bool] = [
            { $0.contains(SignalDOMMarkers.conversationHeaderTitle) },
            { $0.contains(SignalDOMMarkers.conversationHeaderClickable) },
            { $0.contains { $0.contains("ConversationHeader") } },
        ]
        for test in tests {
            if let e = firstDescendant(app, maxNodes: 5000, request: request, where: { c, _ in test(c) }), let name = bestName(e) { return name }
        }
        return nil
    }
}
