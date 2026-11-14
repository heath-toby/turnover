# Signal

- Bundle id: org.whispersystems.signal-desktop
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 14 November 2026; setup details are in the linked evidence.

## Findings

Signal (and Signal Beta, org.whispersystems.signal-desktop-beta) is read by TurnOver's general web navigation. Its module adds the announcements of the tester's VoiceOver Signal Filter, which mirrors their NVDA and Orca Signal Filter add-ons: "Message sent.", a message received ("Message received: …", or the sender's name and the message in a group), someone typing and stopping. Each can be turned off in Settings, Other apps' speech, Signal.

A read-only probe of Signal Beta on macOS 27.2 (14 Nov 2026) confirmed that Chromium exposes the class names and ids the filter relies on. The announcements themselves have not been heard yet.

Next check: with a second account, receive a message in a conversation with one person and in a group, with Signal in front and behind; send one; watch the other person type and stop; open a conversation with unread messages and confirm they are not read out.

## Evidence

[Dated observations and limits](Experiments/2026-11-filter-port.md).
