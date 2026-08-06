# CodexMeter

CodexMeter is a native macOS menu bar app that keeps your Codex account limits
visible at a glance.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![Version](https://img.shields.io/badge/version-1.1.0-blue)

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
- Preserves the last successful result and marks it as stale when refresh fails.
- Supports optional low-quota and over-pace notifications.
- Supports launch at login.
- Includes English, Simplified Chinese, and Traditional Chinese.
- Offers ring, horizontal-bar, stacked-bar, percentage-only, and progress-only
  menu bar styles.
- Includes developer options with presets, custom quota/time sliders, live
  preview, safe appearance controls,
  deterministic quota-state presets, JSON configuration export, and a one-click
  reset to the accepted 1.0 appearance.

## How It Works

CodexMeter launches the locally installed Codex CLI as:

```text
codex app-server --listen stdio://
```

It then communicates with App Server using newline-delimited JSON-RPC messages:

1. Initialize the local App Server connection.
2. Read account metadata with `account/read`.
3. Read ChatGPT rate-limit windows with `account/rateLimits/read`.
4. Refresh when `account/rateLimits/updated` is received.
5. Calculate remaining quota, remaining time, and consumption pace locally.

CodexMeter does not scrape ChatGPT pages, read Codex authentication files, or
store access tokens. Authentication and token refresh remain owned by Codex.

Codex App Server is currently an experimental interface intended for local
development and debugging, so future Codex releases may require compatibility
updates. See the official [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server).

## Requirements

- macOS 13 or later.
- Xcode 26 or later when building from source.
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

Download `CodexMeter-1.1.1.dmg` from the GitHub Releases page, open it, and drag
CodexMeter into the Applications folder.

The downloadable build is signed with an Apple Development certificate but is
not notarized. On first launch, macOS may block it. Control-click CodexMeter in
Applications, choose **Open**, and confirm once. A Developer ID certificate and
Apple notarization are planned for a future distribution build.

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

The pure quota, time, and pacing calculations live in
`CodexMeter/Core/QuotaModels.swift`. `Package.swift` exposes only that directory
to Swift Package Manager so the core logic can be tested independently of the
macOS UI.

See [AGENTS.md](AGENTS.md) for the project architecture, product rules,
verification checklist, and planned developer customization options.

## Privacy and Security

- CodexMeter communicates with a local Codex process over stdio.
- It does not copy or persist Codex access tokens.
- It does not read Codex authentication files directly.
- It does not log account email addresses or raw authentication responses.
- It does not add its own analytics or tracking.

App Sandbox is currently disabled because CodexMeter must launch the user's
local Codex executable. This should be reviewed deliberately before any future
Mac App Store distribution.

## Known Limitations

- Codex App Server is experimental and may change without notice.
- Codex executable discovery currently uses a fixed list of common install
  locations rather than the interactive shell's `PATH`.
- Notification and launch-at-login behavior must be tested with a signed build.
- The downloadable DMG is not notarized and is not prepared for the Mac App
  Store, so first launch may require Control-clicking the app and choosing
  **Open**.

## Contributing

Issues and pull requests are welcome.

Before submitting a change:

```bash
swift test
git diff --check
```

For menu bar or popover changes, also launch exactly one signed app instance and
perform a UI smoke test.

## Disclaimer

Codex and OpenAI are trademarks of OpenAI. This project is provided as an
independent utility and may stop working when upstream experimental interfaces
change.
