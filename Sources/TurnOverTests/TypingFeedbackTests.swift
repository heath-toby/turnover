// SPDX-License-Identifier: GPL-3.0-or-later
// Typing and editing feedback: the pure decisions behind the review of 13 Nov 2026 (stale caret after fast typing,
// the word-end wait, web selection routing, completions, spelling placement, deletions, copy and cut).
import Foundation
import TurnOverCore

func typingFeedbackTests() {
    test("typing: a Backspace right after typing takes the letter typed last, only while that is certain") {
        expect(EditableText.typedCharacterBeforeCaret(typed: "hel", edited: false, waiting: false, sinceTyped: 0.04), "l", "just typed")
        expect(EditableText.typedCharacterBeforeCaret(typed: "hel", edited: true, waiting: false, sinceTyped: 0.04), nil, "a Backspace already in the word")
        expect(EditableText.typedCharacterBeforeCaret(typed: "hel", edited: false, waiting: true, sinceTyped: 0.04), nil, "a word's end still waiting for the field")
        expect(EditableText.typedCharacterBeforeCaret(typed: "hel", edited: false, waiting: false, sinceTyped: 0.4), nil, "typing paused: the field is the truth")
        expect(EditableText.typedCharacterBeforeCaret(typed: "", edited: false, waiting: false, sinceTyped: 0.01), nil, "nothing typed")
    }
    test("typing: the wait for the field only just after typing, and settled only once it holds still") {
        check(EditableText.typingMaySettle(sinceTyped: 0.02), "20 ms after a letter")
        check(!EditableText.typingMaySettle(sinceTyped: 0.2), "200 ms after: no wait")
        check(!EditableText.typingMaySettle(sinceTyped: -1), "a clock step back: no wait")
        check(!EditableText.typingSettled(sinceTyped: 0.02, unchanged: true), "too soon to trust a still field")
        check(!EditableText.typingSettled(sinceTyped: 0.08, unchanged: false), "still changing")
        check(EditableText.typingSettled(sinceTyped: 0.08, unchanged: true), "still, and late enough")
    }
    test("typing: the word end waits for the field only with word echo on for it") {
        let was = config.keyboard.speakTypedWords
        defer { config.keyboard.speakTypedWords = was }
        config.keyboard.speakTypedWords = .off
        check(!Speech.echoesTypedWords(editable: true), "off: no wait in a field")
        config.keyboard.speakTypedWords = .editControls
        check(Speech.echoesTypedWords(editable: true) && !Speech.echoesTypedWords(editable: false), "edit controls only")
        config.keyboard.speakTypedWords = .always
        check(Speech.echoesTypedWords(editable: false), "always")
    }
    test("typing: a non-breaking space the field put for a typed space ends the word") {
        let a = Speech.fieldWord(endedBy: " ", before: "one two\u{a0}", notBefore: 4)
        check(a.taken && a.word == "two", "web editor's trailing no-break space: \(a)")
        let b = Speech.fieldWord(endedBy: ".", before: "one two\u{a0}", notBefore: 4)
        check(!b.taken, "a no-break space is no full stop: \(b)")
    }
    test("selection: a selection after typing is a completion only if typing was the last key") {
        check(EditableText.isTypingCompletion(sinceTyped: 0.1, lastKeyWasTyped: true, fromSelectionKey: false), "an address bar completing")
        check(!EditableText.isTypingCompletion(sinceTyped: 0.1, lastKeyWasTyped: false, fromSelectionKey: false), "Command-A just after typing")
        check(!EditableText.isTypingCompletion(sinceTyped: 0.1, lastKeyWasTyped: true, fromSelectionKey: true), "Shift-Left's own script")
        check(!EditableText.isTypingCompletion(sinceTyped: 0.5, lastKeyWasTyped: true, fromSelectionKey: false), "typing paused")
    }
    test("selection: a web area's notice goes to the focused field in it, only while keys go to the page") {
        var walked = false
        check(AXHandler.routesSelectionToFocus(changedIsFocus: true, keysGoToPage: true, focusInsideWebArea: { walked = true; return false }), "the changed element is the focus")
        check(!walked, "no walk needed when the notice names the focus")
        check(AXHandler.routesSelectionToFocus(changedIsFocus: false, keysGoToPage: true, focusInsideWebArea: { true }), "the focus is inside the web area")
        check(!AXHandler.routesSelectionToFocus(changedIsFocus: false, keysGoToPage: true, focusInsideWebArea: { false }), "a field elsewhere")
        check(!AXHandler.routesSelectionToFocus(changedIsFocus: true, keysGoToPage: false, focusInsideWebArea: { true }), "browse mode follows the selection itself")
    }
    test("spelling: marked ranges move onto the text as spoken, by occurrence") {
        let raw = "concatenate cat"
        let marked = [NSRange(location: 12, length: 3)]
        let same = Speech.moveRanges(marked, from: raw, to: raw)
        check(same == marked, "unchanged text: unchanged ranges")
        let spoken = " link concatenate cat"
        let moved = Speech.moveRanges(marked, from: raw, to: spoken)
        check(moved == [NSRange(location: 18, length: 3)], "the second cat, not the one inside concatenate: \(moved)")
        let first = Speech.moveRanges([NSRange(location: 3, length: 3)], from: raw, to: spoken)
        check(first == [NSRange(location: 9, length: 3)], "the cat inside concatenate stays inside it: \(first)")
        check(Speech.moveRanges([NSRange(location: 40, length: 3)], from: raw, to: spoken).isEmpty, "a range past the text is dropped")
    }
    test("deleting: what a deletion took, from the text kept before the key") {
        expect(EditableText.deletedText(context: "rest of line\nnext", count: 13, forward: true), "rest of line\n", "Control-K at a line's start")
        expect(EditableText.deletedText(context: "the word", count: 1, forward: false), "d", "Control-H")
        expect(EditableText.deletedText(context: "a👩🏽‍💻", count: 7, forward: false), "👩🏽‍💻", "an emoji by its UTF-16 units")
        expect(EditableText.deletedText(context: "short", count: 9, forward: true), nil, "more went than was kept")
        expect(EditableText.deletedText(context: "short", count: 0, forward: true), nil, "nothing went")
        check(EditableText.atTextEnd(caret: 5, length: 5), "Delete at the very end")
        check(!EditableText.atTextEnd(caret: 4, length: 5), "a character still after the caret")
    }
    test("text: a field with no character count uses its value's length") {
        expect(AXTextInfo.characterCount(numberOfCharacters: 7, value: { "never read" }), 7, "the app's count first")
        expect(AXTextInfo.characterCount(numberOfCharacters: nil, value: { "héllo👋" }), 7, "the value's UTF-16 length")
        expect(AXTextInfo.characterCount(numberOfCharacters: nil, value: { nil }), nil, "no value: still unknown")
    }
    test("clipboard: copy and cut say the text, shortened after 100 characters") {
        expect(ClipboardAnnouncer.copiedSpeech("copied", text: "  hello  "), "copied, hello", "copied")
        expect(ClipboardAnnouncer.copiedSpeech("cut", text: "word"), "cut, word", "cut")
        expect(ClipboardAnnouncer.copiedSpeech("copied", text: nil), "copied", "an image: no text")
        let long = String(repeating: "a", count: 150)
        expect(ClipboardAnnouncer.copiedSpeech("copied", text: long), "copied, " + String(repeating: "a", count: 100) + "…", "long text cut at 100")
    }
    test("selection: a selection over 1000 characters is said as a count") {
        expect(Speech.selectedSpeech(String(repeating: "a", count: 1500)), "selected 1500 characters", "a long selection: its length")
        check(Speech.selectedSpeech("hello").hasPrefix("selected "), "a short one: its text")
        check(Speech.selectedSpeech("hello").contains("hello"), "a short one: its text")
    }
    test("clipboard: a password manager's concealed or transient copy is never read") {
        check(ClipboardAnnouncer.isConcealed(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), "concealed")
        check(ClipboardAnnouncer.isConcealed(["org.nspasteboard.TransientType", "public.utf8-plain-text"]), "transient")
        check(!ClipboardAnnouncer.isConcealed(["public.utf8-plain-text", "public.rtf"]), "ordinary text is read")
        check(!ClipboardAnnouncer.isConcealed([]), "an empty clipboard")
    }
}
