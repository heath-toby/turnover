// SPDX-License-Identifier: GPL-3.0-or-later
// A page's summary, as VoiceOver's "Speak webpage summary" gives it as a page loads (VoiceOver Utility, Web, "When
// loading a new webpage"): the title, then how many headings, links, tables, forms and landmarks it has, the kinds it
// has only. Counted from the kinds the virtual buffer noted as it read the page (WebBuffer.kinds), so saying it asks
// the page nothing (14 Nov 2026).
import Foundation

public enum PageSummary {
    public enum Kind: CaseIterable, Sendable {
        case heading, link, table, form, landmark, list, image, textField, button
    }
    /// What a page says as it loads, VoiceOver's five.
    public static let loadKinds: [Kind] = [.heading, .link, .table, .form, .landmark]
    /// What the summary key says: those, then lists, pictures, text fields and buttons (what VO-Shift-Vertical Line
    /// said before, 12 Oct 2026).
    public static let allKinds: [Kind] = Kind.allCases

    /// The kind an element counts as, by its role and subrole; nil for anything not counted. A table is a data table:
    /// WebKit gives a layout table as a group, so it is never counted (or read) as a table.
    public static func kind(role: String, subrole: String) -> Kind? {
        switch role {
        case "AXHeading": return .heading
        case "AXLink": return .link
        case "AXTable": return .table
        case "AXList": return .list
        case "AXImage": return .image
        case "AXTextField", "AXTextArea": return .textField
        case "AXButton": return .button
        default: break
        }
        // A form is a landmark to WebKit (AXLandmarkForm); VoiceOver counts it apart from the others.
        if subrole == "AXLandmarkForm" { return .form }
        if subrole.hasPrefix("AXLandmark") { return .landmark }
        return nil
    }

    /// The kind a line's element counts as (WebBuffer.ElementKind): as above, and a form WebKit gives as a plain group
    /// with the role description "form" (an unnamed one, not a landmark) counts as a form too.
    public static func kind(of k: WebBuffer.ElementKind) -> Kind? {
        if k.role == "AXGroup", k.subrole.isEmpty, k.roleDescription == "form" { return .form }
        return kind(role: k.role, subrole: k.subrole)
    }

    public static func counts(_ kinds: some Sequence<Kind>) -> [Kind: Int] {
        var c: [Kind: Int] = [:]
        for k in kinds { c[k, default: 0] += 1 }
        return c
    }

    /// "12 headings, 48 links, 1 table": the kinds asked for that the page has, in that order.
    public static func countsText(_ counts: [Kind: Int], kinds: [Kind] = loadKinds) -> String {
        kinds.compactMap { k in counts[k].flatMap { $0 > 0 ? words(k, $0) : nil } }.joined(separator: ", ")
    }

    /// The title, then the counts; either may be missing.
    public static func text(title: String, counts: [Kind: Int], kinds: [Kind] = loadKinds) -> String {
        [title.trimmingCharacters(in: .whitespacesAndNewlines), countsText(counts, kinds: kinds)].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func words(_ k: Kind, _ n: Int) -> String {
        let one = n == 1
        switch k {
        case .heading: return one ? String(localized: "1 heading", comment: "A count on a page") : String(localized: "\(String(n)) headings", comment: "A count on a page")
        case .link: return one ? String(localized: "1 link", comment: "A count on a page") : String(localized: "\(String(n)) links", comment: "A count on a page")
        case .table: return one ? String(localized: "1 table", comment: "A count on a page") : String(localized: "\(String(n)) tables", comment: "A count on a page")
        case .form: return one ? String(localized: "1 form", comment: "A count on a page") : String(localized: "\(String(n)) forms", comment: "A count on a page")
        case .landmark: return one ? String(localized: "1 landmark", comment: "A count on a page") : String(localized: "\(String(n)) landmarks", comment: "A count on a page")
        case .list: return one ? String(localized: "1 list", comment: "A count on a page") : String(localized: "\(String(n)) lists", comment: "A count on a page")
        case .image: return one ? String(localized: "1 image", comment: "A count on a page") : String(localized: "\(String(n)) images", comment: "A count on a page")
        case .textField: return one ? String(localized: "1 text field", comment: "A count on a page") : String(localized: "\(String(n)) text fields", comment: "A count on a page")
        case .button: return one ? String(localized: "1 button", comment: "A count on a page") : String(localized: "\(String(n)) buttons", comment: "A count on a page")
        }
    }
}
