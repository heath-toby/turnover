// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func mailMessageReadingTests() {
    func load(_ nodes: [AXFixture.Node]) {
        AXReplay.load(.init(app: "Mail public sample", bundle: "test.mail.message", recorded: "", root: 0, application: nil, focus: nil, nodes: nodes))
    }
    test("Mail message lookup: an editable sibling does not hide a read-only message") {
        load([
            .init(id: 0, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([1, 2])]),
            .init(id: 1, attrs: ["AXRole": .string("AXWebArea")]),
            .init(id: 2, attrs: ["AXRole": .string("AXWebArea")]),
        ])
        defer { AXReplay.unload() }
        let message = MailAppModule.messageIn(AXReplay.root!, isEditable: { AXReplay.id(of: $0) == 1 })
        expect(AXReplay.id(of: message), 2)
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "lookup does not focus or change Mail")
    }
    test("Mail message lookup: compose descendants are excluded while the next message level is searched") {
        load([
            .init(id: 0, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([1, 2])]),
            .init(id: 1, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([3])]),
            .init(id: 2, attrs: ["AXRole": .string("AXGroup"), "AXChildren": .elements([4])]),
            .init(id: 3, attrs: ["AXRole": .string("AXWebArea")]),
            .init(id: 4, attrs: ["AXRole": .string("AXWebArea")]),
        ])
        defer { AXReplay.unload() }
        var editabilityAsked: [Int] = []
        let message = MailAppModule.messageIn(AXReplay.root!, isEditable: {
            let id = AXReplay.id(of: $0)!; editabilityAsked.append(id); return id == 1
        })
        expect(AXReplay.id(of: message), 4)
        check(!editabilityAsked.contains(3), "a nested web area in the compose body is never considered received mail")
    }
    test("Mail message lookup: compose-only and message-list descendants remain excluded") {
        load([
            .init(id: 0, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([1, 2, 3, 4])]),
            .init(id: 1, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([5])]),
            .init(id: 2, attrs: ["AXRole": .string("AXTable"), "AXChildren": .elements([5])]),
            .init(id: 3, attrs: ["AXRole": .string("AXOutline"), "AXChildren": .elements([5])]),
            .init(id: 4, attrs: ["AXRole": .string("AXScrollBar"), "AXChildren": .elements([5])]),
            .init(id: 5, attrs: ["AXRole": .string("AXWebArea")]),
        ])
        defer { AXReplay.unload() }
        check(MailAppModule.messageIn(AXReplay.root!, isEditable: { AXReplay.id(of: $0) == 1 }) == nil,
              "no read-only message is exposed outside excluded containers")
    }
    test("Mail message lookup: an oversized first level is refused before inspecting message candidates") {
        var nodes: [AXFixture.Node] = [.init(id: 0, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements(Array(1...201))])]
        for id in 1...201 { nodes.append(.init(id: id, attrs: ["AXRole": .string("AXWebArea")])) }
        load(nodes); defer { AXReplay.unload() }
        var inspected = 0
        check(MailAppModule.messageIn(AXReplay.root!, isEditable: { _ in inspected += 1; return false }) == nil, "level cap includes the initial children")
        expect(inspected, 0)
    }
    test("Mail suggestions: a row's texts are said once each, the name first") {
        expect(MailAppModule.joinedParts(["Ann Smith", " ", "ann@example.com", "Ann Smith"]), "Ann Smith, ann@example.com")
        expect(MailAppModule.joinedParts(["Ann Smith <ann@example.com>", "Ann Smith"]), "Ann Smith <ann@example.com>", "a part inside another is not said again")
        expect(MailAppModule.namePart("Ann Smith, ann@example.com"), "Ann Smith")
        expect(MailAppModule.namePart(""), "")
    }
    test("Mail send: sent only once the window has gone; an alert is not sent") {
        expect(MailAppModule.sendOutcome(windowStillListed: false, alert: false), .sent)
        expect(MailAppModule.sendOutcome(windowStillListed: true, alert: true), .alert)
        expect(MailAppModule.sendOutcome(windowStillListed: true, alert: false), .waiting)
    }
    test("Mail search: the count said from the list, in TurnOver's words") {
        expect(MailAppModule.resultsPhrase(0), "no results")
        expect(MailAppModule.resultsPhrase(1), "1 result")
        expect(MailAppModule.resultsPhrase(12), "12 results")
    }
    test("Mail compose: a field shown since the walk makes the fields be found again") {
        check(MailAppModule.composeCacheMisses(fieldID: "Mail.bccField", fieldCached: false, partsThen: 5, partsNow: 5), "a header field not in the cache")
        check(MailAppModule.composeCacheMisses(fieldID: "Mail.toField", fieldCached: true, partsThen: 5000, partsNow: 6000), "the header's parts changed in number")
        check(!MailAppModule.composeCacheMisses(fieldID: "Mail.toField", fieldCached: true, partsThen: 5, partsNow: 5), "nothing changed: the cache stands")
        check(!MailAppModule.composeCacheMisses(fieldID: "", fieldCached: false, partsThen: 5, partsNow: 5), "a part that isn't a header field (a pop-up held) is no reason")
    }
    test("Mail headers: the message whose sender and subject match the selected row") {
        let shown: [(from: String, subject: String)] = [("Bob Jones", "Re: Plans"), ("Ann Smith", "Re: Plans"), ("Ann Smith", "Other")]
        expect(MailAppModule.bestHeader(sender: "Ann Smith", subject: "Re: Plans", candidates: shown), 1)
        expect(MailAppModule.bestHeader(sender: "Carol", subject: "Nothing alike", candidates: shown), 0, "no match: the first shown")
        expect(MailAppModule.bestHeader(sender: "bob jones", subject: "", candidates: shown), 0)
    }
    test("chat: a Discord message (a titled article group) is not a time stamp; Messages' nameless group is") {
        check(ChatView.isTimeStamp(role: "AXGroup", description: "", title: "", subrole: ""), "Messages' nameless group")
        check(!ChatView.isTimeStamp(role: "AXGroup", description: "", title: "Ann, hello", subrole: "AXDocumentArticle"), "Discord's article")
        check(!ChatView.isTimeStamp(role: "AXGroup", description: "", title: "", subrole: "AXDocumentArticle"), "an article is a message, named or not")
        check(!ChatView.isTimeStamp(role: "AXGroup", description: "Ann, hello, 14:53", title: "", subrole: ""), "a Messages message")
        check(!ChatView.isTimeStamp(role: "AXStaticText", description: "", title: "", subrole: ""), "not a group")
    }
    test("chat: the watcher backs off in a web page's chat while the user types") {
        check(ChatView.watcherLooks(web: false, sinceKey: 0.1, sinceLastLook: 1), "native chats every second, typing or not")
        check(!ChatView.watcherLooks(web: true, sinceKey: 0.1, sinceLastLook: 1), "Discord while typing: not every second")
        check(ChatView.watcherLooks(web: true, sinceKey: 0.1, sinceLastLook: 3), "every three seconds at least")
        check(ChatView.watcherLooks(web: true, sinceKey: 2, sinceLastLook: 1), "not typing: every second")
    }
}
