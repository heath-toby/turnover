// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's Web settings (14 Nov 2026): the page summary said as a page loads, the loading progress, which
// pictures the arrows reach, and the settings' defaults and migration. The page here is made up.
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func pageSummaryTests() {
    test("page summary: the kinds a page has, in VoiceOver's order, the title first, none left as zero") {
        typealias K = PageSummary.Kind
        let counts = PageSummary.counts([K.link, .heading, .link, .landmark, .form, .heading, .link, .table])
        expect(counts[.link], 3); expect(counts[.heading], 2); expect(counts[.button], nil)
        expect(PageSummary.text(title: "News", counts: counts), "News, 2 headings, 3 links, 1 table, 1 form, 1 landmark")
        expect(PageSummary.text(title: "", counts: [.link: 1]), "1 link", "no title: the counts alone")
        expect(PageSummary.text(title: "  Blank  ", counts: [:]), "Blank", "no counts: the title alone")
        expect(PageSummary.text(title: "", counts: [:]), "")
        expect(PageSummary.text(title: "T", counts: [.image: 4, .heading: 1]), "T, 1 heading", "pictures are not in the summary a page loads with")
        expect(PageSummary.text(title: "T", counts: [.image: 4, .button: 2, .heading: 1], kinds: PageSummary.allKinds), "T, 1 heading, 4 images, 2 buttons", "the summary key says them too")
    }
    test("page summary: what each role and subrole counts as") {
        expect(PageSummary.kind(role: "AXHeading", subrole: ""), .heading)
        expect(PageSummary.kind(role: "AXLink", subrole: ""), .link)
        expect(PageSummary.kind(role: "AXTable", subrole: ""), .table)
        expect(PageSummary.kind(role: "AXGroup", subrole: "AXLandmarkForm"), .form, "a form is not counted among the landmarks")
        expect(PageSummary.kind(role: "AXGroup", subrole: "AXLandmarkNavigation"), .landmark)
        expect(PageSummary.kind(role: "AXTextArea", subrole: ""), .textField)
        expect(PageSummary.kind(role: "AXGroup", subrole: ""), nil, "a plain group (a layout table to WebKit) is not counted")
        expect(PageSummary.kind(role: "AXStaticText", subrole: ""), nil)
        typealias E = WebBuffer.ElementKind
        let lines = [E(role: "AXHeading", headingLevel: 1), E(role: "AXHeading", headingLevel: 2), E(role: "AXGroup", roleDescription: "form"),
                     E(role: "AXGroup", subrole: "AXLandmarkMain"), E(role: "AXGroup", roleDescription: "group"), E(role: "AXLink")]
        expect(PageSummary.text(title: "", counts: PageSummary.counts(lines.compactMap(PageSummary.kind(of:)))),
               "2 headings, 1 link, 1 form, 1 landmark", "from the copy's element kinds: an unnamed form by its role description")
    }
    test("page loading: WebKit's answers, and the percentages said in tens, going up") {
        expect(LoadWatch.state(loaded: nil, progress: nil), nil, "a page that answers neither is not followed")
        expect(LoadWatch.state(loaded: false, progress: 0.3)?.loaded, false)
        expect(LoadWatch.state(loaded: nil, progress: 1)?.loaded, true, "progress alone: done at 1")
        expect(LoadWatch.percentToSay(progress: 0.05, lastSaid: nil), nil, "nothing under ten")
        expect(LoadWatch.percentToSay(progress: 0.34, lastSaid: nil), 30)
        expect(LoadWatch.percentToSay(progress: 0.38, lastSaid: 30), nil, "the same ten once")
        expect(LoadWatch.percentToSay(progress: 0.2, lastSaid: 30), nil, "never going back")
        expect(LoadWatch.percentToSay(progress: 1, lastSaid: 90), nil, "the page announces itself when it is done")
    }
    test("web settings: defaults are the behaviour before them; an old file's say all switch becomes the choice") {
        let decode: (String) -> Config.VirtualBuffers = { try! JSONDecoder().decode(Config.VirtualBuffers.self, from: $0.data(using: .utf8)!) }
        let fresh = Config.VirtualBuffers()
        expect(fresh.pageLoad, "read"); expect(fresh.loadingFeedback, "nothing"); expect(fresh.navigateImages, "always"); expect(fresh.linesPerPage, 20)
        expect(decode("{}").pageLoad, "read")
        expect(decode("{\"autoSayAllOnPageLoad\": false}").pageLoad, "line", "say all off: the title and the first line, as before")
        expect(decode("{\"autoSayAllOnPageLoad\": false, \"pageLoad\": \"summary\"}").pageLoad, "summary", "a choice made is kept")
        let round = decode(String(data: try! JSONEncoder().encode(Config.VirtualBuffers()), encoding: .utf8)!)
        expect(round.linesPerPage, 20); expect(round.navigateImages, "always")
        check(WebBuffer.navigatesImage(described: false, setting: "always"), "always: every picture")
        check(!WebBuffer.navigatesImage(described: false, setting: "described"), "with descriptions: not an undescribed one")
        check(WebBuffer.navigatesImage(described: true, setting: "described"), "with descriptions: a described one")
        check(!WebBuffer.navigatesImage(described: true, setting: "never"), "never: not even a described one")
    }

    /// A page: a heading, a paragraph with two links, a described and an undescribed picture, a picture in a link, a
    /// navigation landmark and a form.
    func page() -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 1, focus: 0, nodes: [])
        func node(_ id: Int, _ parent: Int, _ attrs: [String: AXFixture.Value], kids: [Int] = []) {
            var a = attrs; a["AXParent"] = .element(parent)
            if !kids.isEmpty { a["AXChildren"] = .elements(kids) }
            f.nodes.append(.init(id: id, attrs: a))
        }
        node(10, 0, ["AXRole": .string("AXHeading"), "AXValue": .number(1)], kids: [11])
        node(11, 10, ["AXRole": .string("AXStaticText"), "AXValue": .string("Welcome")])
        node(20, 0, ["AXRole": .string("AXGroup")], kids: [21, 22, 24])
        node(21, 20, ["AXRole": .string("AXStaticText"), "AXValue": .string("Read")])
        node(22, 20, ["AXRole": .string("AXLink")], kids: [23])
        node(23, 22, ["AXRole": .string("AXStaticText"), "AXValue": .string("this")])
        node(24, 20, ["AXRole": .string("AXLink")], kids: [25])
        node(25, 24, ["AXRole": .string("AXStaticText"), "AXValue": .string("that")])
        node(30, 0, ["AXRole": .string("AXImage"), "AXDescription": .string("A red kite")])
        node(31, 0, ["AXRole": .string("AXImage")])
        node(40, 0, ["AXRole": .string("AXLink")], kids: [41])
        node(41, 40, ["AXRole": .string("AXImage"), "AXDescription": .string("Home")])
        node(50, 0, ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXLandmarkNavigation")], kids: [51])
        node(51, 50, ["AXRole": .string("AXStaticText"), "AXValue": .string("Menu")])
        node(60, 0, ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXLandmarkForm")], kids: [61])
        node(61, 60, ["AXRole": .string("AXStaticText"), "AXValue": .string("Search")])
        f.nodes.append(.init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/summary"), "AXParent": .element(1),
                                            "AXChildren": .elements([10, 20, 30, 31, 40, 50, 60])]))
        f.nodes.append(.init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]))
        return f
    }
    test("page summary: counted from the copy, each element once, read again or not") {
        AXReplay.load(page())
        defer { AXReplay.unload() }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        let counts = PageSummary.counts(b.pageKinds.values)
        expect(PageSummary.countsText(counts), "1 heading, 3 links, 1 form, 1 landmark")
        expect(counts[.image], 3)
        b.build()
        expect(PageSummary.counts(b.pageKinds.values), counts, "a second read counts the same")
    }
    test("navigate images: never and with descriptions leave pictures out, but not one in a link") {
        AXReplay.load(page())
        let was = config.virtualBuffers.navigateImages
        defer { AXReplay.unload(); config.virtualBuffers.navigateImages = was }
        @MainActor func text(_ setting: String) -> String {
            config.virtualBuffers.navigateImages = setting
            let b = WebBuffer(webArea: AXReplay.root!)
            b.build()
            return b.text as String
        }
        let graphic = Role.graphic.displayString
        let always = text("always")
        check(always.contains("\(graphic) A red kite"), "always: the described picture")
        check(always.components(separatedBy: graphic).count - 1 == 3, "always: all three pictures")
        let described = text("described")
        check(described.contains("\(graphic) A red kite"), "with descriptions: the described picture")
        check(described.components(separatedBy: graphic).count - 1 == 2, "with descriptions: not the undescribed one")
        let never = text("never")
        check(!never.contains("A red kite"), "never: no picture outside a link")
        check(never.contains("\(graphic) Home"), "never: the picture that is a link's name stays")
        check(never.contains("Welcome") && never.contains("Menu"), "the rest of the page is there")
    }
}
