# Signal Filter port, 14 November 2026

Read-only accessibility probe of Signal Beta (not in front), macOS 27.2, with no message text or names recorded:

- 984 nodes walked in 148 ms; 469 answer AXDOMClassList.
- The timeline is an AXList with `module-timeline__messages`; its 31 children each wrap one message row a level down.
- Message rows are AXRows with `module-message__container` and `--outgoing` / `--incoming` variants, ids `message-accessibility-contents:<uuid>`.
- The timeline's ancestor seven levels up has the id `conversation-<id>`; the conversation header button has `module-ConversationHeader__header--clickable`.
- The conversation list items carry `module-conversation-list__item--…` classes, left out of the typing bubble's wide search.

Not yet tested by ear: arrival, sending and typing announcements.
