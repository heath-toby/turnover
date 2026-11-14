// SPDX-License-Identifier: GPL-3.0-or-later
// The pure parts of the Signal Filter port (SignalFilterLogic.swift; from the tester's VoiceOver Signal Filter).
import Foundation
import TurnOverCore

func signalFilterTests() {
    test("signal: the filter's wording") {
        expect(SignalAnnouncement.messageSent(), "Message sent.")
        expect(SignalAnnouncement.incomingMessage(text: " hello ", author: nil), "Message received: hello")
        expect(SignalAnnouncement.incomingMessage(text: "hello", author: "Sam"), "Sam: hello")
        expect(SignalAnnouncement.incomingMessage(text: "  ", author: "Sam"), "Message received from Sam.")
        expect(SignalAnnouncement.incomingMessage(text: nil, author: " "), "Message received.")
        expect(SignalAnnouncement.typingStarted(names: []), "Someone is typing.")
        expect(SignalAnnouncement.typingStarted(names: ["Sam", " "]), "Sam is typing.")
        expect(SignalAnnouncement.typingStarted(names: ["Sam", "Alex"]), "Sam and Alex are typing.")
        expect(SignalAnnouncement.typingStarted(names: ["Sam", "Alex", "Jo"]), "Sam, Alex and Jo are typing.")
        expect(SignalAnnouncement.typingStarted(names: ["Sam", "Alex", "Jo", "others"]), "Sam and others are typing.")
        expect(SignalAnnouncement.typingStopped(names: []), "Stopped typing.")
        expect(SignalAnnouncement.typingStopped(names: ["Sam"]), "Sam stopped typing.")
        expect(SignalAnnouncement.typingStopped(names: ["Sam", "Alex"]), "Sam and Alex stopped typing.")
        expect(SignalAnnouncement.typingStopped(names: ["Sam", "Alex", "Jo"]), "Sam and others stopped typing.")
    }

    test("signal: contact names lose their isolates and status words") {
        expect(SignalContactName.clean("\u{2068}Isabelle\u{2069} This person is in your contacts."), "Isabelle")
        expect(SignalContactName.clean("Isabelle This person is in your contacts."), "Isabelle")
        expect(SignalContactName.clean("\u{200E}Sam Verified"), "Sam")
        expect(SignalContactName.clean("  Jo  "), "Jo")
    }

    test("signal: the DOM markers") {
        expect(SignalDOMMarkers.messageUUID(fromID: "message-accessibility-contents:abc-1"), "abc-1")
        check(SignalDOMMarkers.messageUUID(fromID: "message-accessibility-label:abc") == nil, "only the contents id is a row's uuid")
        expect(SignalDOMMarkers.conversationID(fromID: "conversation-xyz"), "xyz")
        check(SignalDOMMarkers.direction(classes: ["module-message__container", "module-message__container--outgoing"]) == .outgoing, "outgoing")
        check(SignalDOMMarkers.direction(classes: ["module-message__container--incoming"]) == .incoming, "incoming")
        check(SignalDOMMarkers.direction(classes: ["module-message__container"]) == .unknown, "unknown")
        check(SignalDOMMarkers.isTyping(classes: ["module-message--typing-bubble"]), "the typing bubble")
        check(!SignalDOMMarkers.isTyping(classes: ["module-message__text"]), "a message")
    }

    test("signal: the de-duplication cache is per conversation and bounded") {
        var d = SignalMessageDedup(capacity: 2)
        d.insert(uuid: "a", conversation: "1")
        check(d.contains(uuid: "a", conversation: "1"), "remembered")
        check(!d.contains(uuid: "a", conversation: "2"), "per conversation")
        d.insert(uuid: "b", conversation: "1"); d.insert(uuid: "c", conversation: "1")
        check(!d.contains(uuid: "a", conversation: "1"), "the oldest falls off")
        check(d.contains(uuid: "b", conversation: "1") && d.contains(uuid: "c", conversation: "1"), "the newest kept")
        d.reset(conversation: "1")
        check(!d.contains(uuid: "c", conversation: "1"), "reset")
    }

    test("signal: a conversation switch is sticky and primes once") {
        var s = SignalConversationState()
        check(s.switchTo("1"), "first conversation")
        let e = s.epoch
        check(!s.switchTo(nil), "no reading keeps the last")
        check(!s.switchTo("1"), "the same one")
        expect(s.current, "1"); expect(s.epoch, e)
        check(!s.isPrimed("1"), "not primed yet")
        s.markPrimed("1")
        check(s.isPrimed("1"), "primed")
        check(s.switchTo("2") && s.epoch == e + 1, "another bumps the epoch")
    }

    test("signal: typing starts once and stops after two absent polls and a quiet window") {
        let t0 = Date(timeIntervalSince1970: 1000)
        var t = SignalTypingState()
        check(t.start(conversation: "1", names: ["Sam"], current: "1", now: t0), "starts")
        check(!t.start(conversation: "1", names: ["Sam"], current: "1", now: t0.addingTimeInterval(0.5)), "the same names again is no news")
        check(!t.start(conversation: "2", names: ["Jo"], current: "1", now: t0), "another conversation's bubble is ignored")
        check(t.poll(present: false, now: t0.addingTimeInterval(0.5)) == nil, "a poll too soon doesn't count")
        check(t.poll(present: false, now: t0.addingTimeInterval(1.3)) == nil, "one absent poll")
        expect(t.poll(present: false, now: t0.addingTimeInterval(2.6)), ["Sam"], "two absent polls, no message: stopped")
        check(!t.isActive, "ended")
    }

    test("signal: the bubble coming back resets the absent count") {
        let t0 = Date(timeIntervalSince1970: 1000)
        var t = SignalTypingState()
        _ = t.start(conversation: "1", names: ["Sam"], current: "1", now: t0)
        check(t.poll(present: false, now: t0.addingTimeInterval(1.3)) == nil, "absent once")
        check(t.poll(present: true, now: t0.addingTimeInterval(2.6)) == nil, "back")
        check(t.poll(present: false, now: t0.addingTimeInterval(3.9)) == nil, "absent once again")
        expect(t.poll(present: false, now: t0.addingTimeInterval(5.2)), ["Sam"], "then stopped")
    }

    test("signal: a message as the bubble goes ends typing silently; a recent message holds the stop") {
        let t0 = Date(timeIntervalSince1970: 1000)
        var t = SignalTypingState()
        _ = t.start(conversation: "1", names: ["Sam"], current: "1", now: t0)
        t.messageArrived(present: false, now: t0.addingTimeInterval(1))
        check(!t.isActive, "ended without a stop")
        _ = t.start(conversation: "1", names: ["Sam"], current: "1", now: t0.addingTimeInterval(2))
        t.messageArrived(present: true, now: t0.addingTimeInterval(2.5))
        check(t.poll(present: false, now: t0.addingTimeInterval(3.3)) == nil, "absent once")
        check(t.poll(present: false, now: t0.addingTimeInterval(4.4)) == nil, "absent twice, but a message 1.9 s ago")
        expect(t.poll(present: false, now: t0.addingTimeInterval(5.6)), ["Sam"], "quiet long enough: stopped")
        _ = t.start(conversation: "1", names: ["Sam"], current: "1", now: t0)
        expect(t.cancel(), ["Sam"], "cancel gives the names")
        check(t.cancel() == nil, "nothing to stop")
    }

    test("signal: the debounce waits, but never past its limit") {
        let t0 = Date(timeIntervalSince1970: 1000)
        var d = SignalDebounce(delay: 0.18, maxWait: 0.5)
        expect(d.schedule(now: t0), 0.18)
        check(abs(d.schedule(now: t0.addingTimeInterval(0.4)) - 0.1) < 0.0001, "capped by the limit")
        expect(d.schedule(now: t0.addingTimeInterval(0.6)), 0)
        d.fired()
        expect(d.schedule(now: t0.addingTimeInterval(1)), 0.18)
    }

    test("signal: settings default on and survive a file without them") {
        let c = try? JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        check(c?.signal == Config.Signal(), "missing section: defaults")
        check(c?.signal.announceSent == true && c?.signal.announceReceived == true && c?.signal.announceTyping == true && c?.signal.announceTypingStopped == true, "all on")
        var s = Config.Signal(); s.announceTyping = false
        let back = (try? JSONEncoder().encode(s)).flatMap { try? JSONDecoder().decode(Config.Signal.self, from: $0) }
        expect(back?.announceTyping, false)
        expect(back?.announceSent, true)
    }

    test("signal: the module covers Signal and Signal Beta") {
        for b in ["org.whispersystems.signal-desktop", "org.whispersystems.signal-desktop-beta"] {
            check(SignalAppModule.bundleIDs.contains(b), "\(b) listed")
        }
    }
}
