// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's "While a webpage loads" (VoiceOver Utility, Web): says how far a page has got, or plays a soft tone
// until it has loaded (14 Nov 2026).
//
// WebKit answers two questions on its web area: AXLoaded (whether the page has loaded) and AXLoadingProgress (how far,
// 0 to 1). Neither was seen live: Safari was not open and Mail had no message showing when this was written, so they
// come from WebKit's accessibility wrapper. A web area that answers neither (Chromium, a module's own root) is never
// followed. A page is looked at when the document is made, when the page sends news (a layout change) and just after
// Enter activates something; while loading, every 0.75 s, for a minute at most.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

public enum LoadWatch {
    /// The web area being followed; a new watch or a stop raises the generation, which ends the old ticks.
    private static var watching: AXUIElement?
    private static var generation = 0
    private static var lastCheck = Date.distantPast
    private static var lastPercent: Int?
    private static var lastSaidAt = Date.distantPast

    /// Whether a page that answers neither question is loading: nil, so it is not followed.
    package struct LoadState: Equatable { package let loaded: Bool; package let progress: Double? }
    static func state(of web: AXUIElement) -> LoadState? {
        let loaded = (web.attr("AXLoaded") as? NSNumber)?.boolValue
        let progress = (web.attr("AXLoadingProgress") as? NSNumber)?.doubleValue
        return state(loaded: loaded, progress: progress)
    }
    /// The page's state from WebKit's two answers (a test gives them).
    package static func state(loaded: Bool?, progress: Double?) -> LoadState? {
        if loaded == nil, progress == nil { return nil }
        return LoadState(loaded: loaded ?? ((progress ?? 0) >= 1), progress: progress)
    }

    /// The percentage to say now, if any: in tens, each ten once, going up (WebKit's progress goes back at times as a
    /// page adds what it loads). Nil while it has not reached the next ten, and at 100 (the page announces itself).
    package static func percentToSay(progress: Double, lastSaid: Int?) -> Int? {
        let tens = Int((max(0, min(1, progress)) * 100) / 10) * 10
        guard tens < 100, tens > 0 else { return nil }
        if let lastSaid, tens <= lastSaid { return nil }
        return tens
    }

    /// Look whether the document's page is loading, and follow it if the setting asks. At most every 0.3 s.
    public static func check(_ doc: BrowseModeDocument) {
        let how = config.virtualBuffers.loadingFeedback
        guard how == "progress" || how == "tone" else { return }
        if let w = watching, w.isSame(doc.webArea) { return }
        guard Date().timeIntervalSince(lastCheck) > 0.3 else { return }
        lastCheck = Date()
        guard let s = state(of: doc.webArea), !s.loaded else { return }
        start(doc, how: how)
    }

    /// After Enter activates something (a link): the page may start loading a moment later.
    public static func checkSoon(_ doc: BrowseModeDocument) {
        guard config.virtualBuffers.loadingFeedback != "nothing" else { return }
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak doc] in if let doc { check(doc) } }
        }
    }

    public static func stop() {
        guard watching != nil else { return }
        generation += 1; watching = nil
    }

    private static func start(_ doc: BrowseModeDocument, how: String) {
        generation += 1
        watching = doc.webArea; lastPercent = nil
        Log.io("browse mode: the page is loading; following it (\(how))")
        if how == "progress" { Speech.speakMessage(String(localized: "loading", comment: "Spoken message: a web page is loading")); lastSaidAt = Date() }
        tick(doc, generation, n: 0, how: how)
    }

    private static func tick(_ doc: BrowseModeDocument, _ g: Int, n: Int, how: String) {
        // The tone at once and then each tick; progress is looked at on each.
        if how == "tone" { Tones.beep(880, 30, volume: 0.08) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak doc] in
            guard g == generation, let doc else { return }
            // Another app in front, the setting changed, a minute gone, or the page loaded (or stopped answering).
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == doc.webArea.pid,
                  config.virtualBuffers.loadingFeedback == how, n < 80,
                  let s = state(of: doc.webArea), !s.loaded else { stop(); return }
            if how == "progress", let p = s.progress, Date().timeIntervalSince(lastSaidAt) >= 2,
               let pct = percentToSay(progress: p, lastSaid: lastPercent) {
                lastPercent = pct; lastSaidAt = Date()
                Speech.speakMessage(String(localized: "\(String(pct)) percent", comment: "Spoken message: how far a web page has loaded"))
            }
            tick(doc, g, n: n + 1, how: how)
        }
    }
}
