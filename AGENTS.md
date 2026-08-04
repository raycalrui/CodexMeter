# CodexMeter Development Guide

## Project scope

CodexMeter is a native macOS menu bar app built with SwiftUI. It displays the
remaining Codex account quota without requiring the user to open Codex.

- Support macOS 13 or later.
- Keep the app menu-bar-only; do not add a normal window or Dock icon unless the
  product direction changes.
- Prefer Apple frameworks and avoid third-party dependencies for this small app.
- Make focused changes and preserve the existing architecture.

## AGENTS.md maintenance

Treat this file as living project documentation. After completing every task,
review it and update it automatically when the implementation or project state
has changed.

- Mark completed roadmap items as done and add newly agreed follow-up work.
- Keep architecture, product rules, supported systems, privacy boundaries, and
  verification commands synchronized with the codebase.
- Remove or revise instructions that are no longer accurate.
- Record durable project decisions, not temporary debugging details or
  one-off conversational context.
- Keep edits concise. If a task does not change any documented fact or roadmap
  status, do not make a cosmetic `AGENTS.md` edit merely to touch the file.

## Architecture

- `CodexMeterApp.swift` owns the `MenuBarExtra` and shared usage service.
- `ContentView.swift` renders quota details and user actions.
- `MenuBarProgressView.swift` renders the configurable menu bar progress ring
  and percentage.
- `CodexUsageService.swift` launches the installed `codex app-server` process
  over stdio, communicates with it using newline-delimited JSON-RPC, and owns
  refresh/freshness state.
- `Core/QuotaModels.swift` contains pure quota, remaining-time, and consumption-
  pace calculations shared with the Swift Package unit tests.
- `AppSettings.swift` persists menu bar, notification, threshold, and launch-at-
  login preferences. `NotificationManager.swift` owns local notification state.
- `Localizable.xcstrings` is the source of English, Simplified Chinese, and
  Traditional Chinese user-facing strings.
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

## Refresh and freshness rules

- Refresh immediately at launch, every 60 seconds, after an App Server rate-
  limit notification, and when the user requests it manually.
- Skip a refresh while the previous rate-limit request is still in flight.
- Time out a rate-limit request after 20 seconds.
- On failure, retain the last successful quota snapshot and mark it as possibly
  stale instead of clearing the menu bar.
- Recalculate remaining-time UI locally once per minute without an extra server
  request.

## macOS settings

- `LSUIElement` must remain enabled so the app does not appear in the Dock.
- App Sandbox is currently disabled because the app needs to launch the user's
  locally installed Codex executable. Revisit this deliberately before any Mac
  App Store distribution work.
- Keep the deployment target at macOS 13 unless a new API requires a later OS.

## Roadmap / TODO

### Confirmed next features

- [x] Replace or augment the static menu bar symbol with a compact progress
  indicator that visualizes the most constrained window's remaining quota.
  Keep the numeric percentage visible so the state is not communicated by
  shape or color alone.
- [x] Localize the complete UI into English (`en`), Simplified Chinese
  (`zh-Hans`), and Traditional Chinese (`zh-Hant`). Move user-facing strings to
  a String Catalog and remove hard-coded Chinese strings from Swift source.
- [x] Expand each quota window in the popover with two directly comparable
  progress bars on the same scale and in the same direction:
  - remaining quota percentage;
  - remaining time percentage before reset.
- [x] Add a consumption-pace status for every window. Calculate it from API
  data rather than assuming fixed five-hour or seven-day products:

  ```text
  windowStart = resetsAt - windowDuration
  elapsedPercent = clamp((now - windowStart) / windowDuration * 100, 0...100)
  remainingTimePercent = 100 - elapsedPercent
  remainingQuotaPercent = clamp(100 - usedPercent, 0...100)
  paceDelta = remainingQuotaPercent - remainingTimePercent
  ```

  Treat `paceDelta >= 0` as safe/on pace because the remaining-quota bar is at
  least as long as the remaining-time bar. Treat `paceDelta < 0` as above the
  ideal consumption pace. For example, halfway through a seven-day window,
  using no more than 50% is on pace. If duration or reset data is missing, show
  the quota without guessing a pace status.
- [x] Present pace status with concise text and accessible colors. Do not rely
  on red/green alone; include a symbol or label such as "On pace" and "Over
  pace".

### Candidate follow-ups

- [x] Add a lightweight periodic refresh and visibly mark stale data when the
  Codex service is unavailable. Continue responding immediately to App Server
  rate-limit update notifications.
- [x] Add optional notifications when a window first moves above its ideal
  consumption pace or remaining quota crosses a user-selected threshold.
- [x] Add an optional launch-at-login setting using Apple's native APIs.
- [x] Add a display preference for compact, percentage-only, and progress-plus-
  percentage menu bar styles.
- [x] Add unit tests for quota clamping, window start calculation, reset-time
  boundaries, and pace classification before expanding the pacing UI.

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
run the core unit tests and whitespace check. Changes to `MenuBarExtra`, its
label, or the popover layout also require a UI smoke test: launch exactly one
app instance, click the status item, and confirm the popover opens and its
controls respond.

```bash
swift test
git diff --check
```

`Package.swift` deliberately exposes only `CodexMeter/Core` as the testable
Swift Package target; the macOS app continues to compile the same source through
the Xcode project.
