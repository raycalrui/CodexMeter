# CodexMeter Development Guide

## Project scope

CodexMeter is a native macOS menu bar app built with SwiftUI. It displays the
remaining Codex account quota without requiring the user to open Codex.

- Support macOS 13 or later.
- Keep the app menu-bar-only; do not add a normal window or Dock icon unless the
  product direction changes.
- Prefer Apple frameworks and avoid third-party dependencies for this small app.
- Make focused changes and preserve the existing architecture.

## Architecture

- `CodexMeterApp.swift` owns the `MenuBarExtra` and shared usage service.
- `ContentView.swift` renders quota details and user actions.
- `CodexUsageService.swift` launches the installed `codex app-server` process
  over stdio and communicates with it using newline-delimited JSON-RPC.
- Use `account/read` for account metadata and `account/rateLimits/read` for quota
  windows. Refresh after `account/rateLimits/updated` notifications.

Do not scrape ChatGPT web pages, read Codex authentication files directly, or
copy access tokens into app storage. Authentication and token refresh belong to
Codex App Server.

## Quota display rules

- The API returns `usedPercent`; calculate remaining quota as
  `100 - usedPercent` and clamp it to `0...100`.
- Display every returned quota window in the popover.
- Display the lowest remaining percentage in the menu bar so the most
  constrained window is always visible.
- Use returned window durations and reset timestamps instead of hard-coding the
  account's quota structure.
- Never log account email addresses, tokens, or raw authentication responses.

## macOS settings

- `LSUIElement` must remain enabled so the app does not appear in the Dock.
- App Sandbox is currently disabled because the app needs to launch the user's
  locally installed Codex executable. Revisit this deliberately before any Mac
  App Store distribution work.
- Keep the deployment target at macOS 13 unless a new API requires a later OS.

## Verification

Build from the repository root:

```bash
xcodebuild \
  -project CodexMeter.xcodeproj \
  -scheme CodexMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

If the active developer directory points only to Command Line Tools, set
`DEVELOPER_DIR` to an installed Xcode for that command. Before committing, also
run:

```bash
git diff --check
```
