// SPDX-License-Identifier: GPL-3.0-or-later
// Vision (NVDA: Vision, the focus highlight; VoiceOver: Visuals, the VoiceOver cursor, the caption panel and the
// braille panel). For a sighted helper beside a blind user, and for someone with low vision: a coloured ring round
// the focus, the review cursor and the browse mode reading position; a panel at the bottom of the screen with what
// TurnOver last said; a panel with what the braille display shows, as braille and as text (14 Nov 2026).
//
// Every window here is only to be looked at. They never take the keyboard (non-activating panels that cannot become
// key), the mouse passes through them, and they hide themselves from accessibility, so neither TurnOver nor
// VoiceOver reads them. The ring is drawn as four thin strips round the item, never over it: a hit test inside the
// item (touch exploration, routing the mouse) still lands on the item, not on TurnOver's window.
import AppKit
import ApplicationServices

/// The arithmetic, kept apart so it can be tested.
public enum VisionGeometry {
    /// Accessibility's frame (points from the top left of the main display) as AppKit's (from the bottom left).
    nonisolated public static func cocoa(_ ax: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
    }

    /// The line the ring is drawn along: outside the item by `gap`, so the ring's middle is `width / 2` further out.
    nonisolated public static func ringPath(around item: CGRect, gap: CGFloat, width: CGFloat) -> CGRect {
        item.insetBy(dx: -(gap + width / 2), dy: -(gap + width / 2))
    }

    /// The four windows the ring is drawn in (bottom, top, left, right): the band between the item and the ring's
    /// outer edge. None of them covers the item itself. With a corner radius under (gap + width / 2) / 0.29 the
    /// rounded corners stay inside the band.
    nonisolated public static func strips(around item: CGRect, gap: CGFloat, width: CGFloat) -> [CGRect] {
        let outer = item.insetBy(dx: -(gap + width), dy: -(gap + width))
        return [
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: item.minY - outer.minY),
            CGRect(x: outer.minX, y: item.maxY, width: outer.width, height: outer.maxY - item.maxY),
            CGRect(x: outer.minX, y: item.minY, width: item.minX - outer.minX, height: item.height),
            CGRect(x: item.maxX, y: item.minY, width: outer.maxX - item.maxX, height: item.height),
        ]
    }

    /// The panels' text size for the setting ("small", "medium", "large"; anything else is medium).
    nonisolated public static func fontSize(_ setting: String) -> CGFloat {
        switch setting { case "small": return 13; case "large": return 26; default: return 18 }
    }

    /// A display's cells as Unicode braille (dots 1 to 8 are the bits of each cell, as U+2800 onwards counts them).
    nonisolated public static func unicodeBraille(_ cells: [UInt8]) -> String {
        String(String.UnicodeScalarView(cells.compactMap { Unicode.Scalar(0x2800 + UInt32($0)) }))
    }

    /// The caption's text: what was said a moment ago stays and the new words follow it (a focus change says the
    /// window, then the item, as separate utterances); otherwise the new words replace it. The end is kept.
    nonisolated public static func caption(previous: String, adding text: String, continues: Bool, limit: Int = 300) -> String {
        let joined = continues && !previous.isEmpty ? previous + " " + text : text
        return joined.count > limit ? "…" + String(joined.suffix(limit)) : joined
    }

    /// The text with whole words dropped from its head until `fits` says it fits, so the newest words always show
    /// (at the large size three lines held only the oldest words: a review, 14 Nov 2026). Dropped words become "…".
    /// When not even the last word fits, the last word (the label truncates it).
    nonisolated public static func trimHead(_ text: String, fits: (String) -> Bool) -> String {
        if fits(text) { return text }
        let body = text.hasPrefix("…") ? String(text.dropFirst()) : text
        let words = body.split(separator: " ")
        guard words.count > 1 else { return text }
        func tail(_ k: Int) -> String { "…" + words[k...].joined(separator: " ") }
        // The fewest words dropped that fits (more dropped never fits worse).
        var lo = 1, hi = words.count - 1
        guard fits(tail(hi)) else { return tail(hi) }
        while lo < hi {
            let mid = (lo + hi) / 2
            if fits(tail(mid)) { hi = mid } else { lo = mid + 1 }
        }
        return tail(lo)
    }
}

/// A window of TurnOver's that is only to be looked at: it never takes the keyboard or the mouse, and accessibility
/// does not see it (so TurnOver's own reading, VoiceOver's and hit tests pass it by).
final class LookOnlyPanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        setAccessibilityElement(false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
}

/// One side of a ring: draws the whole rounded rectangle, of which this window shows only its part.
private final class RingStripView: NSView {
    var ring: CGRect = .zero   // the ring's path, in screen coordinates
    var color: NSColor = .systemBlue
    var width: CGFloat = 6
    override var isFlipped: Bool { false }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let w = window else { return }
        let local = ring.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY)
        let path = NSBezierPath(roundedRect: local, xRadius: VisionAids.cornerRadius, yRadius: VisionAids.cornerRadius)
        // A dark edge on each side, so the colour shows on light and dark windows alike.
        path.lineWidth = width
        NSColor.black.withAlphaComponent(0.7).setStroke(); path.stroke()
        path.lineWidth = max(1, width - 2)
        color.setStroke(); path.stroke()
    }
}

/// A ring of four strip windows.
private final class Ring {
    let color: NSColor
    private var panels: [LookOnlyPanel] = []
    private var shownAt: CGRect?
    init(color: NSColor) { self.color = color }

    func show(item: CGRect, gap: CGFloat) {
        let key = item.insetBy(dx: -gap, dy: -gap)
        if shownAt == key, panels.first?.isVisible == true { return }
        shownAt = key
        let width = VisionAids.ringWidth
        let strips = VisionGeometry.strips(around: item, gap: gap, width: width)
        let path = VisionGeometry.ringPath(around: item, gap: gap, width: width)
        while panels.count < strips.count {
            let p = LookOnlyPanel(level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1))
            let v = RingStripView(frame: .zero)
            p.contentView = v
            panels.append(p)
        }
        for (p, r) in zip(panels, strips) {
            guard r.width >= 1, r.height >= 1 else { p.orderOut(nil); continue }
            p.setFrame(r, display: false)
            if let v = p.contentView as? RingStripView { v.ring = path; v.color = color; v.width = width; v.needsDisplay = true }
            p.orderFrontRegardless()
        }
    }

    func hide() {
        shownAt = nil
        for p in panels { p.orderOut(nil) }
    }
}

/// A dark panel at the bottom of the screen with lines of text (the caption panel, the braille panel).
private final class TextPanel {
    private let panel = LookOnlyPanel(level: .statusBar)
    private var labels: [NSTextField] = []
    private(set) var height: CGFloat = 0

    init(lines: Int) {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        box.layer?.cornerRadius = 10
        box.setAccessibilityElement(false)
        panel.contentView = box
        for _ in 0..<lines {
            let l = NSTextField(labelWithString: "")
            l.textColor = .white
            l.isSelectable = false
            l.setAccessibilityElement(false)
            box.addSubview(l)
            labels.append(l)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Lays the lines out across `width`, the bottom edge at `bottom` (screen coordinates), and shows the panel.
    /// The first line may wrap to `wrapLines` lines; the others are one line each.
    func show(_ lines: [(String, NSFont)], screen: NSScreen, bottom: CGFloat, wrapLines: Int) {
        let frame = screen.visibleFrame
        let width = min(frame.width - 40, 1000)
        let pad: CGFloat = 12
        var y = pad
        var placed: [(NSTextField, CGFloat)] = []
        for (i, l) in labels.enumerated() {
            var (text, font) = i < lines.count ? lines[i] : ("", NSFont.systemFont(ofSize: 13))
            l.font = font
            if i == 0, wrapLines > 1, !text.isEmpty {
                // Measured unlimited against `wrapLines` lines' height: the head goes, the newest words stay.
                l.maximumNumberOfLines = 0
                l.lineBreakMode = .byWordWrapping
                let size = NSSize(width: width - 2 * pad, height: 10_000)
                l.stringValue = "Ag"
                let allowed = ceil(l.sizeThatFits(size).height) * CGFloat(wrapLines) + 2
                text = VisionGeometry.trimHead(text) { t in l.stringValue = t; return l.sizeThatFits(size).height <= allowed }
            }
            l.stringValue = text
            l.maximumNumberOfLines = i == 0 ? wrapLines : 1
            l.lineBreakMode = i == 0 && wrapLines > 1 ? .byWordWrapping : .byTruncatingTail
            l.cell?.truncatesLastVisibleLine = true
            l.preferredMaxLayoutWidth = width - 2 * pad
            let h = text.isEmpty ? 0 : ceil(l.sizeThatFits(NSSize(width: width - 2 * pad, height: 10_000)).height)
            placed.append((l, h))
        }
        // From the bottom up: the last line lowest.
        for (l, h) in placed.reversed() {
            l.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: h)
            l.isHidden = h == 0
            if h > 0 { y += h + 4 }
        }
        height = y - 4 + pad
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: bottom, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// The Vision settings at work. Main thread only.
public enum VisionAids {
    static let ringWidth: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    private static let baseGap: CGFloat = 3

    // NVDA's colours: the focus blue, the navigator (review cursor) pink, browse mode's caret yellow.
    private static let focusRing = Ring(color: .systemBlue)
    private static let reviewRing = Ring(color: .systemPink)
    private static let browseRing = Ring(color: .systemYellow)
    private static var timer: Timer?
    private static var pending = false
    /// Apps whose frames are not asked for until then: one that did not answer within the ring's short timeout.
    private static var quietUntil: [pid_t: Date] = [:]

    private static var caption: TextPanel?
    private static var captionText = ""
    private static var captionAt = Date.distantPast
    private static var braillePanel: TextPanel?
    private static var brailleLines: (cells: [UInt8], text: String)?

    private static var vision: Config.Vision { config.vision }
    private static var on: Bool { Core.active }

    /// The settings changed, or TurnOver took over or handed back: show or hide what is wanted.
    public static func apply() {
        let v = vision
        let wantsHighlight = on && v.highlight && (v.highlightFocus || v.highlightReview || v.highlightBrowse)
        if wantsHighlight, timer == nil {
            // Every half second while shown: windows move and scroll with no event TurnOver hears.
            let t = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { updateHighlight() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !wantsHighlight, let t = timer {
            t.invalidate(); timer = nil
        }
        updateHighlight()
        if !(on && v.captionPanel) { caption?.hide(); captionText = "" }
        let brailleWanted = on && v.braillePanel
        if brailleWanted != wantsBraillePanel {
            wantsBraillePanel = brailleWanted
            if brailleWanted { makeBraillePanel() } else { braillePanel?.hide(); brailleLines = nil }
            Braille.panelChanged()   // shown at once, display or not
        }
        layoutPanels()
    }

    /// Hide everything at once (TurnOver hands back to VoiceOver).
    public static func hideAll() {
        timer?.invalidate(); timer = nil
        focusRing.hide(); reviewRing.hide(); browseRing.hide()
        caption?.hide(); captionText = ""
        braillePanel?.hide(); brailleLines = nil
        wantsBraillePanel = false
    }

    // MARK: The highlight

    /// After a script or an event: look again once things settle (the focus moved, the review cursor moved).
    public static func soon() {
        guard timer != nil, !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pending = false; updateHighlight() }
    }

    private static func updateHighlight() {
        let v = vision
        guard on, v.highlight else { focusRing.hide(); reviewRing.hide(); browseRing.hide(); return }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        // A hung app is not asked (a review, 14 Nov 2026: every half second a frame read waited out the 1 s messaging
        // timeout on the main thread): .keep leaves its ring where it was.
        func rect(_ e: AXUIElement?) -> Look {
            guard let e else { return .hidden }
            var pid: pid_t = 0
            AXUIElementGetPid(e, &pid)
            if let q = quietUntil[pid], Date() < q { return .keep }
            if AXHealth.backoff(for: pid) != nil { return .keep }
            switch quickFrame(e, pid: pid) {
            case .timedOut: quietUntil[pid] = Date().addingTimeInterval(3); return .keep
            case .none: return .hidden
            case .frame(let r): return r.width >= 1 && r.height >= 1 ? .at(VisionGeometry.cocoa(r, primaryHeight: primary)) : .hidden
            }
        }
        let doc: BrowseModeDocument? = { if let d = API.focusTreeInterceptor, !d.passThrough { return d }; return nil }()
        let focusElement = API.focusObject?.element
        // In browse mode the focus is often the page itself: a ring round the whole page says nothing.
        let focus = v.highlightFocus && !(doc.map { d in focusElement.map { CFEqual($0, d.webArea) } ?? false } ?? false) ? rect(focusElement) : .hidden
        // The review cursor only once it has left the focus (nil: it follows the focus).
        let reviewElement = ObjectNavigator.shared.reviewElement
        let review = v.highlightReview && !(reviewElement != nil && focusElement != nil && CFEqual(reviewElement!, focusElement!)) ? rect(reviewElement) : .hidden
        let browse = v.highlightBrowse ? rect(doc?.elementAtPosition()) : .hidden
        // Rings round the same item nest, each a step further out, so every colour shows.
        var placed: [CGRect] = []
        for (ring, look) in [(focusRing, focus), (reviewRing, review), (browseRing, browse)] {
            let r: CGRect
            switch look { case .keep: continue; case .hidden: ring.hide(); continue; case .at(let f): r = f }
            let step = CGFloat(placed.filter { $0 == r }.count)
            ring.show(item: r, gap: baseGap + step * (ringWidth + 1))
            placed.append(r)
        }
    }

    /// A hit test landed on one of TurnOver's own windows (a ring's strip, a panel). They hide from accessibility,
    /// but whether the system-wide hit test passes them by is not checked (a review, 14 Nov 2026): callers treat it
    /// as no answer rather than read or move to TurnOver's window.
    nonisolated static func isOwnWindow(_ e: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(e, &pid) == .success && pid == getpid()
    }

    /// What a ring does this time: drawn round a frame, hidden, or kept where it is (its app is not answering).
    private enum Look { case at(CGRect), hidden, keep }
    private enum Frame { case frame(CGRect), none, timedOut }

    /// The frame in one question (position and size together), waiting at most 0.2 s: the ring is not worth a
    /// longer stall on the main thread. The element's own timeout goes back to the global one after.
    private static func quickFrame(_ e: AXUIElement, pid: pid_t) -> Frame {
        AXUIElementSetMessagingTimeout(e, 0.2)
        defer { AXUIElementSetMessagingTimeout(e, 0) }
        var values: CFArray?
        let names = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        let error = AXHealth.query(pid: pid) { AXUIElementCopyMultipleAttributeValues(e, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) }.legacyError
        if error == .cannotComplete { return .timedOut }
        guard error == .success, let list = values as? [AnyObject], list.count == 2,
              CFGetTypeID(list[0]) == AXValueGetTypeID(), CFGetTypeID(list[1]) == AXValueGetTypeID() else { return .none }
        var pt = CGPoint.zero, sz = CGSize.zero
        // A missing attribute comes back as an AXValue of type .axError, which these refuse.
        guard AXValueGetValue(list[0] as! AXValue, .cgPoint, &pt), AXValueGetValue(list[1] as! AXValue, .cgSize, &sz) else { return .none }
        return .frame(CGRect(origin: pt, size: sz))
    }

    // MARK: The caption panel (VoiceOver: Show caption panel)

    /// Speech asks before it queues, so a caption is only made ready when one is shown.
    static var captionWanted: Bool { on && vision.captionPanel }

    /// What speech is saying now, as it starts (never private speech).
    static func spoke(_ text: String) {
        guard on, vision.captionPanel else { return }
        let now = Date()
        captionText = VisionGeometry.caption(previous: captionText, adding: text, continues: now.timeIntervalSince(captionAt) < 0.4)
        captionAt = now
        if caption == nil { caption = TextPanel(lines: 1) }
        layoutPanels()
    }

    /// Speech was stopped (every key does it first): what is said next starts a new caption, so arrowing quickly
    /// down a list shows the item now, not a run of the ones passed.
    static func speechCancelled() { captionAt = .distantPast }

    // MARK: The braille panel (VoiceOver: Show braille panel)

    /// Read by Braille: the panel wants the display's output even when no display is connected.
    public private(set) static var wantsBraillePanel = false

    /// What the display shows now: its cells (cursor and selection dots included) and the text under them.
    static func braille(cells: [UInt8], text: String) {
        guard wantsBraillePanel else { return }
        brailleLines = (cells, text)
        makeBraillePanel()
        layoutPanels()
    }

    private static func makeBraillePanel() {
        if braillePanel == nil { braillePanel = TextPanel(lines: 2) }
    }

    // MARK: Placing the panels

    /// The braille panel sits just above the caption panel, both at the bottom of the screen, as VoiceOver places them.
    private static func layoutPanels() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = VisionGeometry.fontSize(vision.panelFontSize)
        var bottom = screen.visibleFrame.minY + 16
        if on, vision.captionPanel, let c = caption, !captionText.isEmpty {
            c.show([(captionText, NSFont.systemFont(ofSize: size))], screen: screen, bottom: bottom, wrapLines: 3)
            bottom += c.height + 8
        }
        if wantsBraillePanel, let b = braillePanel, let lines = brailleLines {
            let brailleFont = NSFont(name: "Apple Braille", size: size * 1.4) ?? NSFont.systemFont(ofSize: size * 1.4)
            b.show([(VisionGeometry.unicodeBraille(lines.cells), brailleFont), (lines.text, NSFont.monospacedSystemFont(ofSize: size, weight: .regular))],
                   screen: screen, bottom: bottom, wrapLines: 1)
        }
    }
}
