# Reading and say all

## Web pages and messages

Web pages and email messages are read as a document. Up and Down go line by line; Option with the arrows, word by
word. Single letters jump: in the Mac style, VoiceOver's Quick Nav letters (H heading, L link, F text field, T table,
1 to 6 headings by level); in the Windows style, NVDA's. **TurnOver Space** switches between reading the page and
typing into it. Enter activates a link or button.

**TurnOver Shift Backslash** says the page's summary: its title and how many headings, links, tables, forms,
landmarks and so on it has (VO Shift Vertical Line in the Mac style; Caps Lock Shift Backslash in the Windows styles).

Settings, Web pages, has VoiceOver's and NVDA's choices for pages:

- **When a new page opens:** read the page through (the standard), say its title and its summary (how many headings,
  links, tables, forms and landmarks), say its title and first line, or say nothing.
- **While a page loads:** say nothing (the standard), say how far it has got ("loading", then "30 percent" and so on),
  or play a soft tone until it has loaded. This needs a browser that tells TurnOver how loading is going (Safari's
  engine); elsewhere nothing is heard.
- **Pictures on a page:** always read (the standard), read only those with a description, or skip them. A picture
  inside a link is always read, as it is often the link's only name.
- **Lines moved by Page Up and Page Down:** 20 unless you change it.

## Say all

Say all reads from where you are to the end: **VO A** in the Mac style, **Caps Lock A** in the Windows
style (Caps Lock Down Arrow with the desktop keyboard layout). It moves the caret as it goes.

- Any key stops it, and the caret is left on the word you had reached, not the start of the paragraph.
- Up and Down during say all skim: they move a line and carry on reading from there.

## The say all voice

Say all can read in a natural voice made on your Mac, while everything else (moving, typing, menus) stays in your
usual voice, which answers at once. The TurnOver menu, Settings, Speech, **Say all voice**: "Same as speech", or a
natural voice. Natural voice speed is there too.

The natural voice reads ahead: while one paragraph plays, the next ones are being made, so it never waits.
Natural voices speak English for now; other languages keep your Mac's voices.

## Other languages

Settings, Speech, **Automatic language switching** reads text in another language in that language's voice, as
VoiceOver does:

- Text a page or document marks as another language, and text in another alphabet (Arabic, Russian, Greek and so on),
  is always switched.
- Text in your own alphabet is recognised as one of the languages you tick in the **Languages** table: a German line in
  an English document is read in German. It takes three words or more (two when they are plainly German), so names
  and borrowed words stay in your voice; a single word you move to keeps the language of the lines around it.

The **Languages** table lists every language with a voice on your Mac, the ones you have set up first. Up and Down
go through the languages; Tab goes on to the chosen one's voice, rate, pitch and volume, and **Recognise in text**.
A language you haven't set up uses its best voice at your own rate, pitch and volume. Each change is heard in that
language as you make it.

## How text is said

Settings has VoiceOver's and NVDA's choices for how text is read:

- **Speech:** read numbers as words or digits; repeated punctuation, each one or with a count ("7 dash"); when
  deleting text, speak it, speak it lower, play a tone or do nothing; a tone before a capital, as well as or instead
  of "cap" and a raised pitch.
- **Emoji and symbols:** emoji are named by the voice itself ("grinning face"), in the voice's language. Symbols a
  voice would pass over in silence, such as arrows, maths and shapes, are said by their Unicode names ("rightwards
  arrow"). Emoticons such as :-) and <3 are said by name ("smiley", "heart"), unless you turn that off in Speech.
- **Pronunciations** (Speech): words said your way. Choose one in the list to change or remove it, or type a word and
  how to say it and Add. "LBRF" said as "L B R F", for instance. It changes speech only; braille shows the word as
  written.
- **Documents, Lines:** line indentation as the caret moves by line, when it changes: spoken ("4 space", "tab",
  "no indent"), as tones (higher for deeper), or both, as NVDA does.
- **Documents, Fonts:** colour, with the font's name, size and style.
- **Item details:** how long a pause before a hint, and whether a dialog reads its text as it opens.
- **Keyboard:** Caps Lock on and off said or not; right Option with a letter as VoiceOver's Keyboard Commander; and
  NVDA's timings, how soon a key pressed again counts as twice, and how long to wait for the caret.
- **Moving around:** at the end of a group, wrap round to its start, with VoiceOver's wrap sound.

## Documents

In Word, Pages and TextEdit, the arrows read as they move. **VO Command H** goes to the next heading (Shift for the
previous). In Pages, a table's line says its size; **VO Shift Down** reads it cell by cell (the arrows move, each
cell said with its row or column heading), and **VO Shift Up** or Escape comes back. Comments and highlights are
said after the line that holds them. TurnOver says the page as you move onto it.

## PDFs in Preview (experimental)

A PDF is read like a web page: line by line across pages, with "page 2 of 5" as you reach each page, and headings
by H. Highlights, notes and text boxes, which Preview hides from VoiceOver, are read where they sit.
