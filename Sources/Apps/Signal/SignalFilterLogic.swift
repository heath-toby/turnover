// SPDX-License-Identifier: GPL-3.0-or-later
// Signal Desktop's events, the pure part (14 Nov 2026): from the tester's VoiceOver Signal Filter
// (VoiceOverSignalFilter, which mirrors their NVDA and Orca Signal Filter add-ons). The wording, the contact name
// cleaner, the de-duplication cache, the conversation store and the typing state machine are copied from it, with the
// clock passed in so the tests can drive the timing. SignalFilter.swift reads Signal's tree and speaks.
import Foundation

/// The strings that find Signal's parts through Chromium's accessibility bridge. From the tester's VoiceOver Signal
/// Filter (SignalDOMMarkers.swift), which took them from the Orca and NVDA add-ons and Signal-Desktop's source.
/// Checked against Signal Beta on 14 Nov 2026 (macOS 27.2): the timeline is an AXList "module-timeline__messages",
/// each message an AXRow "module-message__container" with the id "message-accessibility-contents:<uuid>", the open
/// conversation an ancestor with the id "conversation-<id>".
nonisolated package enum SignalDOMMarkers {
    package static let bundles: Set<String> = ["org.whispersystems.signal-desktop", "org.whispersystems.signal-desktop-beta"]

    /// Chromium's own attributes, not in AppKit's headers.
    package static let domClassList = "AXDOMClassList"
    package static let domIdentifier = "AXDOMIdentifier"

    package static let timelineMessages = "module-timeline__messages"
    package static let messageContainer = "module-message__container"
    package static let messageText = "module-message__text"
    package static let messageAuthor = "module-message__author"
    package static let incomingSuffix = "--incoming"
    package static let outgoingSuffix = "--outgoing"
    package static let typingAvatar = "module-message__typing-avatar"
    package static let typingAvatarSpacer = "module-message__typing-avatar-spacer"
    package static let typingOverflowSuffix = "--overflow-count"
    package static let conversationHeaderTitle = "module-ConversationHeader__header__info__title"
    package static let conversationHeaderClickable = "module-ConversationHeader__header--clickable"
    package static let conversationList = "module-conversation-list"

    package static let messageContentsPrefix = "message-accessibility-contents:"
    package static let conversationPrefix = "conversation-"

    /// The message's uuid from its row's id, or nil for a row that is not a message (the typing bubble).
    package static func messageUUID(fromID id: String?) -> String? {
        guard let id, id.hasPrefix(messageContentsPrefix) else { return nil }
        return String(id.dropFirst(messageContentsPrefix.count))
    }

    /// The conversation's id from an element's id ("conversation-<id>").
    package static func conversationID(fromID id: String?) -> String? {
        guard let id, id.hasPrefix(conversationPrefix) else { return nil }
        return String(id.dropFirst(conversationPrefix.count))
    }

    package enum Direction: Sendable, Equatable { case incoming, outgoing, unknown }

    /// Outgoing wins: a row has both only if Signal ever marks one so, and the filter checked outgoing first.
    package static func direction(classes: [String]) -> Direction {
        if classes.contains(where: { $0.contains(outgoingSuffix) }) { return .outgoing }
        if classes.contains(where: { $0.contains(incomingSuffix) }) { return .incoming }
        return .unknown
    }

    /// Any class with "typing" in it, as the filter matched the typing bubble.
    package static func isTyping(classes: [String]) -> Bool {
        classes.contains { $0.lowercased().contains("typing") }
    }
}

/// What is said. From the tester's VoiceOver Signal Filter (AnnouncementFormatter.swift): the Orca add-on's wording,
/// with the NVDA add-on's "Message received:" for a conversation with one person. Kept in English, as the add-ons say
/// it; the names and the message are the contact's own words.
nonisolated package enum SignalAnnouncement {
    package static func messageSent() -> String { "Message sent." }

    /// One person: "Message received: {text}". A group: "{author}: {text}".
    package static func incomingMessage(text: String?, author: String?) -> String {
        let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            if body.isEmpty { return "Message received from \(author)." }
            return "\(author): \(body)"
        }
        if body.isEmpty { return "Message received." }
        return "Message received: \(body)"
    }

    package static func typingStarted(names: [String]) -> String {
        let names = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        switch names.count {
        case 0: return "Someone is typing."
        case 1: return "\(names[0]) is typing."
        case 2: return "\(names[0]) and \(names[1]) are typing."
        case 3: return "\(names[0]), \(names[1]) and \(names[2]) are typing."
        default: return "\(names[0]) and others are typing."
        }
    }

    package static func typingStopped(names: [String]) -> String {
        let names = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        switch names.count {
        case 0: return "Stopped typing."
        case 1: return "\(names[0]) stopped typing."
        case 2: return "\(names[0]) and \(names[1]) stopped typing."
        default: return "\(names[0]) and others stopped typing."
        }
    }
}

/// Names as Signal's bridge gives them, with bidi isolates and status words round them ("⁨Isabelle⁩ This person is in
/// your contacts." is "Isabelle"). From the tester's VoiceOver Signal Filter (ContactNameCleaner.swift).
nonisolated package enum SignalContactName {
    private static let bidiControls: Set<Character> = [
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{200E}", "\u{200F}",
    ]
    /// Longest and most specific first.
    private static let knownSuffixes = [
        " This person is in your contacts.",
        " This person is in your contacts",
        " This conversation is end-to-end encrypted.",
        " This conversation is end-to-end encrypted",
        " Verified",
        " Unverified",
    ]

    package static func clean(_ raw: String) -> String {
        // The name between the first first-strong isolate (U+2068) and the pop (U+2069) that follows it.
        if let start = raw.firstIndex(of: "\u{2068}") {
            let inner = raw[raw.index(after: start)...]
            if let end = inner.firstIndex(of: "\u{2069}") {
                return String(inner[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var trimmed = String(raw.filter { !bidiControls.contains($0) })
        for suffix in knownSuffixes {
            if let range = trimmed.range(of: suffix) { trimmed = String(trimmed[..<range.lowerBound]) }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The messages already said (or seen while priming), by conversation, the oldest dropped past `capacity`. From the
/// tester's VoiceOver Signal Filter (MessageDedupCache.swift; the Orca add-on's _is_duplicate and _remember).
package struct SignalMessageDedup {
    private struct Conversation { var order: [String] = []; var set: Set<String> = [] }
    private var caches: [String: Conversation] = [:]
    private let capacity: Int

    package init(capacity: Int = 500) { self.capacity = capacity }

    package func contains(uuid: String, conversation: String) -> Bool {
        caches[conversation]?.set.contains(uuid) ?? false
    }

    package mutating func insert(uuid: String, conversation: String) {
        var cache = caches[conversation] ?? Conversation()
        guard cache.set.insert(uuid).inserted else { return }
        cache.order.append(uuid)
        if cache.order.count > capacity { cache.set.remove(cache.order.removeFirst()) }
        caches[conversation] = cache
    }

    package mutating func reset(conversation: String) { caches[conversation] = nil }
}

/// Which conversation is open, whether it has been primed (its messages taken in silently the first time, so opening
/// a chat with unread messages doesn't read them all out), and an epoch that changes with the conversation so a late
/// scan of the old one is dropped. From the tester's VoiceOver Signal Filter (ConversationStateStore.swift).
package struct SignalConversationState {
    package private(set) var current: String?
    package private(set) var epoch = 0
    private var primed: Set<String> = []

    package init() {}

    /// True when it changed. Nil never changes it: the focus off any conversation (the search field, the list) leaves
    /// the last one known, or a typing indicator in progress would be dropped with its "stopped typing".
    @discardableResult
    package mutating func switchTo(_ id: String?) -> Bool {
        guard let id, id != current else { return false }
        current = id
        epoch &+= 1
        return true
    }

    package func isPrimed(_ id: String) -> Bool { primed.contains(id) }
    package mutating func markPrimed(_ id: String) { primed.insert(id) }
}

/// Someone typing, and stopping. From the tester's VoiceOver Signal Filter (TypingStateMachine.swift): it starts as a
/// scan finds the typing bubble; Signal sends no news when the bubble goes, so it is polled, and "stopped typing" is
/// said after two polls in a row without it (polls at least `pollInterval` apart) and a quiet window with no new
/// message (a message arriving as the bubble goes ends it silently: the message is the news). The clock is passed in.
package struct SignalTypingState {
    package static let pollInterval: TimeInterval = 1.2
    package static let quietWindow: TimeInterval = 2.0

    package private(set) var activeConversation: String?
    package private(set) var activeNames: [String] = []
    private var absentPolls = 0
    private var lastPoll: Date?
    private var lastMessageAt: [String: Date] = [:]

    package init() {}

    package var isActive: Bool { activeConversation != nil }

    /// The bubble seen (or its names changed). True when this is news: "is typing" is said.
    package mutating func start(conversation: String, names: [String], current: String?, now: Date) -> Bool {
        guard current == nil || current == conversation else { return false }
        if activeConversation == conversation, activeNames == names { return false }
        activeConversation = conversation
        activeNames = names
        absentPolls = 0
        lastPoll = now
        return true
    }

    /// One look for the bubble. The names to say "stopped typing" for, when it has stopped; nil otherwise.
    package mutating func poll(present: Bool, now: Date) -> [String]? {
        guard let convo = activeConversation else { return nil }
        // Scans come more often than the filter's 1.2 s poll (every second, and on Signal's news): only one that far
        // from the last counts, so "two polls" means what it did in the filter.
        if let last = lastPoll, now.timeIntervalSince(last) < Self.pollInterval { return nil }
        lastPoll = now
        if present { absentPolls = 0; return nil }
        absentPolls += 1
        guard absentPolls >= 2 else { return nil }
        let quiet = lastMessageAt[convo].map { now.timeIntervalSince($0) } ?? .infinity
        guard quiet >= Self.quietWindow else { return nil }
        return cancel()
    }

    /// A new message landed. If the bubble has gone with it, typing ends without a word.
    package mutating func messageArrived(present: Bool, now: Date) {
        absentPolls = 0
        lastMessageAt[activeConversation ?? ""] = now
        if !present { _ = cancel() }
    }

    /// Ends it (another conversation, Signal gone); the names it had, for a "stopped typing" if one is wanted.
    @discardableResult
    package mutating func cancel() -> [String]? {
        let names = activeNames, was = activeConversation
        activeConversation = nil; activeNames = []; absentPolls = 0; lastPoll = nil
        return was != nil && !names.isEmpty ? names : nil
    }
}

/// Coalesces Signal's bursts of news into one scan: each call puts it off by `delay`, but never past `maxWait` from
/// the first, or React's cascading renders would put it off for ever. From the tester's VoiceOver Signal Filter
/// (Debouncer.swift). Pure: the caller asks when to fire.
package struct SignalDebounce {
    package let delay: TimeInterval
    package let maxWait: TimeInterval
    private var first: Date?

    package init(delay: TimeInterval = 0.18, maxWait: TimeInterval = 0.5) { self.delay = delay; self.maxWait = maxWait }

    /// How long from `now` until the scan, for a call at `now`.
    package mutating func schedule(now: Date) -> TimeInterval {
        if first == nil { first = now }
        let elapsed = now.timeIntervalSince(first ?? now)
        return min(delay, max(0, maxWait - elapsed))
    }

    package mutating func fired() { first = nil }
}
