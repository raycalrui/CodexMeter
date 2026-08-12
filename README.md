# CodexMeter

CodexMeter is a native macOS menu bar app that keeps your Codex account limits
visible at a glance.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![Version](https://img.shields.io/badge/version-1.3.1-blue)

> [!NOTE]
> CodexMeter is an unofficial community project. It is not affiliated with or
> endorsed by OpenAI.

## Features

- Shows the most constrained Codex quota directly in the macOS menu bar.
- Uses two concentric progress rings:
  - outer ring: remaining quota;
  - inner ring: remaining time before reset.
- Highlights normal, over-pace, and low-quota states without relying on color
  alone.
- Displays every quota window returned by Codex, with reset countdowns and
  detailed progress bars.
- Compares remaining quota with remaining time to indicate whether consumption
  is on pace.
- Refreshes on launch, every 60 seconds, after a Codex rate-limit update, and on
  manual request.
- Detects Codex account changes and switches quota data without requiring an app
  restart.
- Preserves the last successful result and marks it as stale when refresh fails.
- Supports optional low-quota and over-pace notifications.
- Supports launch at login.
- Includes English, Simplified Chinese, and Traditional Chinese.
- Offers ring, horizontal-bar, stacked-bar, percentage-only, and progress-only
  menu bar styles.
- Includes developer options with presets, custom quota/time sliders, live
  preview, safe appearance controls,
  deterministic quota-state presets, JSON configuration export, and a one-click
  reset to the accepted 1.0 appearance. Developer-only test data can populate
  30 days of quota history and simulate an available app update.
- Records local quota history as changes plus 15-minute anchors. The full chart
  defaults to the current seven-day reset cycle and can also show the rolling
  last 7 days, 14 days, or month, plus browsable calendar weeks and months.
  Historical ranges show observed quota consumption across reset cycles and
  label incomplete totals as lower bounds instead of estimating missing use.
  Each reset cycle remains a separate smooth curve beginning at 100%, with long
  unrecorded periods visibly shaded.
- Shows a compact view of the current weekly quota cycle plus the last 30 days
  of token activity directly in the menu-bar popover. The full history window
  can switch token activity between 7 days, 30 days, 90 days, one year, and all
  locally retained data. One-year data is grouped by week and all-time data by
  month to remain readable. Token values use compact `k`, `M`, and `B` units
  instead of scientific notation.
- Keeps the menu-bar popover compact with divider-separated quota and token
  sections rather than nested card backgrounds.
- Provides a resizable, full-screen-capable history window with an integrated
  transparent title bar. Hovering a token bar reveals its exact day or grouped
  week/month and compact token count.
- Shows optional daily and summary token activity from `account/usage/read`
  when the current Codex account supports it.
- Accumulates returned daily token buckets locally, clears them on an explicit
  account change, and supports 7-, 30-, 90-day, one-year, or unlimited local
  retention, storage-size reporting, CSV export, and history clearing. CSV
  exports include both the raw Unix timestamp and a readable ISO 8601 local
  time with its UTC offset.
- Uses native Liquid Glass cards and controls on macOS 26, with the same modern
  chart layout and a system-material fallback on earlier supported macOS.
- Includes an About window and Sparkle-based signed updates. It checks daily,
  supports one-click download/install/relaunch, and can optionally download and
  install future updates automatically.

## How It Works

CodexMeter launches the locally installed Codex CLI as:

```text
codex app-server --listen stdio://
```

It then communicates with App Server using newline-delimited JSON-RPC messages:

1. Initialize the local App Server connection.
2. Read account metadata with `account/read`.
3. Read ChatGPT rate-limit windows with `account/rateLimits/read`.
4. Optionally read token activity with `account/usage/read` when supported.
5. Record successful quota snapshots and token summaries in account-separated
   local SQLite partitions. ChatGPT accounts use a salted, one-way local key;
   account email and authentication data are never stored.
6. Refresh when `account/updated` or `account/rateLimits/updated` is received.
7. Recover a stale authentication session by restarting only the local App
   Server child process once.
8. Calculate remaining quota, remaining time, consumption pace, and eligible
   history estimates locally.

CodexMeter does not scrape ChatGPT pages, read Codex authentication files, or
store access tokens. Authentication and token refresh remain owned by Codex.

Codex App Server is currently an experimental interface intended for local
development and debugging, so future Codex releases may require compatibility
updates. See the official [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server).

## Requirements

- macOS 13 or later.
- Xcode 27 beta or later when building the current project from source.
- A locally installed Codex CLI.
- A working Codex login.

Install and sign in to Codex CLI if needed:

```bash
npm install -g @openai/codex
codex login
```

CodexMeter currently discovers `codex` in these locations:

```text
~/.local/bin/codex
/opt/homebrew/bin/codex
/usr/local/bin/codex
~/.npm-global/bin/codex
```

## Build and Run

Clone the repository:

```bash
git clone git@github.com:raycalrui/CodexMeter.git
cd CodexMeter
open CodexMeter.xcodeproj
```

In Xcode:

1. Select the `CodexMeter` scheme.
2. Select **My Mac** as the destination.
3. Press **Run**.

CodexMeter is a menu-bar-only app, so it does not appear in the Dock. Look for
the quota indicator in the macOS menu bar after launch.

## Download and Install

Download `CodexMeter-1.3.1.dmg` from the GitHub Releases page, open it, and drag
CodexMeter into the Applications folder.

The downloadable build uses an ad-hoc signature and is not notarized. On first
launch, macOS may block it. Control-click CodexMeter in Applications, choose
**Open**, and confirm once. A Developer ID certificate and Apple notarization
are planned for a future distribution build.

## Automatic Updates

Starting with version 1.3.0, CodexMeter uses
[Sparkle](https://sparkle-project.org/) to download, verify, replace, and
relaunch the app. Every update archive is signed with a separate EdDSA key, so
this works with the existing ad-hoc app signature and does not require a paid
Apple Developer account. The private EdDSA key remains in the maintainer's
login Keychain and is never stored in the repository or bundled in the app.

Version 1.2.1 does not contain Sparkle, so upgrading from 1.2.1 to 1.3.0 still
requires downloading the DMG manually. Once 1.3.0 is installed, later signed
updates can be installed inside CodexMeter. Because the app is not notarized,
macOS may still show Gatekeeper warnings on a new installation or after an
update; Sparkle does not replace Apple notarization.

## Development

Build from Terminal:

```bash
xcodebuild \
  -project CodexMeter.xcodeproj \
  -scheme CodexMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the core unit tests:

```bash
swift test
```

If Command Line Tools is selected instead of the full Xcode installation, set
`DEVELOPER_DIR` before running either command.

Pure quota, time, pacing, history, migration, and semantic-version logic lives
under `CodexMeter/Core`. `Package.swift` exposes only that directory to Swift
Package Manager so the core logic can be tested independently of the macOS UI.

### Publishing a Sparkle update

After building the unsigned Release app, re-sign the embedded Sparkle framework
and then the outer app bundle. This order is required because Xcode removes
development headers while embedding the framework:

```bash
Scripts/sign_ad_hoc_release.sh /path/to/CodexMeter.app
```

Create the release DMG from that verified app. Then use Sparkle's bundled
`generate_appcast` utility. The helper below reads the private EdDSA key from
the login Keychain, signs the archive metadata, and updates the repository's
`appcast.xml`:

```bash
Scripts/prepare_sparkle_update.sh \
  v1.3.1 \
  /path/to/CodexMeter-1.3.1.dmg \
  /path/to/Sparkle/bin
```

For a prerelease, pass `beta` as the fourth argument. Upload the exact signed
DMG to the matching GitHub Release, commit and push the generated
`appcast.xml`, then verify its download URL before announcing the release.

See [AGENTS.md](AGENTS.md) for the project architecture, product rules,
verification checklist, and planned developer customization options.

## Privacy and Security

- CodexMeter communicates with a local Codex process over stdio.
- It does not copy or persist Codex access tokens.
- It does not read Codex authentication files directly.
- It does not log account email addresses or raw authentication responses.
- It separates ChatGPT account history with a salted SHA-256 key derived
  locally from the account type and normalized email. Neither the email nor
  this internal key is included in CSV exports.
- It does not add its own analytics or tracking.
- Usage history is stored only in
  `~/Library/Application Support/CodexMeter/UsageHistory.sqlite` and can be
  exported or cleared by the user.

App Sandbox is currently disabled because CodexMeter must launch the user's
local Codex executable. This should be reviewed deliberately before any future
Mac App Store distribution.

## Known Limitations

- Codex App Server is experimental and may change without notice.
- Codex executable discovery currently uses a fixed list of common install
  locations rather than the interactive shell's `PATH`.
- Notification and launch-at-login behavior must be tested with a signed build.
- Token activity is optional and may be unavailable for API-key, Bedrock, or
  other account types even when quota windows are available.
- Codex currently provides no stable identifier for API-key and Bedrock
  accounts. CodexMeter therefore cannot restore separate historical profiles
  when switching back and forth between multiple credentials of those types;
  their anonymous history partition is reset on an explicit account change.
- The downloadable DMG is ad-hoc signed, not notarized, and not prepared for
  the Mac App Store, so first launch may require Control-clicking the app and
  choosing **Open**.

## Contributing

Issues and pull requests are welcome.

Before submitting a change:

```bash
swift test
git diff --check
```

For menu bar or popover changes, also launch exactly one signed app instance and
perform a UI smoke test.

## License

CodexMeter is available under the [MIT License](LICENSE).

## Disclaimer

Codex and OpenAI are trademarks of OpenAI. This project is provided as an
independent utility and may stop working when upstream experimental interfaces
change.
