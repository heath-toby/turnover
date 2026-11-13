// SPDX-License-Identifier: GPL-3.0-or-later
// Browse mode, the review of 13 Nov 2026: kinds kept in the copy, V and U and frames found in it, re-reads that keep
// the place and are not made on every key of a slow page, same-page links, focus mode for lists and tables, and table
// moves by logical row and column. The page here is made up.
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func browseModeReviewTests() {
    /// A heading (level 2), a visited and an unvisited link on one line, a frame with text, and text after it.
    func page() -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 1, focus: 0, nodes: [])
        func text(_ id: Int, _ s: String, _ parent: Int) { f.nodes.append(.init(id: id, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(s), "AXParent": .element(parent)])) }
        f.nodes.append(.init(id: 10, attrs: ["AXRole": .string("AXHeading"), "AXValue": .number(2), "AXParent": .element(0), "AXChildren": .elements([11])]))
        text(11, "Title", 10)
        f.nodes.append(.init(id: 20, attrs: ["AXRole": .string("AXLink"), "AXVisited": .bool(true), "AXParent": .element(0), "AXChildren": .elements([21])]))
        text(21, "Seen", 20)
        text(22, " and ", 0)
        f.nodes.append(.init(id: 30, attrs: ["AXRole": .string("AXLink"), "AXVisited": .bool(false), "AXParent": .element(0), "AXChildren": .elements([31])]))
        text(31, "New", 30)
        f.nodes.append(.init(id: 40, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXChildren": .elements([41])]))
        f.nodes.append(.init(id: 41, attrs: ["AXRole": .string("AXWebArea"), "AXParent": .element(40), "AXChildren": .elements([42])]))
        text(42, "Inside frame", 41)
        text(50, "After frame", 0)
        f.nodes.append(.init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/page"), "AXParent": .element(1), "AXChildren": .elements([10, 20, 22, 30, 40, 50])]))
        f.nodes.append(.init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]))
        return f
    }
    func offset(_ b: WebBuffer, _ s: String) -> Int { b.text.range(of: s).location }

    test("browse mode review: the copy keeps what each line's element is, and H finds a heading by its level from it") {
        AXReplay.load(page())
        defer { AXReplay.unload() }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        let first = b.lines[0]
        expect(first.enteringKinds.map(\.role), ["AXHeading"], "the heading entered, kept")
        expect(first.enteringKinds.first?.headingLevel, 2, "its level kept")
        expect(b.find(from: -1, forward: true, roles: ["AXHeading"], headingLevel: 2)?.offset, 0)
        check(b.find(from: -1, forward: true, roles: ["AXHeading"], headingLevel: 3) == nil, "no heading at level 3")
    }

    test("browse mode review: V and U find visited and unvisited links in the copy (Chromium has no search for them)") {
        AXReplay.load(page())
        defer { AXReplay.unload() }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        expect(b.find(from: -1, forward: true, roles: ["AXLink"], visited: true)?.offset, offset(b, "Seen"))
        expect(b.find(from: -1, forward: true, roles: ["AXLink"], visited: false)?.offset, offset(b, "New"))
        expect(b.find(from: -1, forward: true, roles: ["AXLink"])?.offset, offset(b, "Seen"), "K: any link")
        expect(AXReplay.id(of: b.segment(at: offset(b, "New"))?.link), 30, "a link's piece knows its link")
        expect(BrowseModeDocument.visitedFilter("VisitedLink"), true)
        expect(BrowseModeDocument.visitedFilter("UnvisitedLink"), false)
        expect(BrowseModeDocument.visitedFilter("Link"), nil)
        check(BrowseModeDocument.quickNavRoles["VisitedLink"] != nil && BrowseModeDocument.quickNavRoles["UnvisitedLink"] != nil, "V and U search the copy")
        check(BrowseModeDocument.quickNavRoles["FormField"]?.contains("AXButton") == true, "F takes buttons, as NVDA's and Safari's")
        expect(BrowseModeDocument.quickNavRoles["Frame"], ["AXWebArea"], "M finds frames")
    }

    test("browse mode review: a frame in the page is a container, said entering (frame) and found by M") {
        AXReplay.load(page())
        defer { AXReplay.unload() }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        let inside = offset(b, "Inside frame")
        let line = b.lines[b.lineIndex(at: inside)!]
        expect(line.entering.compactMap { AXReplay.id(of: $0) }, [41], "the frame entered with its first line")
        check(b.containers.contains { AXReplay.id(of: $0.element) == 41 && $0.start <= inside && inside < $0.end && $0.end <= offset(b, "After frame") },
              "the frame's span, for out of frame")
        expect(b.find(from: 0, forward: true, roles: ["AXWebArea"])?.offset, inside)
        expect(WebTextInfo.describe(AXReplay.element(41), forEntering: true), "frame")
        check(!b.lines.contains { $0.entering.contains { AXReplay.id(of: $0) == 0 } }, "the page itself is not a frame")
    }

    test("browse mode review: kinds match quick navigation as the page's attributes did") {
        typealias K = WebBuffer.ElementKind
        check(K(role: "AXGroup", subrole: "AXLandmarkMain").matches(roles: ["AXLandmark"]), "landmark")
        check(K(role: "AXGroup", roleDescription: "blockquote").matches(roles: ["AXBlockQuote"]), "block quote by description")
        check(K(role: "AXGroup", subrole: "AXListItem").matches(roles: ["AXListItem"]), "list item")
        check(K(role: "AXGroup", roleDescription: "Highlight").matches(roles: ["Annotation"]), "annotation")
        check(K(role: "AXGroup", roleDescription: "video").matches(roles: ["EmbeddedObject"]), "embedded video")
        check(!K(role: "AXGroup").matches(roles: ["AXLandmark", "AXBlockQuote"]), "a plain group is neither")
        check(K(role: "AXHeading", headingLevel: 3).matches(roles: ["AXHeading"], headingLevel: 3), "heading 3")
        check(!K(role: "AXHeading", headingLevel: 2).matches(roles: ["AXHeading"], headingLevel: 3), "not heading 3")
    }

    test("browse mode review: a dirty page is read again on a key even when slow, but not twice in 1.5 s") {
        check(BrowseModeDocument.mayRebuild(lastBuildMs: 100, age: 1.2, cheapAfter: 1), "cheap, after a second")
        check(!BrowseModeDocument.mayRebuild(lastBuildMs: 100, age: 0.5, cheapAfter: 1), "cheap, too soon for the arrows")
        check(BrowseModeDocument.mayRebuild(lastBuildMs: 100, age: 0), "cheap, any time for a missing element")
        check(BrowseModeDocument.mayRebuild(lastBuildMs: 1800, age: 1.6), "slow, after 1.5 s")
        check(!BrowseModeDocument.mayRebuild(lastBuildMs: 1800, age: 1.0, cheapAfter: 1), "slow, not within 1.5 s")
        check(!BrowseModeDocument.mayRebuild(lastBuildMs: 300, age: 0.2), "slow, never per key")
    }

    test("browse mode review: read again, the reading keeps its line and how far into it it was") {
        let text = "Intro\nNew line added\nThe line read\nEnd\n" as NSString
        // The line was at 6, the reading 4 characters into it; the page grew above it.
        let at = BrowseModeDocument.placeAfterRebuild(oldLine: "The line read", into: 4, oldPosition: 10, in: text)
        expect(at, text.range(of: "The line read").location + 4)
        expect(BrowseModeDocument.placeAfterRebuild(oldLine: "Gone", into: 2, oldPosition: 7, in: text), 7, "line gone: the old offset")
        expect(BrowseModeDocument.placeAfterRebuild(oldLine: "Gone", into: 0, oldPosition: 500, in: text), text.length - 1, "within the copy")
        expect(BrowseModeDocument.placeAfterRebuild(oldLine: "End", into: 9, oldPosition: 0, in: text), text.range(of: "End").location + 3, "no further than the line")
    }

    test("browse mode review: say all at the end of a copy read again goes on past what it read") {
        let old = "Top\nFirst part read\n" as NSString
        expect(BrowseModeDocument.carryOnAfterRebuild(oldText: old, reached: old.length, newText: "Top\nFirst part read\nThe rest\n" as NSString),
               old.length, "more past its end: on from there")
        let grown = "Banner\nTop\nFirst part read\nThe rest\n" as NSString
        expect(BrowseModeDocument.carryOnAfterRebuild(oldText: old, reached: old.length, newText: grown),
               grown.range(of: "The rest").location, "more above too: past the text read last")
        expect(BrowseModeDocument.carryOnAfterRebuild(oldText: old, reached: old.length, newText: "Other\n" as NSString), 6, "all gone: within the copy")
    }

    test("browse mode review: the anchor's climb goes past an element an earlier line's climb ended at") {
        // <div id=x (1)><p (2)><a (3)>link (4)</a> more (5)</p></div>: the first line from 4 climbs 4, 3, 2; the second,
        // from 5, reaches 2 with a level more to go, and so 1.
        let parents = [4: 3, 3: 2, 5: 2, 2: 1, 1: 0]
        expect(BrowseModeDocument.climbToMatch([4, 5], parent: { parents[$0] }, matches: { $0 == 1 }), 1)
        expect(BrowseModeDocument.climbToMatch([4, 5], parent: { parents[$0] }, matches: { $0 == 3 }), 0, "found on the first line")
        expect(BrowseModeDocument.climbToMatch([4, 5], parent: { parents[$0] }, matches: { $0 == 0 }), nil, "past three levels: not")
        expect(BrowseModeDocument.climbToMatch([4, 5], parent: { parents[$0] }, matches: { _ in true }, stop: { true }), nil, "out of time")
    }

    test("browse mode review: a link to this page's anchor is told by its address, the fragment already in the page's or not") {
        expect(BrowseModeDocument.samePageFragment(link: "https://example.com/a#content", page: "https://example.com/a#content"), "content", "Jump to content, a second time")
        expect(BrowseModeDocument.samePageFragment(link: "https://example.com/a#content", page: "https://example.com/a"), "content")
        expect(BrowseModeDocument.samePageFragment(link: "https://example.com/b#content", page: "https://example.com/a"), nil, "another page")
        expect(BrowseModeDocument.samePageFragment(link: "https://example.com/a#", page: "https://example.com/a"), nil, "no fragment")
        expect(BrowseModeDocument.samePageFragment(link: "https://example.com/a", page: "https://example.com/a"), nil)
    }

    test("browse mode review: an anchor added, changed or gone is the same page; another address is not") {
        check(BrowseModeDocument.isSamePage("https://example.com/a#b", "https://example.com/a"), "an anchor followed")
        check(BrowseModeDocument.isSamePage("https://example.com/a", "https://example.com/a#b"), "Back from the anchor")
        check(BrowseModeDocument.isSamePage("https://example.com/a#c", "https://example.com/a#b"), "another anchor")
        check(!BrowseModeDocument.isSamePage("https://example.com/b", "https://example.com/a"), "another page")
        check(!BrowseModeDocument.isSamePage("https://example.com/b#x", "https://example.com/a#x"), "another page with an anchor")
        check(!BrowseModeDocument.isSamePage("https://example.com/a", "https://example.com/a"), "unchanged")
        check(!BrowseModeDocument.isSamePage("https://example.com/a#b", ""), "the first look")
        check(!BrowseModeDocument.isSamePage("https://mail.example.com/mail/u/0/#inbox/FMfcg", "https://mail.example.com/mail/u/0/#inbox"), "a route: a message opened")
        check(!BrowseModeDocument.isSamePage("https://example.com/app/", "https://example.com/app/#/a"), "a route gone: the app's start")
        check(!BrowseModeDocument.isSamePage("https://example.com/app/#!/b", "https://example.com/app/#!/a"), "a hash-bang route")
        check(BrowseModeDocument.isSamePage("https://example.com/a#section-2", "https://example.com/a#section-1"), "plain anchors still are")
    }

    test("browse mode review: focus mode for a list box or grid, not for a plain list or table that took the focus (NVDA)") {
        expect(BrowseModeDocument.focusModeContainer(.list, subrole: "AXContentList", roleDescription: "list"), false)
        expect(BrowseModeDocument.focusModeContainer(.list, subrole: "AXDescriptionList", roleDescription: nil), false)
        expect(BrowseModeDocument.focusModeContainer(.list, subrole: nil, roleDescription: "list box"), true, "a listbox")
        expect(BrowseModeDocument.focusModeContainer(.table, subrole: nil, roleDescription: "table"), false)
        expect(BrowseModeDocument.focusModeContainer(.table, subrole: nil, roleDescription: "grid"), true)
        expect(BrowseModeDocument.focusModeContainer(.comboBox, subrole: nil, roleDescription: nil), nil, "other roles decided elsewhere")
    }

    test("browse mode review: table keys move by logical row and column, across merged cells") {
        @MainActor func to(_ m: NVDATables.Move, _ r: (Int, Int), _ c: (Int, Int), rows: Int = 4, cols: Int = 4) -> [Int]? {
            NVDATables.logicalTarget(m, row: (r.0, r.1), column: (c.0, c.1), rows: rows, columns: cols).map { [$0.row, $0.column] }
        }
        expect(to(.column(1), (1, 1), (0, 2)), [1, 2], "right from a cell two columns wide: past its far side")
        expect(to(.column(-1), (1, 1), (2, 2)), [1, 1], "left from it: the column before its near side")
        expect(to(.row(1), (0, 2), (1, 1)), [2, 1], "down from a cell two rows tall")
        expect(to(.row(-1), (2, 1), (3, 1)), [1, 3], "up keeps the column")
        expect(to(.column(1), (0, 1), (2, 2)), nil, "the last column: the edge")
        expect(to(.row(-1), (0, 1), (0, 1)), nil, "the first row: the edge")
        expect(to(.lastColumn, (1, 1), (3, 1)), nil, "already in the last column")
        expect(to(.firstRow, (2, 1), (1, 1)), [0, 1])
        expect(to(.lastRow, (0, 1), (2, 1)), [3, 2])
    }

    test("browse mode review: Escape in a web dialog says once how browse mode comes back, in the style's keys") {
        expect(BrowseModeDocument.backToBrowseModeHint(keyName: "TurnOver", windowsKeys: true), "TurnOver Space returns to browse mode")
        expect(BrowseModeDocument.backToBrowseModeHint(keyName: "VO", windowsKeys: false), "VO Q returns to browse mode")
    }
}
