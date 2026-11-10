# LaunchBar

- Bundle id: at.obdev.LaunchBar
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 10 November 2026; LaunchBar 6.24, macOS 27.2; structure observed with a script, the module not yet heard.

## Findings

The bar is one focused AXCell that LaunchBar renames for each chosen item (typing, the arrows, Right and Left, Control
Tab), posting AXTitleChanged. TurnOver heard the changes but said nothing. The module says the cell's title as the bar
opens and at each new name.

## Evidence

[App implementation](LaunchBarAppModule.swift).
