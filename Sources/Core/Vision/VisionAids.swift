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
            let (text, font) = i < lines.count ? lines[i] : ("", NSFont.systemFont(ofSize: 13))
            l.font = font
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
        let wantsHighlight = on && v.highlight
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
        func rect(_ e: AXUIElement?) -> CGRect? {
            guard let e, let r = TurnOverObject.frame(e), r.width >= 1, r.height >= 1 else { return nil }
            return VisionGeometry.cocoa(r, primaryHeight: primary)
        }
        let doc: BrowseModeDocument? = { if let d = API.focusTreeInterceptor, !d.passThrough { return d }; return nil }()
        let focusElement = API.focusObject?.element
        // In browse mode the focus is often the page itself: a ring round the whole page says nothing.
        let focus = v.highlightFocus && !(doc.map { d in focusElement.map { CFEqual($0, d.webArea) } ?? false } ?? false) ? rect(focusElement) : nil
        // The review cursor only once it has left the focus (nil: it follows the focus).
        let reviewElement = ObjectNavigator.shared.reviewElement
        let review = v.highlightReview && !(reviewElement != nil && focusElement != nil && CFEqual(reviewElement!, focusElement!)) ? rect(reviewElement) : nil
        let browse = v.highlightBrowse ? rect(doc?.elementAtPosition()) : nil
        // Rings round the same item nest, each a step further out, so every colour shows.
        var placed: [CGRect] = []
        for (ring, r) in [(focusRing, focus), (reviewRing, review), (browseRing, browse)] {
            guard let r else { ring.hide(); continue }
            let step = CGFloat(placed.filter { $0 == r }.count)
            ring.show(item: r, gap: baseGap + step * (ringWidth + 1))
            placed.append(r)
        }
    }

    // MARK: The caption panel (VoiceOver: Show caption panel)

    /// What speech is saying now (never private speech).
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
