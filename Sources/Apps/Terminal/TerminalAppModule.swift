// SPDX-License-Identifier: GPL-3.0-or-later
// Terminal (NVDA: the Windows console support: new output read as it arrives, typing not
// echoed twice, a review cursor for what has scrolled by).
//
// Measured 2 Oct 2026, Terminal on macOS 27: the window holds one AXTextArea, subrole
// AXTerminalTextArea, description "shell", whose AXValue is the whole scrollback padded with
// empty rows to the window's height. AXSelectedTextRange is the cursor. AXLineForIndex,
// AXRangeForLine and AXStringForRange work. Output arrives as AXValueChanged with
// AXSelectedTextChanged on the text area, batched (a command's echo and its first output come
// together; a later line about every second for `sleep 1`). The window title changes with the
// running command.
//
// Only what follows the start of the cursor's line is ever re-read, so a long scrollback costs
// nothing.
import Foundation
import AppKit
import ApplicationServices
import Carbon

final class TerminalAppModule: AppModule {
    static let bundleID = "com.apple.Terminal"
    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        // (7 Oct 2026: Terminal no longer gives the subrole; the text area is still described as "shell".)
        if subrole == "AXTerminalTextArea" { return TerminalText.self }
        guard element.role == "AXTextArea", let description = element.string(kAXDescriptionAttribute) else { return nil }
        // Terminal says "shell" in the language it runs in: "kabuk" on a Turkish Mac, where the module never came in
        // (7 Nov 2026, macOS 27.2, Terminal 2.15: Return went to the edit field's script, new output wasn't read).
        // iTerm2 says "shell".
        return (bundleIdentifier == Self.bundleID ? Self.shellWords : ["shell"]).contains(description) ? TerminalText.self : nil
    }

    /// Terminal's word for "shell" in each of its languages, from the table the description comes from (Accessibility:
    /// that one word, in 42 languages, 21 different words; read once, about 18 ms; 7 Nov 2026, macOS 27.2). All of
    /// them, not the one looked up for TurnOver: that lookup follows TurnOver's own language, and Terminal can run in
    /// another (one set for it in System Settings). Before macOS 15.4 only that one (not tried); without the table,
    /// "shell" alone. Taking all of them takes no other text area: only Terminal's own text areas are asked, the whole
    /// description has to be one of the words, and the table holds nothing but the word Terminal gives its shell, so
    /// another text area would have to be described as a shell too.
    static let shellWords: Set<String> = {
        var words: Set<String> = ["shell"]
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let terminal = Bundle(url: url) else { return words }
        if #available(macOS 15.4, *) {
            for language in terminal.localizations {
                words.insert(terminal.localizedString(forKey: "shell", value: "shell", table: "Accessibility", localizations: [Locale.Language(identifier: language)]))
            }
        } else {
            words.insert(terminal.localizedString(forKey: "shell", value: "shell", table: "Accessibility"))
        }
        return words
    }()
}

final class TerminalText: TurnOverObject {
    /// What TurnOver knows of one terminal (tab or window), kept across the fresh objects made for each event.
    final class State {
        var anchor = -1                 // where the cursor's line started when last read
        var anchorText = ""             // that line as it was
        var typed = ""                  // keys typed since then (the shell echoes them; they are not news)
        var enterAt = Date.distantPast  // the last Return: the line it finished was already heard
        var review: Int?                // the review cursor's line
        var pending = false
        var prompt = ""                 // the shell's prompt line, as last seen with the shell waiting
        var lastOutput: (Int, String, Date)? // the output last read, the anchor it was read from, and when
        var held = false                // output arrived while a menu or sheet was in the way: read on the way back
        var secret = TerminalSecret()   // a password being typed: no character spoken or kept
    }
    static var states: [Int: State] = [:]
    var state: State {
        let k = Int(CFHash(element))
        if let s = Self.states[k] { return s }
        let s = State(); Self.states[k] = s; return s
    }

    override var role: Role { .editableText }
    override var roleText: String? { "terminal" }
    override var name: String { "" }

    // MARK: Text helpers

    private func int(_ attr: String) -> Int? { (element.attr(attr) as? NSNumber)?.intValue }
    private var cursor: Int? {
        guard let v = element.attr(kAXSelectedTextRangeAttribute) else { return nil }
        guard let r = cfRange(v), r.location >= 0, r.location != Int.max else { return nil }
        return r.location
    }
    private func string(_ location: Int, _ length: Int) -> String {
        var r = CFRange(location: location, length: max(0, length))
        guard let v = AXValueCreate(.cfRange, &r), let s = element.param(kAXStringForRangeParameterizedAttribute, v) as? String else { return "" }
        return s
    }
    /// Shell AX positions are UTF-16, while spoken characters are extended graphemes. The old one-unit reads
    /// split supplementary and combining characters (28 Oct 2026, #180). Never fetch AXValue scrollback to repair
    /// an unavailable slice: keep key delivery and leave the unproven character unspoken.
    private func character(at offset: Int) -> String? {
        guard let length = int(kAXNumberOfCharactersAttribute), length >= 0, offset >= 0, offset <= length else { return nil }
        if offset == length { return "" }
        guard let (start, end) = CharacterBoundaries.offsets(at: offset, length: length, read: { start, end in
            self.string(start, end - start)
        }) else { return nil }
        let text = string(start, end - start)
        guard text.utf16.count == end - start, text.count == 1 else { return nil }
        return text
    }

    private func lineIndex(at i: Int) -> Int? {
        (element.param(kAXLineForIndexParameterizedAttribute, NSNumber(value: i)) as? NSNumber)?.intValue
    }
    private func lineRange(_ line: Int) -> CFRange? {
        guard let v = element.param(kAXRangeForLineParameterizedAttribute, NSNumber(value: line)) else { return nil }
        var r = CFRange(); axValue(v, .cfRange, &r); return r
    }
    private func lineText(_ line: Int) -> String? {
        guard let r = lineRange(line) else { return nil }
        return string(r.location, r.length).trimmingCharacters(in: .newlines)
    }
    /// The line the cursor is on: (start, text).
    private func cursorLine() -> (Int, String)? {
        guard let c = cursor, let l = lineIndex(at: c), let r = lineRange(l) else { return nil }
        return (r.location, string(r.location, r.length).trimmingCharacters(in: .newlines))
    }
    /// Where the screen above `start` begins: the start of what the window shows when Terminal says, else 200 lines up;
    /// never more than 40,000 characters back.
    private func screenTop(above start: Int) -> Int {
        var top = 0
        if let v = element.attr(kAXVisibleCharacterRangeAttribute), let r = cfRange(v), r.location >= 0, r.location <= start {
            top = r.location
        } else if let l = lineIndex(at: start), let r = lineRange(max(0, l - 200)) {
            top = min(r.location, start)
        }
        return max(top, start - 40_000)
    }

    /// The last line with anything on it (below it is the window's empty padding).
    private func lastContentLine() -> Int {
        guard let n = int(kAXNumberOfCharactersAttribute), n > 0, var l = lineIndex(at: n - 1) else { return 0 }
        while l > 0, (lineText(l) ?? "").trimmingCharacters(in: .whitespaces).isEmpty { l -= 1 }
        return l
    }

    // MARK: Events

    /// A shell prompt not yet learned (TurnOver started with the shell already open): "user@host folder %" — up to the
    /// first " % ", " $ " or " # " after the "@".
    static func guessPrompt(_ line: String) -> String? {
        guard let at = line.firstIndex(of: "@") else { return nil }
        let tail = line[at...]
        for mark in [" % ", " $ ", " # "] {
            if let r = tail.range(of: mark) { return String(line[..<r.lowerBound]) + mark.trimmingCharacters(in: .whitespaces) }
        }
        for mark in [" %", " $", " #"] where line.hasSuffix(mark) { return line }
        return nil
    }

    /// What differs between two prompts: what is left when their common start and common end are taken away.
    static func changedPart(from old: String, to new: String) -> String {
        let o = old.trimmingCharacters(in: .whitespaces), n = new.trimmingCharacters(in: .whitespaces)
        if o == n { return "" }
        let head = o.commonPrefix(with: n)
        let oRest = String(o.dropFirst(head.count)), nRest = String(n.dropFirst(head.count))
        let tail = String(String(oRest.reversed()).commonPrefix(with: String(nRest.reversed())).reversed())
        let middle = String(nRest.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        return middle.isEmpty ? n : middle
    }

    /// A line that is the shell's prompt coming back: the same start (user@host) and the same last character
    /// as the prompt seen before. ("Password:" or a program's question is not, and is read.)
    private func isPrompt(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces), p = state.prompt.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !p.isEmpty, let last = p.last, t.last == last else { return false }
        let head = p.split(separator: " ").first.map(String.init) ?? p
        return t.hasPrefix(head)
    }

    override func event_gainFocus() {
        let s = state
        // Back from a menu or a sheet with output held meanwhile: that first, from where the reading left off.
        if s.held, !AXHandler.shared.isMenuOpen, !AXHandler.modalInFront(pid: pid) {
            s.held = false
            API.setFocusObject(self, ancestors: API.focusAncestors)   // the guard in readNewOutput asks for the focus
            readNewOutput()
            return
        }
        if let (start, text) = cursorLine() { s.anchor = start; s.anchorText = text }
        if let line = cursorLine()?.1, let last = line.trimmingCharacters(in: .whitespaces).last, "%$#>❯➜".contains(last) { s.prompt = line }
        s.review = nil
        let line = cursorLine()?.1.trimmingCharacters(in: .whitespaces) ?? ""
        Speech.speakMessage(["terminal", line].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    override func event_typedCharacter(_ ch: Character) {
        let s = state
        if ch == "\r" || ch == "\n" {
            // The Return script has usually noted it, before the key went (with the line it finished).
            if Date().timeIntervalSince(s.enterAt) > 0.3 { noteReturn(cursorLine()?.1) }
            s.enterAt = Date(); s.typed = ""
            Speech.speakTypedCharacter(ch, inEditable: true)
            return
        }
        // At a password prompt (sudo, ssh, a passphrase): never the character, "star" as NVDA says in a password field.
        // Terminal echoes nothing there, so the cursor's line still ends with the prompt (a review, 13 Nov 2026: the
        // password was spoken aloud). Nor kept in the typed-so-far, which is compared with the echo.
        if Self.atPasswordPrompt(cursorLine()?.1) { s.secret.sawPrompt() }
        if IsSecureEventInputEnabled() || s.secret.isSecret(now: Date()) {
            s.secret.keyTypedAhead(backspace: ch == "\u{8}", at: Date())
            Speech.clearTypedWordBuffer()
            Speech.speakMessage(String(localized: "star", comment: "A typed character hidden, as in a password field"), remember: false)
            return
        }
        if ch == "\u{8}" { if !s.typed.isEmpty { s.typed.removeLast() } }
        else { s.typed.append(ch) }
        Speech.speakTypedCharacter(ch, inEditable: true)
    }

    /// Return went: a password typed at a prompt ends; after `sudo …`, `ssh host`, `su` or `passwd` the password is
    /// often typed ahead, before the prompt is drawn (a review, 13 Nov 2026: those keys were read aloud).
    private func noteReturn(_ line: String?) {
        state.secret.returnPressed(commandLine: line ?? "", at: Date())
    }

    /// A line that asks for a password, or secure input on (Terminal's Secure Keyboard Entry, a prompt's own).
    static func atPasswordPrompt(_ line: String?) -> Bool {
        if IsSecureEventInputEnabled() { return true }
        return TerminalRules.isPasswordPrompt(line)
    }

    override func event_caret() {}   // the cursor moves with every byte of output: the value change speaks

    override func event_valueChange() {
        let s = state
        guard !s.pending else { return }
        s.pending = true
        // Output arrives in bursts: gather a moment's worth and read it once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [self] in
            s.pending = false
            readNewOutput()
        }
    }

    /// Read what changed from the start of the cursor's old line to the end.
    private func readNewOutput() {
        let s = state
        // Not over a menu, or a sheet or dialog that has the keyboard (Terminal's "terminate running processes?"):
        // a command printing every second talked over both (15 Oct 2026). The anchor stays, so what came
        // meanwhile is read on the way back to the terminal.
        if AXHandler.shared.isMenuOpen || TurnOverMenu.shared.isOpen || AXHandler.modalInFront(pid: pid)
            || !(API.focusObject?.isSameElement(as: self) ?? false) {
            Log.io("terminal: new output held (menu, sheet, or the keyboard elsewhere)")
            s.held = true
            return
        }
        guard let total = int(kAXNumberOfCharactersAttribute) else { return }
        // Up and Down recall history: the whole command, as NVDA reads the new line ("python3 hello.py", not the
        // "hello.py" that differs from the command before). A command may span lines (printf with newlines): it runs
        // from the last line that starts with the prompt to the end.
        if ["kb:upArrow", "kb:downArrow"].contains(InputManager.lastKeyIdentifier), Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1 {
            let p = s.prompt.trimmingCharacters(in: .whitespaces)
            var l = lastContentLine(); var parts: [String] = []; var found = false
            while l >= 0, parts.count < 40, let t = lineText(l) {
                // The prompt line: the prompt learned, or any "user@host folder %" (the folder may have changed since).
                if let here = (!p.isEmpty && t.hasPrefix(p)) ? p : Self.guessPrompt(t) {
                    parts.insert(String(t.dropFirst(here.count)), at: 0); found = true; break
                }
                parts.insert(t, at: 0); l -= 1
            }
            // No shell prompt above (a program's own prompt, Python's >>>): just the line the cursor is on.
            if !found { parts = [cursorLine()?.1 ?? parts.last ?? ""] }
            let command = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let (start, text) = cursorLine() { s.anchor = start; s.anchorText = text } else { s.anchor = total }
            s.review = nil
            Speech.speakText(command.isEmpty ? Phrases.blank : command)
            return
        }
        if s.anchor > total, let (start, text) = cursorLine() {
            // Cleared (clear, Command-K): the text is shorter than the anchor. Whatever arrived in the same batch
            // (clear; ls) is above the cursor's line, from the first line with anything on it; the prompt alone there
            // is nothing new (a review, 13 Nov 2026: that output was lost to the re-anchoring).
            // Only the screen above the cursor is looked in, never from the text's start: what is left of an old
            // scrollback (or more than 40,000 characters back) was read as new. Output on the cursor's own line with
            // no newline after it ("clear; printf hi": "hi" then the prompt) is read too (a review, 13 Nov 2026).
            s.anchor = start; s.anchorText = text
            let top = screenTop(above: start)
            guard let first = TerminalRules.firstContentLineStart(string(top, start - top)) else {
                let own = TerminalRules.outputBeforePrompt(text, prompt: s.prompt)
                guard !own.isEmpty else { return }
                Log.io("terminal: read \(own.count) characters (the cursor's line after clear)")
                s.lastOutput = (start, own, Date())
                Speech.speakNews(own)
                return
            }
            s.anchor = top + first; s.anchorText = ""
            s.enterAt = .distantPast   // its first line is output, not the command line just heard
        }
        guard s.anchor >= 0, s.anchor <= total else {
            if let (start, text) = cursorLine() { s.anchor = start; s.anchorText = text }
            return
        }
        let from = s.anchor
        let region = string(s.anchor, min(total - s.anchor, 40_000))
        var lines = region.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { lines.removeLast() }
        guard let first = lines.first else { return }
        var rest = Array(lines.dropFirst())
        // Keys typed ahead of a password prompt are echoed by the terminal at the start of the next line, before the
        // prompt ("abc[sudo] password for toby:"): taken off, not read.
        if !rest.isEmpty, s.secret.aheadKeys > 0 { rest[0] = TerminalRules.withoutTypedAhead(rest[0], keys: s.secret.aheadKeys) }
        var speech: [String] = []


        // A password being typed: what appears on the cursor's line is its echo (sudo-rs and pwfeedback draw a star
        // per key; the line discipline echoes keys typed ahead of the prompt), never read.
        if rest.isEmpty, s.secret.isSecret(now: Date()) {
            // The secret's echo, never read. But the prompt itself arriving on the line (ssh's "toby@host's
            // password:", drawn after Return's newline was read on its own) is said: it was silenced as echo, and the
            // user never heard that a password was asked for (a review, 13 Nov 2026). Typed-ahead echo and stars off.
            // In the window a password-asking command opened, any line ending in a colon is its prompt (in the user's
            // language, a review, 14 Nov 2026).
            let ahead = !s.secret.latched
            func asks(_ l: String) -> Bool { TerminalRules.isPasswordPrompt(l) || (ahead && TerminalRules.isPromptInSecretWindow(l, aheadKeys: s.secret.aheadKeys)) }
            if asks(first), !asks(s.anchorText) {
                let line = TerminalRules.withoutTypedAhead(first, keys: s.secret.aheadKeys)
                let words = line.trimmingCharacters(in: CharacterSet(charactersIn: " *•●"))
                if !words.isEmpty { speech.append(words) }
            }
        } else if rest.isEmpty {
            // The same line: typing echoed by the shell (silent), a completion or a recalled command (the new part).
            let common = first.commonPrefix(with: s.anchorText)
            let added = String(first.dropFirst(common.count)).trimmingCharacters(in: .whitespaces)
            let justTyped = Date().timeIntervalSince(InputManager.lastKeyDownAt) < 0.5 && added.count <= 1
            if !added.isEmpty, !justTyped, added != s.typed.trimmingCharacters(in: .whitespaces), !s.typed.hasSuffix(added) { speech.append(added) }
            if added == s.typed.trimmingCharacters(in: .whitespaces) { s.typed = "" }
        } else {
            // New lines: the finished command line was heard as it was typed; the rest is output.
            // Only the first change after Return finishes the command line; later lines are all output.
            let finishedByEnter = Date().timeIntervalSince(s.enterAt) < 5
            s.enterAt = .distantPast
            if !finishedByEnter {
                let common = first.commonPrefix(with: s.anchorText)
                let added = String(first.dropFirst(common.count)).trimmingCharacters(in: .whitespaces)
                if !added.isEmpty { speech.append(added) }
            }
            var output = rest
            // Output with no newline before the prompt ("printf hi": "hiuser@host ~ %"): only the output.
            if let last = output.last, !isPrompt(last), !s.prompt.isEmpty, last.hasSuffix(s.prompt.trimmingCharacters(in: .whitespaces)) {
                let own = TerminalRules.outputBeforePrompt(last, prompt: s.prompt)
                output.removeLast()
                if !own.isEmpty { output.append(own) }
            }
            // The prompt coming back after the output: the same prompt is not news; a changed one is (after cd,
            // the folder), and only the part that changed is read: "Audible", not the whole user@host line.
            if let last = output.last, isPrompt(last) {
                output.removeLast()
                let changed = Self.changedPart(from: s.prompt, to: last)
                s.prompt = last
                if !changed.isEmpty { output.append(changed) }
            }
            speech.append(contentsOf: output)
            s.typed = ""
        }

        if let (start, text) = cursorLine() { s.anchor = start; s.anchorText = text } else { s.anchor = total }
        // The prompt drawn: what is typed now is the password. Other new lines: typing ahead is over.
        // Only lines with something besides the typed-ahead echo (taken off above) are output: the first key's echo can
        // land in the same batch as Return's newline, and ended the secret at once (a review, 13 Nov 2026).
        // Inside the window a password-asking command opened (sudo, ssh, openssl), the cursor's line ending in a colon,
        // with no newline after it, is its prompt whatever its words ("[sudo] parola per toby:"): latched, where it
        // closed the secret as output and the password was read (a review, 14 Nov 2026). The typed-ahead echo starts
        // the first new line, so it is taken off only when the cursor's line is that one.
        // (Only as the first thing after the Return that opened it, not after a retry, and not under other output:
        // a whole dialog of questions after it was starred, a review, 14 Nov 2026.)
        // (After other lines in the same batch, only when the cursor's line is the last of them: a lecture or a build's
        // output before sudo's prompt. In a retry window, only the very prompt latched before.)
        let cursorTrimmed = s.anchorText.trimmingCharacters(in: .whitespaces)
        let cursorIsLast = rest.last.map { $0.trimmingCharacters(in: .whitespaces) == cursorTrimmed } ?? true
        let samePromptAgain = s.secret.retryWindow && s.secret.lastPrompt == cursorTrimmed && !cursorTrimmed.isEmpty
        let inWindow = !s.secret.latched && s.secret.isSecret(now: Date()) && !isPrompt(s.anchorText)
            && (samePromptAgain || (!s.secret.retryWindow && (rest.count <= 1 || cursorIsLast)
                && TerminalRules.isPromptInSecretWindow(s.anchorText, aheadKeys: rest.count <= 1 ? s.secret.aheadKeys : 0)))
        if TerminalRules.isPasswordPrompt(s.anchorText) || inWindow { s.secret.sawPrompt(s.anchorText) }
        else if !TerminalRules.allBlank(rest) { s.secret.outputArrived() }
        // The shell's prompt drawn on the cursor's line on its own (sudo with its credentials kept, a slow prompt): the
        // command is over, so typing is no password; the next command was said as "star" (a review, 13 Nov 2026).
        else if isPrompt(s.anchorText) { s.secret.outputArrived() }
        s.review = nil
        var out = TerminalRules.withoutRules(speech.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        // A full-screen program redrawing its input box as you type (Claude Code: the line typed so far and the box's
        // rules, read after every letter, a tester, 13 Nov 2026): just after a typed key, the cursor's own line (the box
        // being typed in) isn't output. Only that line: short real output ("done", a y/n prompt's answer) is kept (a review).
        // (Not after Return: a program's prompt arrives on the cursor's line, "Password:", and was lost. An echo ends
        // with the character just typed; a prompt doesn't. A review, 13 Nov 2026.)
        let key = InputManager.lastKeyIdentifier.replacingOccurrences(of: "kb:", with: "").replacingOccurrences(of: "shift+", with: "")
        if InputManager.lastKeyWasTyped, key.count == 1, Date().timeIntervalSince(InputManager.lastKeyDownAt) < 0.6, let (_, cur) = cursorLine() {
            out = TerminalRules.withoutEcho(out, cursorLine: cur, typed: key)
        }
        guard !out.isEmpty else { return }
        // The same output again a moment later: iTerm2 moves its cursor after the text arrives, so the next change
        // starts from the old line and finds it again ("second test" twice, parts sweep 15 Oct 2026). Only when read
        // from the same anchor: the same output of a new command (echo hi twice) starts from a new line and is news
        // (a review, 13 Nov 2026: the second was silent).
        Log.io("terminal: read \(out.count) characters (\(rest.isEmpty ? "same line" : "\(rest.count) new lines"), anchor \(s.anchor))")
        if let (anchor, last, at) = s.lastOutput, anchor == from, last == out, Date().timeIntervalSince(at) < 1.5 { return }
        s.lastOutput = (from, out, Date())
        Speech.speakNews(out.count > 5000 ? String(out.prefix(5000)) + " … and more" : out)
    }

    // MARK: Review (NVDA's review cursor; VoiceOver's VO+Up and VO+Down in text)

    override func initOverlay() {
        super.initOverlay()
        let cat = "Terminal"
        // Return: the command goes; the word typed last is spoken (typed words), and what follows is output.
        script("terminal_enter", String(localized: "Sends the command line to the shell", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:numpadEnter"], category: cat) { [weak self] g in
            guard let self else { g.send(); return }
            let s = self.state
            self.noteReturn(self.cursorLine()?.1)
            s.enterAt = Date()
            s.typed = ""
            Speech.speakTypedCharacter("\n", inEditable: true)
            g.send()
        }
        script("terminal_reviewPrevious", String(localized: "Previous line of output; reads the previous line of the terminal, without disturbing the shell", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+upArrow"], category: cat) { [weak self] _ in self?.review(-1) }
        script("terminal_reviewNext", String(localized: "Next line of output; reads the next line of the terminal", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+downArrow"], category: cat) { [weak self] _ in self?.review(1) }
        script("terminal_reviewTop", String(localized: "Reads the first line of the terminal's history", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+home"], category: cat) { [weak self] _ in self?.reviewTo(top: true) }
        script("terminal_reviewBottom", String(localized: "Reads the last line of output", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+end"], category: cat) { [weak self] _ in self?.reviewTo(top: false) }
        script("terminal_reviewCurrent", String(localized: "Reads the line the review cursor is on; the cursor's line if it has not moved", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+l"], category: cat) { [weak self] _ in self?.review(0) }
        // Editing keys, as in any edit field: what was deleted is said, and where the cursor went.
        script("terminal_backspace", String(localized: "Deletes the character before the cursor and says it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:backspace"], category: cat) { [weak self] g in
            // A password: the key goes, nothing is said (before the cursor is the prompt's colon, or a star).
            if let self, self.state.secret.isSecret(now: Date()) { self.state.secret.keyTypedAhead(backspace: true, at: Date()); g.send(); return }
            guard let self, let c = self.cursor, !self.atInputStart(c) else { Tones.edge(); g.send(); return }
            let ch = self.character(at: c - 1)
            g.send()
            if !self.state.typed.isEmpty { self.state.typed.removeLast() }
            Speech.clearTypedWordBuffer()
            if let ch { self.sayCharacter(ch) }
        }
        script("terminal_deleteForward", String(localized: "Deletes the character at the cursor and says it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:delete"], category: cat) { [weak self] g in
            guard let self, let c = self.cursor else { g.send(); return }
            let ch = self.character(at: c)
            g.send()
            guard let ch else { return }
            if ch.isEmpty || ch == "\n" || self.inputAfter(c).isEmpty { Tones.edge() } else { self.sayCharacter(ch) }
        }
        script("terminal_deleteWord", String(localized: "Deletes the word before the cursor and says it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+backspace", "kb:control+w"], category: cat) { [weak self] g in
            if let self, self.state.secret.isSecret(now: Date()) { g.send(); return }
            guard let self, let c = self.cursor, !self.atInputStart(c) else { Tones.edge(); g.send(); return }
            let before = self.inputBefore(c)
            let trimmed = before.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let word = trimmed.split(whereSeparator: { $0 == " " || $0 == "/" }).last.map(String.init) ?? trimmed
            g.send()
            // Deleted text is typing: kept out of the speech history and feedback, as typed characters are (a review,
            // 13 Nov 2026: a mistyped password, deleted, was kept there).
            Speech.asPrivate { Speech.speakText(word.isEmpty ? String(localized: "space", comment: "Spoken message") : word) }
        }
        script("terminal_clearLine", String(localized: "Clears what has been typed on the command line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:control+u"], category: cat) { [weak self] g in
            g.send()
            self?.state.typed = ""
            Speech.speakMessage(String(localized: "line cleared", comment: "Spoken message"), remember: false)
        }
        for (key, forward) in [("option+leftArrow", false), ("option+rightArrow", true)] {
            script("terminal_word_\(forward ? "next" : "previous")", "Moves the shell's cursor by a word and reads it", gestures: ["kb:\(key)"], category: cat) { [weak self] g in
                g.send()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    guard let self, let c = self.cursor else { return }
                    let after = self.inputAfter(c)
                    let word = after.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? ""
                    if word.isEmpty { Tones.edge(); Speech.speakText(String(localized: "blank", comment: "Spoken message")) } else { Speech.speakText(word) }
                }
            }
        }
        for (key, start) in [("control+a", true), ("control+e", false)] {
            script("terminal_line\(start ? "Start" : "End")", start ? "Moves to the start of the command line and reads it" : "Moves to the end of the command line", gestures: ["kb:\(key)"], category: cat) { [weak self] g in
                g.send()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    guard let self, let c = self.cursor else { return }
                    let rest = self.inputAfter(c)
                    Speech.speakText(start ? (rest.isEmpty ? Phrases.blank : rest) : String(localized: "end", comment: "The end of the typed command line"))
                }
            }
        }
        // Left and Right go to the shell; then the character under the cursor is read, as in an edit field.
        // Always sent: at column 0 or a line's end the key still means something to nano, vim or a program's input
        // box, which the shell's prompt doesn't describe (a review, 13 Nov 2026: Left at column 0 and Right at the
        // end never reached them). A bump, as an edit field gives, only when the cursor didn't move.
        // Looked at after 50 ms and again at 150 ms before the bump: over ssh, or in vim, the cursor moves later, and
        // one look at 50 ms gave a false edge and silence (a review, 13 Nov 2026).
        for key in ["leftArrow", "rightArrow"] {
            script("terminal_\(key)", String(localized: "Moves the shell's cursor and reads the character there", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:\(key)"], category: cat) { [weak self] g in
                let before = self?.cursor
                g.send()
                self?.readCharacterAfterMove(from: before, at: [0.05, 0.15])
            }
        }
    }

    /// The character under the cursor once it has moved from `before`, looked at after each delay in turn (seconds
    /// from the key); a bump when it never moved.
    private func readCharacterAfterMove(from before: Int?, at delays: [Double], waited: Double = 0) {
        guard let next = delays.first else { Tones.edge(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next - waited)) { [weak self] in
            guard let self, let c = self.cursor else { return }
            if c == before { self.readCharacterAfterMove(from: before, at: Array(delays.dropFirst()), waited: next); return }
            guard let ch = self.character(at: c) else { return }
            Speech.speakText(ch.isEmpty || ch == "\n" ? "blank" : ch, symbolLevel: .all)
        }
    }

    // MARK: The command line being typed

    /// The cursor's line from its start to the cursor, and from the cursor to the end.
    private func inputBefore(_ c: Int) -> String {
        guard let l = lineIndex(at: c), let r = lineRange(l) else { return "" }
        let before = string(r.location, c - r.location)
        // Without the prompt, when the line starts with it.
        let p = state.prompt.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty, before.hasPrefix(p) { return String(before.dropFirst(p.count)).replacingOccurrences(of: "^\\s", with: "", options: .regularExpression) }
        return before
    }
    private func inputAfter(_ c: Int) -> String {
        guard let l = lineIndex(at: c), let r = lineRange(l) else { return "" }
        return string(c, r.location + r.length - c).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The cursor is right after the prompt: nothing typed to delete.
    private func atInputStart(_ c: Int) -> Bool {
        guard let l = lineIndex(at: c), let r = lineRange(l) else { return false }
        let before = string(r.location, c - r.location)
        if before.isEmpty { return true }
        let p = state.prompt.trimmingCharacters(in: .whitespaces)
        return !p.isEmpty && before.trimmingCharacters(in: .whitespaces) == p
    }
    private func sayCharacter(_ ch: String) {
        guard let first = ch.first, ch != "\n" else { Speech.speakText(String(localized: "blank", comment: "Spoken message")); return }
        Speech.asPrivate { Speech.speakText(Symbols.name(of: first)) }   // deleted typing: private, as typed characters are
    }

    private func review(_ step: Int) {
        let s = state
        let here = s.review ?? (cursor.flatMap { lineIndex(at: $0) } ?? lastContentLine())
        var target = here + step
        let last = lastContentLine()
        if target < 0 { target = 0; Tones.edge() }
        if target > last { target = last; Tones.edge() }
        s.review = target
        let t = (lineText(target) ?? "").trimmingCharacters(in: .whitespaces)
        Speech.speakItem(t.isEmpty ? Phrases.blank : t, processed: true)   // on the display too, until the shell line moves (8 Oct 2026)
    }

    private func reviewTo(top: Bool) {
        let s = state
        let target = top ? 0 : lastContentLine()
        s.review = target
        let t = (lineText(target) ?? "").trimmingCharacters(in: .whitespaces)
        Speech.speakItem(t.isEmpty ? Phrases.blank : t, processed: true)   // on the display too, until the shell line moves (8 Oct 2026)
    }
}

/// Terminal output as it is read (pure, tested).
package enum TerminalRules {
    /// Where the first line with anything on it starts, in UTF-16 units as Terminal counts; nil when all is blank. Pure.
    package nonisolated static func firstContentLineStart(_ text: String) -> Int? {
        guard let i = text.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let lineStart = text[..<i].lastIndex(where: { $0.isNewline }).map { text.index(after: $0) } ?? text.startIndex
        return text.utf16.distance(from: text.utf16.startIndex, to: lineStart)
    }

    /// A line that asks for a secret: it ends with ":" and has the word "password", "passphrase" or "pin" in it, in
    /// any case. Whole words, so ssh-keygen's "Enter passphrase (empty for no passphrase):", "Enter same passphrase
    /// again:" and ssh's "Enter PIN for 'key':" are prompts (a review, 13 Nov 2026: the passphrase typed there was
    /// read aloud, only lines ending "passphrase:" were known), while "Spinning up:" is not. Pure.
    /// The stars or dots a prompt draws per key (sudo-rs, sudo's pwfeedback: "Password: ***") are taken off first:
    /// after the first key the line no longer ended with ":", and the rest was read (a review, 13 Nov 2026).
    /// Also "pass phrase" in two words (OpenSSL: "Enter PEM pass phrase:") and the word in other languages, as sudo
    /// asks in the user's own ("[sudo] Passwort für toby:", "[sudo] toby 的密码："): those passwords were read aloud (a
    /// review, 14 Nov 2026). Chinese, Japanese and Korean by containment, as they run on into the words around them.
    package nonisolated static func isPasswordPrompt(_ line: String?) -> Bool {
        guard let l = promptLine(line) else { return false }
        let words = l.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let single: Set<String> = ["password", "passphrase", "pin", "passwort", "kennwort", "parola", "contraseña", "senha",
                                   "wachtwoord", "lösenord", "пароль", "passord", "adgangskode", "salasana", "hasło", "heslo"]
        if words.contains(where: { single.contains($0) }) { return true }
        let spaced = " " + words.joined(separator: " ") + " "
        if [" pass phrase ", " mot de passe "].contains(where: { spaced.contains($0) }) { return true }
        return ["密码", "密碼", "パスワード", "비밀번호", "암호"].contains { l.contains($0) }
    }

    /// A line ending with a colon (ASCII or full-width), lowercased, the stars a prompt draws per key taken off; nil
    /// when it doesn't end so. Pure.
    package nonisolated static func promptLine(_ line: String?) -> String? {
        guard var l = line?.lowercased() else { return nil }
        while let last = l.last, last == "*" || last == "•" || last == "●" || last.isWhitespace { l.removeLast() }
        return l.hasSuffix(":") || l.hasSuffix("：") ? l : nil
    }

    /// Inside the window a password-asking command opened, the cursor's line ending in a colon with something before
    /// it, besides the keys' typed-ahead echo, is that command's prompt, whatever its words (a review, 14 Nov 2026:
    /// prompts in other words closed the secret as output). Pure.
    package nonisolated static func isPromptInSecretWindow(_ line: String, aheadKeys: Int) -> Bool {
        guard let l = promptLine(withoutTypedAhead(line, keys: aheadKeys)) else { return false }
        // A default in brackets ("Country Name (2 letter code) [AU]:", "Full Name []:") is never a password's: openssl
        // req and gpg's questions were all starred (a review, 14 Nov 2026).
        if l.trimmingCharacters(in: .whitespaces).hasSuffix("]:") { return false }
        return l.contains { $0.isLetter }
    }

    /// A command line that asks for a password next: sudo, doas, su, passwd, ssh (and scp, sftp) where a command
    /// starts: the line's start, after the prompt, or after ;, &&, || or |. A path to one counts. Pure.
    package nonisolated static func asksForPassword(commandLine: String) -> Bool {
        // openssl and gpg ask for a pass phrase (a review, 14 Nov 2026).
        let commands: Set<String> = ["sudo", "sudo-rs", "doas", "su", "passwd", "ssh", "scp", "sftp", "openssl", "gpg", "gpg2"]
        // ";", "&&", "||" and "|" are words of their own even without spaces ("make;sudo cp").
        let spaced = commandLine.replacingOccurrences(of: "[;&|]+", with: " $0 ", options: .regularExpression)
        let tokens = spaced.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (i, token) in tokens.enumerated() {
            var t = token
            while t.first == "(" { t.removeFirst() }
            let name = t.split(separator: "/").last.map(String.init) ?? t
            guard commands.contains(name) else { continue }
            if i == 0 { return true }
            let before = tokens[i - 1]
            if before.allSatisfy({ ";&|".contains($0) }) { return true }
            if let last = before.last, "%$#>❯➜".contains(last) { return true }   // the prompt's own end
        }
        return false
    }

    /// A line without the echo of `keys` characters typed ahead of a prompt at its start. Pure.
    package nonisolated static func withoutTypedAhead(_ line: String, keys: Int) -> String {
        String(line.dropFirst(max(0, keys)))
    }

    /// Whether new lines hold nothing (spaces only, or the typed-ahead echo already taken off): not output. Pure.
    package nonisolated static func allBlank(_ lines: [String]) -> Bool {
        lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// What on the cursor's line is output rather than the shell's prompt: the text before the prompt when the line
    /// holds it ("hi" in "hiuser@host ~ %"), nothing when the line starts with it, the whole line when it isn't there
    /// (a program's question: "Password:"). Nothing when no prompt is known. Pure.
    package nonisolated static func outputBeforePrompt(_ line: String, prompt: String) -> String {
        let p = prompt.trimmingCharacters(in: .whitespaces), t = line.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !t.isEmpty else { return "" }
        if t.hasPrefix(p) { return "" }
        guard let r = t.range(of: p, options: .backwards) else {
            // Another prompt of the shell's (after cd, another folder): user@host and the same last mark.
            return t.contains("@") && t.last == p.last ? "" : t
        }
        return String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Runs of three or more box-drawing characters (a program's rules and frames: "────") taken out, and lines left
    /// with nothing else dropped. Pure.
    package nonisolated static func withoutRules(_ text: String) -> String {
        func isBox(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x2500...0x259F).contains($0.value) } }
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            var kept = "", run = ""
            for c in line {
                if isBox(c) { run.append(c); continue }
                if run.count < 3 { kept += run }
                run = ""; kept.append(c)
            }
            if run.count < 3 { kept += run }
            let t = kept.trimmingCharacters(in: .whitespaces)
            return t.isEmpty && !line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : t
        }.joined(separator: "\n")
    }

    /// Output without the lines that are the cursor's own line redrawn, whole or its end (the text typed so far in a
    /// program's input box, rules and frames aside). Pure.
    package nonisolated static func withoutEcho(_ text: String, cursorLine: String, typed: String) -> String {
        let cur = withoutRules(cursorLine).trimmingCharacters(in: .whitespaces)
        guard !cur.isEmpty, !typed.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // Only a line ending with the character just typed is its echo (a prompt doesn't end so).
            let echo = (t == cur || cur.hasSuffix(t)) && t.lowercased().hasSuffix(typed.lowercased())
            return t.isEmpty || !echo
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Whether keys typed in a terminal are a password: from a password prompt being seen until Return, and after Return on
/// a line that asks for one next (`sudo …`, `ssh host`) or after a password (a retry), until a prompt or other output
/// arrives: two seconds from Return or the last key typed ahead, ten at most from Return. Rolling, as a slow ssh or
/// sudo prompt (over two seconds) had the rest of a password typed ahead spoken (a review, 13 Nov 2026). Pure.
package nonisolated struct TerminalSecret {
    package private(set) var latched = false
    /// Return, or the last key typed ahead since: the rolling window's start.
    package private(set) var aheadFrom: Date?
    /// The Return that opened the window: it closes ten seconds after, however long the typing goes on.
    package private(set) var aheadSince: Date?
    /// How many keys were typed ahead of the prompt (Backspace takes one off): their echo is not read. Only a count.
    package private(set) var aheadKeys = 0
    /// The window was opened by Return at a latched prompt (a retry), not by a password-asking command: its colon lines
    /// aren't taken for prompts by their colon alone (a review, 14 Nov 2026).
    package private(set) var retryWindow = false
    package init() {}

    package mutating func sawPrompt(_ line: String? = nil) { latched = true; aheadFrom = nil; aheadKeys = 0; if let line { lastPrompt = line.trimmingCharacters(in: .whitespaces) } }
    /// The prompt line last latched: the same line again after a wrong password ("Sorry, try again." and the prompt in
    /// one batch) is the prompt, in any language (a review, 14 Nov 2026).
    package private(set) var lastPrompt: String?
    /// New lines while the cursor's line is no longer a password prompt: the prompt is gone (a password itself echoes
    /// no new line). Control-C, Escape or Control-D at the prompt draw "^C" and the shell's prompt, and the latch
    /// stayed: the next command was spoken as stars, its echo silenced and its Return taken for a retry (a review,
    /// 13 Nov 2026).
    package mutating func outputArrived() { latched = false; aheadFrom = nil; aheadKeys = 0 }
    package mutating func keyTypedAhead(backspace: Bool, at now: Date) {
        // Only inside a live window: an expired one is not reopened by a key (secure input on says "star" too).
        guard !latched, isSecret(now: now) else { return }
        aheadFrom = now
        aheadKeys = backspace ? max(0, aheadKeys - 1) : aheadKeys + 1
    }
    package mutating func returnPressed(commandLine: String, at now: Date) {
        // A password typed ahead and sent: still ahead of its prompt, its count kept for the echo.
        if !latched, isSecret(now: now) { aheadFrom = now; return }
        let retry = latched
        latched = false
        aheadKeys = 0
        aheadFrom = retry || TerminalRules.asksForPassword(commandLine: commandLine) ? now : nil
        retryWindow = retry
        aheadSince = aheadFrom
    }
    package func isSecret(now: Date) -> Bool {
        if latched { return true }
        guard let from = aheadFrom, let since = aheadSince else { return false }
        return now.timeIntervalSince(from) < 2 && now.timeIntervalSince(since) < 10
    }
}
