# CodexMeter Development Guide

## Project scope

CodexMeter is a native macOS menu bar app built with SwiftUI. It displays the
remaining Codex account quota without requiring the user to open Codex.

- Support macOS 13 or later.
- Keep the app menu-bar-only; do not add a normal window or Dock icon unless the
  product direction changes.
- Prefer Apple frameworks and avoid third-party dependencies for this small app.
- Make focused changes and preserve the existing architecture.

## Version baseline

- Version 1.0 (build 1) is the first accepted usable release baseline. The
  current development version is 1.1.2 (build 4).
- Keep source comments in English and reserve them for non-obvious architecture,
  protocol, state, permission, and calculation behavior. Do not narrate obvious
  Swift syntax line by line.
- Keep `README.md` synchronized with public features, build requirements,
  privacy behavior, known limitations, and the experimental App Server caveat.
- The accepted menu bar baseline uses a compact 18-point dual-ring indicator
  with visually prominent strokes: outer quota at 3 points and inner time at
  2 points. Use the brighter blue appearance choice for the default time color
  so the thinner inner ring remains legible.
- The accepted application icon uses a warm ivory background with a burgundy
  abstract code mark and a cream segmented meter with a coral active segment.
  Keep the source icon simple and legible at the 16-point macOS size.

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
  Its quota and time progress bars use the same configurable status and time
  colors as the menu bar indicator.
- `MenuBarProgressView.swift` draws the selected ring, bar, percentage, and
  caption style into an original-color `NSImage`. Keep the status-item label
  free of nested dynamic layout containers. Omit time indicators when reset
  timing is missing.
- `CodexUsageService.swift` launches the installed `codex app-server` process
  over stdio, communicates with it using newline-delimited JSON-RPC, and owns
  refresh/freshness state. Always drain both stdout and stderr, detach file-
  handle callbacks at EOF or process termination, and close retained handles
  during teardown so pipe readiness cannot create a CPU spin loop.
- `Core/QuotaModels.swift` contains pure quota, remaining-time, and consumption-
  pace calculations shared with the Swift Package unit tests.
- `Core/MenuBarAppearance.swift` contains bounded, codable appearance values and
  deterministic developer preview fixtures, including custom quota/time values.
  `DeveloperOptionsView.swift` provides live appearance tuning without touching
  account data. Present it in
  its own `Window` scene because a sheet attached to `MenuBarExtra(.window)` is
  dismissed as soon as the status-item window loses focus.
- `AppSettings.swift` persists in-app language, menu bar, notification,
  threshold, launch-at-login, and separately namespaced developer preferences.
  `NotificationManager.swift` owns local notification state and checks the
  existing system authorization before requesting it.
- `Localizable.xcstrings` is the source of English, Simplified Chinese, and
  Traditional Chinese user-facing strings.
- Use `account/read` for account metadata and `account/rateLimits/read` for quota
  windows. Refresh after `account/rateLimits/updated` notifications. Treat
  `account/updated` as an account boundary: clear the previous account's visible
  quota and notification state, then re-read with token refresh enabled. If the
  existing App Server rejects or stalls that refresh, restart only the child
  App Server once and retry through normal initialization.

Do not scrape ChatGPT web pages, read Codex authentication files directly, or
copy access tokens into app storage. Authentication and token refresh belong to
Codex App Server.

## Quota display rules

- The API returns `usedPercent`; calculate remaining quota as
  `100 - usedPercent` and clamp it to `0...100`.
- Display every returned quota window in the popover.
- Display the lowest remaining percentage in the menu bar so the most
  constrained window is always visible.
- Label the percentage as Codex remaining quota. Visual state priority is:
  below 20% is critical/red; otherwise above ideal pace is warning/yellow;
  otherwise use the normal system/accent color. Apply the same rule to the
  detail quota bar.
- In the menu bar, the outer ring represents remaining quota and follows the
  quota state color. The inner ring represents remaining time in blue. Do not
  draw the inner ring when the server does not provide enough reset timing data.
- Show a localized countdown to reset in the detail footer instead of repeating
  the used percentage.
- Use returned window durations and reset timestamps instead of hard-coding the
  account's quota structure.
- Never log account email addresses, tokens, or raw authentication responses.

## Refresh and freshness rules

- Refresh immediately at launch, every 60 seconds, after an App Server rate-
  limit notification, and when the user requests it manually.
- Skip a refresh while the previous rate-limit request is still in flight.
- Time out a rate-limit request after 20 seconds.
- On failure, retain the last successful quota snapshot and mark it as possibly
  stale instead of clearing the menu bar. The exception is an explicit
  `account/updated` notification, where showing the previous account's quota
  would be misleading.
- Recalculate remaining-time UI locally once per minute without an extra server
  request.

## macOS settings

- `LSUIElement` must remain enabled so the app does not appear in the Dock.
- Keep the app category set to `public.app-category.utilities`.
- App Sandbox is currently disabled because the app needs to launch the user's
  locally installed Codex executable. Revisit this deliberately before any Mac
  App Store distribution work.
- Compile-only builds may disable code signing, but notification and
  `SMAppService` testing must use a signed build (Xcode's "Sign to Run Locally"
  is sufficient for local development).
- Keep the deployment target at macOS 13 unless a new API requires a later OS.

## Roadmap / TODO

### Confirmed next features

- [ ] Add a usage-history section to the details popover with two separate
  views so quota percentage and token activity are never presented as the same
  metric:
  - **Quota History**: record timestamped snapshots from
    `account/rateLimits/read` and `account/rateLimits/updated`, with separate
    series for every returned quota window;
  - **Token Activity**: request `account/usage/read` and display available daily
    token buckets plus lifetime tokens, peak daily tokens, current and longest
    streaks, and longest-running turn duration.
- [ ] Plot Quota History as a time-series chart with time on the horizontal
  axis and remaining quota on a fixed `0...100` vertical scale. Overlay an ideal
  consumption reference line, distinguish actual data from the reference
  visually and textually, and mark reset boundaries. Provide 24-hour, 7-day,
  and 30-day ranges plus a quota-window selector.
- [ ] Treat Quota History as near-real-time rather than per-token telemetry.
  Record immediately after a successful refresh or App Server rate-limit
  update. Avoid duplicate minute-by-minute rows by recording changes plus a
  periodic 15-minute anchor. Preserve step changes because `usedPercent` is an
  integer snapshot rather than a continuous measurement.
- [ ] Store chart history locally with a bounded retention policy and no cloud
  sync. Provide actions to export CSV and clear all local history. Never include
  account email addresses, authentication data, or raw server responses in the
  stored or exported records.
- [ ] Show explicit gaps whenever the app was not running or data was stale.
  Do not interpolate, backfill, or imply that missing samples are confirmed
  usage. Treat a changed reset timestamp or a falling used percentage as a new
  quota-window segment.
- [ ] Add an optional quota-exhaustion estimate only after enough recent samples
  exist to support a meaningful trend. Label it as an estimate, show when it was
  calculated, suppress it for sparse, stale, reset-crossing, or non-monotonic
  data, and never replace the official reset time with a prediction.
- [ ] Handle `account/usage/read` as optional account-dependent data.
  `dailyUsageBuckets` and summary fields may be absent, and API-key-only or
  Bedrock authentication may not support this endpoint. Show an unavailable
  state without treating it as a network failure or fabricating token counts.

- [x] Add an expandable Developer Options section for live menu bar appearance
  tuning. Persist experimental values separately from normal user preferences
  and provide a one-click reset to the accepted 1.0 defaults. Include controls
  for:
  - percentage font size, weight, and vertical position;
  - caption text, visibility, font size, weight, color, and vertical position;
  - overall indicator width and height;
  - ring diameter, outer and inner stroke widths, ring gap, start angle, and
    background-track opacity;
  - spacing between the indicator and text, plus horizontal padding;
  - normal, warning, critical, time-ring, and stale-indicator colors;
  - stale-indicator visibility, size, and placement.
  Clamp every numeric control to a safe rendering range so experimental values
  cannot create a zero-sized or excessively large status item.
- [x] Add multiple selectable menu bar visualization styles while keeping the
  current concentric-ring design as the default:
  - concentric quota/time rings with percentage and optional caption;
  - a horizontal progress bar beside the percentage;
  - a compact progress bar below the percentage, replacing the `Codex` caption;
  - two compact horizontal bars for remaining quota and remaining time;
  - percentage-only and progress-only minimal variants.
  Every style must retain a non-color status cue and a localized accessibility
  description. Styles that cannot show reset timing must not invent it.
- [x] Add developer-only preview data so every visual state can be tested
  without changing or waiting for the real account quota. Provide presets for
  normal, over-pace/warning, below-20-percent/critical, zero quota, stale data,
  missing reset timing, long localized text, and all supported languages. Make
  preview mode visually identifiable, keep it local, never send notifications
  from preview values, and return to live data with one action. Provide custom
  `0...100%` sliders for remaining quota and remaining time; moving either
  slider switches the preview preset to Custom.
- [x] Add a live preview area inside Developer Options and an action to copy the
  active appearance configuration as readable JSON for bug reports and future
  design comparisons. Do not include account metadata or quota snapshots in the
  exported configuration.

- [x] Replace or augment the static menu bar symbol with a compact progress
  indicator that visualizes the most constrained window's remaining quota.
  Keep the numeric percentage visible so the state is not communicated by
  shape or color alone.
- [x] Localize the complete UI into English (`en`), Simplified Chinese
  (`zh-Hans`), and Traditional Chinese (`zh-Hant`). Move user-facing strings to
  a String Catalog, remove hard-coded Chinese strings from Swift source, and
  allow language selection inside the app with a system-default option.
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

- [x] Expand the Settings disclosure hit target so clicking the gear icon,
  localized Settings label, or the surrounding row opens and closes the
  section. Keep the visual layout compact, but provide a comfortable pointer
  target instead of requiring a click on the small disclosure symbol.
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
