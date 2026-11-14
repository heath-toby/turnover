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
- Up and Down during say all skim: they move a line and carry on reading from there. To have them stop say all
  instead, turn off Settings, Keyboard, **Line and paragraph keys skim through say all**.

## The say all voice

Say all can read in a natural voice made on your Mac, while everything else (moving, typing, menus) stays in your
usual voice, which answers at once. Settings, Speech, **Say all voice**: "Same as speech", or a
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

## Speech history

As NVDA's Speech History add-on: **Control Shift F11** says the thing said before, **Control Shift F12** the
thing after, and **Control F12** copies the one you are on, to paste into a report. New speech puts you back at the
newest. Private speech (a password, a code, what you type) is never kept.

To copy several things at once, record them: **TO Shift F11** starts recording, and again stops it; **TO Shift F12**
copies what was recorded, a line each, as written where the text came with its own words (a message, a line of a
document). With VoiceOver keys, TO Shift F11 is Screen Curtain, so press TO Shift F12 twice to start or stop
recording.

## How text is said

Settings has VoiceOver's and NVDA's choices for how text is read:

- **Speech:** read numbers as words or digits; repeated punctuation, each one or with a count ("7 dash"); when
  deleting text, speak it, speak it lower, play a tone or do nothing; a tone before a capital, as well as or instead
  of "cap" and a raised pitch.
- **Emoji and symbols:** emoji are named by the voice itself ("grinning face"), in the voice's language. Symbols a
  voice would pass over in silence, such as arrows, maths and shapes, are said by their Unicode names ("rightwards
  arrow"). Emoticons such as :-) and <3 are said by name ("smiley", "heart"), unless you turn that off in Speech.
- **Speech dictionary** (its own section, after Speech): words said your way, as NVDA's speech dictionaries, in one
  list. Each entry has its own **Applies to**: **All voices and languages**, **Only in** a language (your main
  voice's, or one in the languages table), or **Only for** a voice (your main voice, a voice chosen for another
  language, or the natural voice if you use it). So a German name can be fixed for the German voice without
  touching English. Entries apply in NVDA's order: those for the voice speaking first, then those for its
  language, then those for all voices. They change speech only; braille shows the text as written.
  - **Show**, at the top, narrows the list: **All entries**, **For all voices and languages**, one language or one
    voice. It only changes what is shown. With a language or voice chosen there, a new entry is for that language
    or voice unless you change its Applies to.
  - **Entries** lists the entries, each read as its pattern, its type, what it is said as and who it is for:
    "LBRF, whole word, said as L B R F, all voices", "Siobhan, phonemes, said as ʃɪˈvɔːn, only in English". They
    apply in the order listed, each to the text the one before left; **Move up** and **Move down** change the
    order (with Show narrowed, past the entry before or after it in the list as shown).
  - To add one, choose its **Type**, fill in **Pattern** and **Replacement**, choose **Applies to**, and press
    **Add**. To change one, choose it in the list, change the fields and press **Change**; **Remove** takes it
    away. **Case sensitive** makes it match only in the case typed; **Comment** is a note of your own.
  - The types: **Whole word**, the pattern as a word on its own ("LBRF", not inside "LBRFs"); **Anywhere**, the
    pattern wherever it is, inside words too, for a symbol such as "&" or letters inside longer words; **Regular
    expression**, a pattern in which the replacement can use $1 for what the first group in brackets found, $2 for
    the second ("(\d+)px" said as "$1 pixels"); and **Phonemes**, a whole word said with the sounds you give in IPA,
    in **Phonemes (IPA)**: Siobhan as ʃɪˈvɔːn. A pattern that isn't a valid regular expression, or one that could
    match no text at all, is refused, and the section says why; one that runs too long while speaking is left out
    until the dictionary changes.
  - For phonemes, three ways to find the sounds: **Use a pronunciation from System Settings** copies those of one
    you made there; **Hear it** says the word with the sounds typed, in the voice of the entry's Applies to; and
    **Look up on Wiktionary** sends the word in Pattern, and only that, to Wiktionary and lists its pronunciations
    in the entry's language to choose from. The Mac's voices say IPA, which VoiceOver can't; a natural voice says
    the word as written.
  - The TurnOver menu, Settings, Speech dictionary, opens the window at this section.
  - The dictionary is a text file in TurnOver's folder in Application Support, pronunciations.txt, a line each:
    `LBRF = L B R F` is a whole word for all voices, `Siobhan = /ʃɪˈvɔːn/` phonemes, and the other types and the
    scopes start with an @: `@anywhere & = and`, `@regex,case (\d+)px = $1 pixels`, `@phonemes,lang=de Bach = /bax/`,
    `@word,voice=com.apple.voice.premium.en-GB.Malcolm LBRF = L B R F` (in a voice's name, anything but letters,
    digits, dots, dashes and underscores is written with a % code: `voice=external%3Aaf_heart`). A comment line,
    starting with `#`, just before an entry is that entry's comment.
  - Earlier builds of the same day kept a language's and a voice's words in files of their own, in the
    pronunciations folder. The first time TurnOver speaks, or the Settings window shows this section, their
    entries are added to pronunciations.txt with their language or voice, and the old files renamed to end in
    .migrated; they are never deleted.
- **Also use the pronunciations from System Settings** (Speech dictionary, on unless you turn it off): the words
  you gave in System Settings, Accessibility, Read & Speak, Pronunciation, are said that way too, after TurnOver's
  own dictionary, for the languages and voices they were given for. TurnOver only reads that list; change it in
  System Settings. The section says how many there are.
- **Documents, Lines:** line indentation as the caret moves by line, when it changes: spoken ("4 space", "tab",
  "no indent"), as tones (higher for deeper), or both, as NVDA does.
- **Documents, Fonts:** colour, with the font's name, size and style.
- **Item details:** how long a pause before a hint, and whether a dialog reads its text as it opens.
- **Keyboard:** Caps Lock on and off said or not; the Commander key (right Option unless changed) with a letter as
  VoiceOver's Keyboard Commander; and
  NVDA's timings, how soon a key pressed again counts as twice, and how long to wait for the caret.
- **Moving around:** at the end of a group, wrap round to its start, with VoiceOver's wrap sound.

## The mouse

Settings, Mouse, has NVDA's and VoiceOver's mouse choices. All are off until you turn them on.

- **Speak what is under the mouse pointer as it moves:** over text, a character, word, line or paragraph (your
  choice, a paragraph at first); anywhere else, the item, such as "Save, button". It can wait until the pointer has
  rested for a moment, as VoiceOver's does.
- **Say the kind of item when the pointer reaches it:** "button", "link", before the text under the pointer.
- **Say the window's name when the pointer moves into another window.**
- **Play audio coordinates as the mouse moves:** NVDA's short beep at each move, higher towards the top of the screen
  (880 Hz) and lower towards the bottom (220 Hz), from the left or the right speaker by where the pointer is across.
  It works on its own, with speech off. NVDA's "brightness controls the volume" isn't there: it needs the Mac's
  Screen Recording permission.
- **Mouse pointer and the cursor:** as VoiceOver's. The pointer ignores the cursor (as before); the pointer follows
  the cursor, going to each item it reaches; or moving the pointer moves the cursor to the item under it, which is
  read, so VO Space then presses it. The keyboard focus stays where it is. (Keyboard, Review cursor follows the
  mouse, moves the cursor the same way but silently.)
- While trackpad control is on, the mouse settings are silent: the trackpad is TurnOver's then.
- Over a password field, only "password edit" is said, never what is typed in it.

## Documents

In Word, Pages and TextEdit, the arrows read as they move. **VO Command H** goes to the next heading (Shift for the
previous). In Pages, a table's line says its size; **VO Shift Down** reads it cell by cell (the arrows move, each
cell said with its row or column heading), and **VO Shift Up** or Escape comes back. Comments and highlights are
said after the line that holds them. TurnOver says the page as you move onto it.

## PDFs in Preview (experimental)

A PDF is read like a web page: line by line across pages, with "page 2 of 5" as you reach each page, and headings
by H. Highlights, notes and text boxes, which Preview hides from VoiceOver, are read where they sit.

## Showing it on the screen (Vision)

For someone sitting beside you, or if you see a little: Settings, Vision. All of it is off until you turn it on.

- **Highlight what TurnOver is on** draws a ring on the screen, like VoiceOver's cursor: blue round the focus, pink
  round the review cursor once you move it away from the focus, and yellow round the reading position on a web page.
  Each colour has its own switch. Where two are on the same item, the rings sit one inside the other.
- **Show the caption panel** puts what TurnOver says in a dark panel at the bottom of the screen. Private speech, such
  as what you type in a password field, is never shown.
- **Show the braille panel** shows what the braille display shows, as braille and as text, above the caption panel.
  It works without a display: a sighted helper can see what the display would say.
- **Text size in the panels**: small, medium or large.

These never take the keyboard or the mouse, and TurnOver does not read them. They go when VoiceOver takes over.
