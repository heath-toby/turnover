# Braille

TurnOver shows what it reads on a refreshable braille display, through the Mac's own braille drivers: any display
VoiceOver supports works in TurnOver too, by USB or Bluetooth, with nothing to install. All of braille's settings are
in Settings, Braille; the TurnOver menu's Braille submenu has the table and the most used ones.

## The display

- **Braille display:** Automatic uses any display a driver takes. No braille leaves displays alone. Or choose one
  kind (HID braille displays for the APH Mantis and Chameleon, Freedom Scientific Focus, HIMS, Handy Tech and the
  rest): only that kind is looked for, and it is used as soon as it is connected.
- **Bluetooth:** a display paired over Bluetooth is looked for only with "Look for displays paired over Bluetooth"
  on. A display on USB is always preferred: plug it in and TurnOver moves to the cable.
- A sound says when the display is connected and when it goes.

## Tables

- **Output table:** what you read. Automatic is the contracted table for your language (Unified English Braille,
  contracted, in English). Every table macOS has is listed, by language.
- **Input table:** what you type on the display's braille keyboard; the same as the output table unless you choose.
- **Show the word at the cursor uncontracted:** while editing, the word you are on is in computer braille, letter by
  letter, so each letter can be checked and routed to.
- **Show bold, italic and underline:** with the table's own signs (the indicators braille books use: Unified English
  Braille's, the US and UK codes'), or with dots 7 and 8 under formatted text, which works with any table. In
  documents and on web pages; a heading is not marked as bold.

## What the display shows

- **Braille mode:** follow the cursors (the focus and the caret), or show what was last spoken.
- **Tether braille:** automatically, to the focus, or to the review cursor (object navigation and the review keys).
- **Focus context presentation:** the display shows what the focus is in (its window, list or group) before it.
  Fill display for context changes shows the context when you move somewhere new; Only when scrolling back keeps it
  out of sight until you pan left; Always fill display shows it every time.
- **Read by paragraph:** the display shows a paragraph instead of a line, and its up and down move by paragraph,
  with a start marker if you want one (a pilcrow, or two blank cells).
- **Headings:** a line in a heading starts with its level, h1 to h9 (in Word and on web pages), unless headings
  are turned off under Document formatting; with the level not reported there, just h.
- **Avoid splitting words:** the display ends at a space rather than inside a word.
- **Show messages:** TurnOver's messages for a time (seconds for each display's width), until a key, or not at all.
- **Cursor:** shown or not, blinking or not and how fast, and its shape for the focus and for review (dots 7 and 8,
  dot 7, dot 8, or all dots). Selected text has dots 7 and 8.

## Keys on the display

- **Panning keys** move along the line, and on to the next or previous line at either end. With "Panning moves the
  cursor" (Line by line, To the text shown, or Off), the caret follows what you read. The line reached is spoken
  too, as VoiceOver does; turn off "Speak the line when panning to it" to pan silently, as NVDA does. In Terminal
  the shell keeps its cursor, so the line you pan to stays on the display until new output moves it.
- **Routing keys** move the caret to that character (the character is spoken), or press a link or button in browse
  mode. Tethered to review, they move the review cursor, and the caret only if you choose.
- The display's other keys do what VoiceOver does with them: up and down, the action key, Escape, the Dock, the menu
  bar, first and last item, start and stop interacting, the rotor, contracted or uncontracted braille, and the
  announcement history.
- **The braille keyboard:** type in contracted braille a word at a time, or letter by letter. Space with dots are
  VoiceOver's braille commands; dot 7 is Backspace and dot 8 Return. Keyboard help (TurnOver 1, or space with dots
  1 3) says what each key and chord does.
