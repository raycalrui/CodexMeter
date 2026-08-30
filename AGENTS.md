# CodexMeter Development Guide

## Project scope

CodexMeter is a native macOS menu bar app built with SwiftUI. It displays the
remaining Codex account quota without requiring the user to open Codex.

- Support macOS 13 or later.
- Keep the app menu-bar-only; do not add a normal window or Dock icon unless the
  product direction changes.
- Prefer Apple frameworks. Sparkle is the deliberate exception used for signed
  in-app updates without requiring an Apple Developer account.
- Make focused changes and preserve the existing architecture.

## Version baseline

- Version 1.0 (build 1) is the first accepted usable release baseline. The
  current released version is 1.5.1 (build 16).
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
  colors as the menu bar indicator. The popover also presents compact weekly
  quota history and 30-day token activity as separate, divider-separated links
  to the full Usage History window. Render optional popover sections from the
  user's stored order while keeping the header, refresh and freshness state,
  Settings, and Quit controls permanently reachable.
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
- `Core/RateLimitResetCredits.swift` decodes optional banked-reset summaries and
  detail rows from the rate-limit response. Missing or `null` summaries mean
  unavailable information rather than a confirmed zero balance.
- `Core/HistoryAccountIdentity.swift`, `Core/HistoryModels.swift`,
  `Core/UsageHistoryStore.swift`, and `Core/SemanticVersion.swift` contain
  testable pseudonymous account partitioning, history, SQLite migration,
  retention, CSV, estimation, gap, and semantic-version logic.
- `UsageHistoryModel.swift` bridges the actor-backed SQLite store to the UI.
  `UsageHistoryView.swift` owns the quota and token range filters, export/clear
  actions, and the separate quota/token presentation.
  `HistoryChartComponents.swift` owns shared token chart data, compact `k/M/B`
  formatting UI, hover selection, and the macOS 26 Liquid Glass card with an
  earlier-system material fallback. Keep the full history view in an
  independent, resizable, full-screen-capable Window scene with a transparent
  integrated title bar so charts and save/confirmation panels survive menu bar
  popover focus changes. Use the native traffic-light controls instead of an
  additional in-content Close button.
- `UpdateChecker.swift` adapts Sparkle's standard updater to app state, stable
  and beta channels, manual checks, and the automatic-install preference.
  Sparkle owns the daily schedule, signed download, replacement, and relaunch.
  `AboutView.swift` presents version/build, update channel, automatic-install
  preference, repository, local data location, privacy, and license status.
- Developer Options can create a separately identified 30-day history fixture
  and a temporary v9.9.9 update state. These fixtures must not change live quota,
  send notifications, or survive as real release state.
- `Core/MenuBarAppearance.swift` contains bounded, codable appearance values and
  deterministic developer preview fixtures, including custom quota/time values.
  `DeveloperOptionsView.swift` provides live appearance tuning without touching
  account data. Present it in
  its own `Window` scene because a sheet attached to `MenuBarExtra(.window)` is
  dismissed as soon as the status-item window loses focus.
- `Core/PopoverContentConfiguration.swift` stores presentation-only popover
  visibility, ordering, per-quota-window choices, and the stable quota identity
  used by the menu bar indicator. Reset opportunities and Token Activity are
  shown by default, while missing selected windows fall back to the lowest
  remaining quota.
  `PopoverCustomizationView.swift` presents these controls and a live preview in
  an independent Window so picker and button interactions survive popover focus
  changes. Hidden sections must continue refreshing and recording history.
- `AppSettings.swift` persists in-app language, menu bar, popover content,
  notification, threshold, launch-at-login, and separately namespaced developer preferences.
  `NotificationManager.swift` owns local notification state and checks the
  existing system authorization before requesting it.
- `Localizable.xcstrings` is the source of English, Simplified Chinese, and
  Traditional Chinese user-facing strings.
- Use `account/read` for account metadata and `account/rateLimits/read` for quota
  windows plus optional banked-reset availability. Refresh after
  `account/rateLimits/updated` notifications. Treat
  `account/updated` as an account boundary: clear the previous account's visible
  quota and notification state, deactivate its history partition, then re-read
  with token refresh enabled. If the existing App Server rejects or stalls that
  refresh, restart only the child App Server once and retry through normal
  initialization.

Do not scrape ChatGPT web pages, read Codex authentication files directly, or
copy access tokens into app storage. Authentication and token refresh belong to
Codex App Server.

## History and update rules

- Store successful non-stale quota changes plus an unchanged 15-minute anchor
  in `~/Library/Application Support/CodexMeter/UsageHistory.sqlite`.
- Persist quota history under a duration-scoped bucket identity rather than the
  App Server's positional `primary`/`secondary` slot. SQLite schema v5 repairs
  both pre-v4 rows and raw IDs appended by an older process during the v4
  upgrade so a slot swap cannot hide, duplicate, or combine quota windows.
- Normalize small reset timestamp jitter and a sliding reset while quota remains
  at 100%; neither represents a real quota cycle boundary. Apply the same
  normalization when rendering older rows so historical timestamp drift cannot
  create overlapping curves.
- Keep quota percentage and token activity as separate metrics. Treat
  `account/usage/read` as optional and never turn its absence into a quota
  refresh failure.
- Default Quota History to the current weekly reset cycle on a fixed seven-day
  domain. Also offer rolling 7-day, 14-day, and one-month ranges plus natural
  calendar weeks and months. Keep Current cycle, Last 7 days, Last 14 days, and
  Last month in the primary selector, then expose natural-period navigation
  behind a final Browse option. Browse supports Week/Month, previous/next
  navigation, a return-to-current action, and stops at the oldest retained
  sample. Resolve natural boundaries with the user's calendar and time zone,
  and query each calendar interval lazily from SQLite. Start each visible cycle
  at 100% at its reset boundary and keep separate reset cycles as separate curve
  series rather than smoothing across the reset jump. Use the same custom
  capsule selector style for quota and token history.
- Let the full Quota History window select every quota window returned by the
  service. Use each window's returned duration for cycle starts, chart domains,
  ideal pace, and consumption totals; never force shorter windows onto a
  seven-day cycle or add different quota-window types together.
- Calculate **Observed quota consumed** from raw remaining-quota samples within
  the displayed interval, but omit this summary for **Current cycle** because
  the remaining-quota metric already communicates that single-cycle state.
  Establish 100% only at a known reset boundary, use
  the first in-range sample for a clipped leading cycle, and add each cycle's
  observed decrease so totals may exceed 100%. If the leading or trailing
  boundary is unobserved, or a gap can hide an entire cycle, label the result as
  a lower bound such as **At least 220%** instead of estimating missing use.
- Draw one monotonic smooth curve through recorded points. Keep it continuous
  across missing periods, but shade gaps longer than 30 minutes so interpolation
  cannot be mistaken for confirmed usage. Draw the actual quota trend directly
  from recorded points with the accepted thin, dense rounded-dash style at 55%
  opacity: the full chart uses a 1.25-point `[2, 4]` stroke and the compact chart
  uses a 1-point `[1, 3]` stroke. Retain the 28% full-chart and 22% compact-chart area fills.
  Apply a display-only centered five-point `[1, 4, 6, 4, 1]` weighted average to
  the dashed trend line within each reset cycle, preserving its first and last
  points. Render the gradient area from raw samples. Never write smoothed or
  fabricated intermediate samples into SQLite.
- Only show a quota-exhaustion estimate for at least three monotonic samples in
  one continuous segment spanning at least 15 minutes and changing by at least
  two percentage points. Suppress estimates at or beyond the official reset.
- Partition quota samples, token buckets, summaries, history views, developer
  fixtures, and CSV exports by a local account key. For ChatGPT accounts, derive
  that key from normalized account type and email using SHA-256 plus a random
  installation-local salt; never persist or export the email itself. SQLite
  schema v3 assigns pre-upgrade rows to `legacy`, then lets the first identifiable
  account claim them only when that account has no existing rows. API-key and
  Bedrock responses expose no stable identifier, so reuse one anonymous key
  between launches but clear that partition on an explicit account boundary.
- Upsert token daily buckets so each account's local chart can accumulate beyond
  the endpoint's recent window. The popover shows 30 days; the full window offers
  7-day, 30-day, 90-day, one-year, and all-data views with `k/M/B` labels.
  Keep daily bars through 90 days, group one-year data weekly, and group all-time
  data monthly so long ranges remain legible.
- Show the preferred weekly quota cycle as a compact, axis-free chart in the
  popover above Token Activity. Reuse the full history chart component and the
  same fixed seven-day cycle rather than maintaining separate calculations.
- Keep the token Chart mark tree static during hover. Resolve the selected bar's
  temporal bucket midpoint (12 hours for a day, 3.5 days for a week, and half
  the real calendar-month duration for a month) through `ChartProxy`. Pass the
  same UTC Gregorian calendar to `BarMark` that token aggregation and midpoint
  calculation use so local time zones cannot shift the rule. Then draw
  both its rule and tooltip in `chartOverlay`. Keep the rule centered on the
  selected bar, let the tooltip
  follow the pointer in both axes, and clamp only the tooltip to the plot edges
  so the first and last bars never move. Give the selected bucket a clear
  style response without changing mark geometry, and use an opaque tooltip
  surface rather than nesting another material inside Liquid Glass.
  Build every token chart's horizontal calendar axis independently from its
  recorded bars. Keep empty day, week, or month buckets on the timeline without
  fabricating zero-token bars, then sample labels from that complete axis.
  Feed every UTC bucket start to `AxisMarks`, render text only for the sampled
  labels, and use `AxisValueLabel(centered: true)` so Swift Charts centers each
  visible date with the same temporal interval used by its `BarMark`. Include
  one unlabeled trailing boundary mark so the final visible bucket has a next
  interval and its label does not fall back to the bucket's leading edge.
  Animate hover selection without changing mark geometry: ease bar opacity and
  the centered rule over roughly 150 ms. Keep the tooltip entirely unanimated
  so its appearance, content, and pointer-following position update immediately.
  Disable the remaining transitions when Reduce Motion is enabled.
- Apply the selected 7-, 30-, 90-day, one-year, or forever retention locally;
  default new installations to forever because daily buckets are small. CSV exports
  include only the active account and contain both raw Unix timestamps and
  readable ISO 8601 local times with UTC offsets. They may contain calculated
  quota fields and token counts, but never an account key, account email,
  authentication data, or raw App Server responses.
- Use Sparkle's HTTPS appcast and EdDSA verification for every downloadable
  update. Keep the public key in `Config/CodexMeter-Info.plist` and the private
  key only in the maintainer's login Keychain. Check daily, keep stable as the
  default channel, and use `beta` only when prereleases are enabled. Automatic
  download and installation must remain an explicit user preference.
- Generate release entries with `Scripts/prepare_sparkle_update.sh`, upload the
  exact signed archive to the matching GitHub Release, and verify the appcast's
  URL and signature before publishing. Version 1.2.1 cannot self-update to
  1.3.0; the first Sparkle-enabled upgrade remains a manual DMG installation.
- For ad-hoc releases, run `Scripts/sign_ad_hoc_release.sh` on the built app
  before creating the DMG. It re-signs the stripped embedded Sparkle framework
  before signing and strictly verifying the outer app bundle.

## Quota display rules

- The API returns `usedPercent`; calculate remaining quota as
  `100 - usedPercent` and clamp it to `0...100`.
- Display every returned quota window in the popover.
- Separate quota windows, Token Activity, Settings, and the footer with dividers
  in the popover. Do not add nested card backgrounds around quota or token
  sections; the menu-bar window already provides the containing surface.
- Display the lowest remaining percentage in the menu bar so the most
  constrained window is always visible.
- Label the percentage as Codex remaining quota. Visual state priority is:
  below 20% is critical/red; otherwise above ideal pace is warning/yellow;
  otherwise use the normal system/accent color. Apply the same rule to the
  detail quota bar.
- In the menu bar, the outer ring represents remaining quota and follows the
  quota state color. The inner ring represents remaining time in blue. Do not
  draw the inner ring when the server does not provide enough reset timing data.
- Resolve dynamic AppKit colors against SwiftUI's current color scheme before
  passing them to native progress controls. Also key each metric
  `ProgressView` to `colorScheme` so AppKit cannot reuse a control whose tint it
  reset during a live appearance change and leave it at accent blue.
- Show a localized countdown to reset in the detail footer instead of repeating
  the used percentage.
- When `rateLimitResetCredits` is present, show its confirmed available count in
  a read-only, divider-separated popover section. Show usable detail rows with
  backend title, description, grant time, and expiration when provided. For a
  valid grant-to-expiration interval, draw a minute-updated remaining-lifetime
  progress bar that starts at 100% when granted and reaches 0% at expiration.
  Omit the bar instead of guessing when expiration or a valid interval is
  missing. Do not expose a redemption action or interpret missing data as zero.
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
- Version 1.5.1 is distributed with an ad-hoc signature and no notarization
  because no valid Apple signing identity was available at release time. Do not
  describe it as Apple Development or Developer ID signed. Replace this with a
  Developer ID and notarized workflow before claiming frictionless distribution.
- Sparkle's EdDSA signature authenticates update archives independently of the
  app's ad-hoc code signature. It does not notarize the app or remove Gatekeeper
  warnings.
- Keep the deployment target at macOS 13 unless a new API requires a later OS.

## Roadmap / TODO

### Confirmed next features

- [x] Add update checking against the project's GitHub Releases. Provide a
  manual **Check for Updates** action and daily checks. Use Sparkle's EdDSA-
  signed appcast for one-click download, installation, and relaunch. Ignore
  prereleases unless explicitly enabled, keep the current version usable when
  checks fail, and offer automatic download/install only as an explicit user
  preference. Keep Apple notarization as a separate future distribution step.

- [x] Add an **About CodexMeter** page that shows the installed version and
  build number, GitHub repository link, update-check action, stable/prerelease
  update-channel preference, local data location, concise privacy explanation,
  and open-source license information. Keep account identity and authentication
  details out of this page.

- [x] Add a usage-history section to the details popover with two separate
  views so quota percentage and token activity are never presented as the same
  metric:
  - **Quota History**: record timestamped snapshots from
    `account/rateLimits/read` and `account/rateLimits/updated`, with separate
    series for every returned quota window;
  - **Token Activity**: request `account/usage/read` and display available daily
    token buckets plus lifetime tokens, peak daily tokens, current and longest
    streaks, and longest-running turn duration.
- [x] Plot the current weekly Quota History on a fixed seven-day horizontal
  domain and `0...100` vertical scale. Begin every new cycle at 100%, connect
  available samples with a monotonic smooth curve, shade long missing-data
  periods without breaking the curve, and retain a distinct ideal-consumption
  reference line.
- [x] Add Quota History range controls for the current reset cycle, rolling
  7-day, 14-day, and one-month views. Preserve per-cycle ideal pace lines,
  reset boundaries, and missing-data shading across longer ranges.
- [x] Treat Quota History as near-real-time rather than per-token telemetry.
  Record immediately after a successful refresh or App Server rate-limit
  update. Avoid duplicate minute-by-minute rows by recording changes plus a
  periodic 15-minute anchor. Preserve step changes because `usedPercent` is an
  integer snapshot rather than a continuous measurement.
- [x] Store chart history locally with no cloud sync. Let the user select a
  retention period of 7 days, 30 days, 90 days, or forever; show the current
  local storage size; and provide actions to export CSV and clear all local
  history. Version the storage schema and add tested forward migrations so an
  app update can preserve older history when fields or indexes change. A failed
  migration must not prevent the menu bar app from launching. Never include
  account email addresses, authentication data, or raw server responses in the
  stored or exported records.
- [x] Show explicit shaded gaps whenever the app was not running or data was
  stale. Keep the visual curve continuous for readability, but never backfill
  stored samples or imply that the shaded interpolation is confirmed usage.
  Treat a changed reset timestamp or a falling used percentage as a new cycle.
- [x] Add an optional quota-exhaustion estimate only after enough recent samples
  exist to support a meaningful trend. Label it as an estimate, show when it was
  calculated, suppress it for sparse, stale, reset-crossing, or non-monotonic
  data, and never replace the official reset time with a prediction.
- [x] Handle `account/usage/read` as optional account-dependent data.
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

- [x] Re-investigate the **quota progress-bar tint regression after a live
  Light/Dark appearance switch**. While CodexMeter remains running, switching
  the system appearance can make both five-hour and weekly quota bars fall back
  to accent blue even though their status labels remain green and the time bars
  keep the configured time color. Dynamic-color resolution alone was not
  sufficient because SwiftUI reused the same native `NSProgressIndicator` as
  AppKit reset its tint. Key the control identity to `colorScheme` so each
  appearance gets a newly tinted control while preserving all existing
  normal/warning/critical color rules.

- [x] Display available **Codex rate-limit reset opportunities** from
  `rateLimitResetCredits` in the existing `account/rateLimits/read` response.
  Show `availableCount` in the details popover and, when supplied by the
  backend, each available reset's title, description, grant time, and expiration
  time. Show a minute-updated remaining-lifetime progress bar when the backend
  provides a valid grant-to-expiration interval. Treat a `null` summary or
  missing detail rows as unavailable information, not as a confirmed zero
  balance, and distinguish banked resets from purchased credits and automatic
  quota-window resets. Refresh this state with the normal quota request,
  localize it in all supported languages, and cover nullable, count-only,
  detailed, and expired responses with tests. Keep the first version read-only;
  do not call `account/rateLimitResetCredit/consume` until a separate, explicitly
  confirmed redemption design prevents accidental use.

- [x] Add **menu-bar popover content customization** in Settings. Let users
  independently show or hide each quota window returned by Codex—including the
  weekly and five-hour limits—plus reset opportunities, compact Quota History,
  and Token Activity. Generate quota-window choices from the returned duration
  and identity instead of hard-coding only known products. Let users reorder the
  enabled sections with a clear live preview. Preserve the current layout as the
  default and provide a one-click reset to that default. Keep the app
  header/refresh action, Settings entry, freshness or error status, and Quit
  action always reachable so a user cannot hide the controls needed to restore
  the layout. Treat visibility as presentation only: hiding a quota window or
  section must not clear history, stop background collection, or change refresh
  behavior. Persist the preference locally and localize and accessibility-label
  every customization control.

- [ ] Add an optional **System Monitor** module, starting with real-time network
  throughput in the menu bar. Show separate upload and download rates with
  automatically scaled `B/s`, `KB/s`, `MB/s`, and `GB/s` units, plus selectable
  compact display styles and a more detailed popover view. Read only local
  interface byte counters at a low-overhead interval; do not capture packets,
  destinations, domains, or traffic contents. Define how Wi-Fi, Ethernet, VPN,
  virtual adapters, interface switching, sleep/wake, and counter resets are
  handled before implementation. Keep this module optional and architecturally
  separate from Codex quota/history so it can be disabled without affecting
  refresh, notifications, or account data. Evaluate CPU, memory, temperature,
  and similar system indicators later as separate modules rather than bundling
  them into the first network-speed release.

- [ ] Add a lossless **CodexMeter Backup** export and restore workflow for
  moving all local history to another Mac. Use a versioned
  `.codexmeterbackup` archive rather than treating CSV as a database backup.
  Create a transactionally consistent SQLite snapshot with the SQLite backup
  API so live WAL/SHM state cannot be missed, and include a small manifest with
  backup format version, database schema version, creation time, app version,
  integrity checksum, and the installation history-identity salt required to
  preserve every opaque account partition on the destination Mac. Include all
  quota windows, quota samples, token daily buckets, token summaries, and
  retention-independent history, but never include Codex authentication,
  access tokens, account email addresses, raw App Server responses, or unrelated
  app preferences. Treat restore as an explicit full replacement for the first
  version: validate the archive and reject unsupported newer schemas, create an
  automatic recoverable backup of the destination's existing history and salt,
  stop database writes, atomically replace and reopen the store, restore the
  identity salt before account activation, then verify row counts/checksums and
  refresh or relaunch the app. Clearly warn that existing local history will be
  replaced, never silently merge, and add tests for WAL-consistent backup,
  corrupted archives, schema compatibility, rollback after failed restore,
  multi-account isolation, and successful migration to a fresh Mac. Keep CSV
  export as a separate human-readable feature; CSV import is not required for
  this lossless restore workflow.

- [x] Add an **Observed quota consumed** summary for the currently selected
  quota window and visible date interval. Sum the monotonic remaining-quota
  decreases within each reset cycle so multiple cycles may legitimately exceed
  100% (for example, `50% + 80% + 90% = 220%`). Include the current unfinished
  cycle and let the quota-window picker expose every returned window, including
  shorter windows currently hidden when a weekly window exists. Never add
  different quota-window types together because five-hour and weekly limits can
  describe the same underlying usage. Derive this metric from raw samples and
  reset boundaries rather than smoothed chart points. If a
  cycle or selected interval contains an unobserved boundary, stale period, or
  retention gap that prevents an exact baseline or ending value, present the
  result explicitly as a lower bound such as **At least 220% observed**, and
  expose the incomplete-data cue instead of fabricating missing consumption.
  Add tests for complete cycles, partial cycles, interval boundaries, resets,
  missing samples, and totals greater than 100%.

- [x] Add calendar-period browsing to Quota History without removing the
  existing current-cycle and rolling 7-, 14-, and 30-day views. Organize the
  primary control as **Current cycle / Last 7 days / Last 14 days / Last month /
  Browse**; only Browse reveals **Week / Month** and calendar navigation. In
  Browse mode, use previous/next arrows plus a centered exact range label to
  browse this week, last week, older complete weeks, this month, last month,
  and older complete months. Disable navigation into future periods and provide
  a compact action to return to the current week or month. Resolve natural week
  and month boundaries with the user's current calendar and time zone. Query
  the selected interval lazily from SQLite instead of relying on the model's
  current 30-day in-memory quota snapshot, and stop at the oldest retained data;
  an empty or retention-pruned period must show an honest no-data state. Keep
  the summary, chart, gaps, reset-cycle segmentation, and CSV/account isolation
  scoped to the selected quota window and displayed interval.

- [x] Rebuild the Usage History title area as a system-style translucent glass
  header. Keep a compact 14-point gap between the title banner and the initial
  Quota History card, keep the header visually fixed, and let quota/token
  content scroll visibly beneath its material so the glass responds to the
  content behind it. Preserve native window safe areas and traffic-light
  placement.

- [ ] Redesign the Token Activity panel in a future pass. Keep the current data,
  range behavior, account isolation, and hover accuracy intact until the visual
  and interaction requirements are specified.
  - [x] Make the selected bar respond without changing chart geometry, keep the
    dashed rule centered on the real plotted bar, and let the opaque tooltip
    follow the pointer with four-edge clamping across 7-day, 30-day, 90-day,
    one-year, and all-data ranges.
  - [ ] Complete the remaining visual and data-presentation redesign after its
    requirements are specified.

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

After every successful Git commit, automatically push the current branch to
its configured GitHub remote and verify that the remote commit matches local
`HEAD`. Do not create a commit merely because files changed; this rule applies
only after a commit has already been requested or created as part of the task.

Build from the repository root with Xcode 27 beta or later:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
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
