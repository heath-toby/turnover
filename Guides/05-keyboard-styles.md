# Keyboard styles

TurnOver speaks three screen readers' keys. Press Command Control Comma, then K, until you hear the one you want; the
TurnOver menu, Settings, Keyboard, and the Settings window offer the same choice. The style changes which keys you
press, never what TurnOver can do.

## VoiceOver keys (the Mac style)

VoiceOver's own keys, doing what they do in VoiceOver. VO is Control and Option together; Caps Lock works as VO too.
VO arrows move around, VO Space presses, VO Shift Down and Up go into and out of things, VO U is the rotor, VO M the
menu bar, VO D the Dock, VO Shift M the shortcut menu. VO Command Shift with the arrows changes speech settings, VO
Command with the arrows moves by the rotor's kind. Control pauses speech. One Quick Nav is shared with VoiceOver.

[Every key, VoiceOver keys](keys-voiceover.html).

VoiceOver Utility's Commanders and Navigation choices are in Settings, Keyboard:

- **Keyboard Commander** and **Commander key**: right Option and a letter runs that letter's command (the switch, or
  VO Shift K, turns it on and off). It can be left Option, right or left Command, or right Control instead. Give a
  letter its command in the TurnOver menu, Keys, My own keys, Give a key to a command, then press the Commander key and
  the letter. Keypad keys are given commands the same way; trackpad gestures with Give a trackpad gesture to a command.
  With a Command or Control key as the Commander, a letter you give a command no longer reaches the app with that key:
  with Left Command, giving T a command takes Command T (a new tab) away from your apps. The Commander key and T tells
  the time only while an Option key is the Commander. With the Commander off, a Command or Control key's letters are
  the apps' again; an Option key's letters you gave commands still run them.
- **Grouping behaviour**: Standard moves by groups, as VoiceOver does; Ignore groups walks the whole window.
- **Initial position of the cursor in a new window**: the keyboard focused item, or the window's first item.
- **Automatically interact when using the Tab key**: on, Tab puts the cursor inside the group it reaches; off, on the
  group itself, and VO Shift Down goes in.
- **Fast searching**: with the keyboard focus on a list, table or outline, Right Command and a letter moves to the
  next item there starting with it. Off at first, as Right Command and a letter then no longer reaches the app in a
  list. With Right Command as the Commander key, a letter you gave a command runs that command instead.

## NVDA keys (the Windows style)

NVDA's own keys, doing what they do in NVDA. Caps Lock is the NVDA key (Control and Option works too): Caps Lock N
the TurnOver menu, Caps Lock 1 keyboard help, Caps Lock L the current line, Caps Lock A say all, Caps Lock F7 the
elements list, Caps Lock Space browse mode on and off. Control stops speech. Where NVDA uses Alt, TurnOver uses the
Mac's Command key, which sits where Alt does on a PC keyboard. The role is said before the words, as NVDA says them.

[Every key, NVDA keys](keys-nvda.html).

### The review cursor

Settings, Keyboard, Moving around has NVDA's review cursor settings:

- **Review cursor follows the keyboard focus** (on): the review cursor goes wherever the focus goes. Caps Lock 7
  switches it, and so does VoiceOver's cursor tracking (VO Shift F3); the change is kept.
- **Review cursor follows the caret** (on): in text, the review cursor goes back to the caret when the caret moves.
  Caps Lock 6 switches it.
- **Review cursor follows the mouse** (off): the review cursor goes to whatever the pointer is over, silently. To
  hear it as well, use Settings, Mouse, "Moving the pointer moves the cursor".
- **Simple review mode** (on): moving item by item skips layout, such as unnamed groups and scroll areas: NVDA's next
  and previous object, VoiceOver's keys with Grouping behaviour set to Ignore groups, and moving out to the item
  holding the cursor. Off, every object is a stop, as in NVDA's full review.

## JAWS keys

JAWS's laptop layout, with Caps Lock as the JAWS key. The reading grid: Caps Lock U, I and O for the previous, current
and next line; J, K and L for words; M, Comma and Period for characters; Y, H and N for sentences; Control U, I and O
for paragraphs. Caps Lock Shift J and L read the line up to and from the cursor. Caps Lock Z is the virtual cursor,
Caps Lock F5, F6 and F7 the lists of form fields, headings and links, Caps Lock Semicolon the PC cursor and Caps Lock P
the JAWS cursor, Caps Lock 8 and 9 click. During say all, Left and Right go back and on a sentence, and Page Up and
Page Down change the speed for that say all. Every other key is NVDA's.

[Every key, JAWS keys](keys-jaws.html).

## On a Mac keyboard

- **Insert doesn't exist**, so every Insert, NVDA or JAWS key chord becomes Caps Lock.
- **The Mac's own shortcuts win.** Where a Windows reader's key collides with a Mac shortcut (Command Comma opens
  every app's settings, Command Period cancels), the reader's command sits on a second key, listed on its page.
- **Windows' Control is often the Mac's Command** for app shortcuts: copy, find, new tab. In screen reader chords it
  stays Control.
- **Home, End, Page Up and Page Down** are Fn with the arrows on a laptop keyboard. F1 to F12 need Fn unless the Mac
  is set to use them as standard function keys.

## In every style

- TurnOver's own commands behind Command Control Comma never change with the style.
- Keyboard help (the TurnOver menu, Keys) says what any key does without doing it.
- Command Control Comma, then Slash, lists every key that works where you are.
- Your own keys (the TurnOver menu, Keys, My own keys) sit on top of any style.

## Keys, speech and announcements

Settings, Keyboard, **Keys and speech**, as VoiceOver's and NVDA's options:

- Say a modifier key's name (shift, right command) when it is pressed and let go on its own. The TurnOver key is
  never named while you use it. Control, which stops speech, is named only when nothing was being said. With NVDA
  keys, Command and Option alone open menus and aren't named, and Shift, which pauses speech, is like Control.
- Whether a typed character, and Return, stop what is being said. Off, the echo waits its turn. Any key still
  stops reading all, and what it was saying with it.
- A sound when a word you just typed into a text field is misspelt.

Settings, Item details, **Announcements**, as VoiceOver's: when the text under the cursor changes (a status line, a
timer), when the table or list you are in gains or loses rows, and a sound when a dialog appears (whether its text
is read is **Read a dialog's text as it opens**). **Skip a label already said with its item** passes over the text a plugin's label came from.
