#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
    echo "Usage: $0 <CodexMeter.app>" >&2
    exit 64
fi

app_path="$1"
sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"

if [[ ! -d "$app_path" || "${app_path:e}" != "app" ]]; then
    echo "App bundle not found: $app_path" >&2
    exit 66
fi

if [[ ! -d "$sparkle_framework" ]]; then
    echo "Embedded Sparkle framework not found: $sparkle_framework" >&2
    exit 66
fi

# Xcode strips framework headers when embedding Sparkle, so its original
# resource seal no longer matches. Re-sign the embedded framework before the
# outer app bundle to produce a valid ad-hoc distribution build.
codesign --force --sign - "$sparkle_framework"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

echo "Ad-hoc signature verified: $app_path"
