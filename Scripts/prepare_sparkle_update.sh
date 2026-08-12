#!/bin/zsh

set -euo pipefail

if (( $# < 3 || $# > 4 )); then
    echo "Usage: $0 <tag> <dmg-or-zip> <sparkle-bin-directory> [channel]" >&2
    exit 64
fi

release_tag="$1"
archive_path="$2"
sparkle_bin_directory="$3"
release_channel="${4:-}"
project_directory="${0:A:h:h}"
generate_appcast="$sparkle_bin_directory/generate_appcast"

if [[ ! -f "$archive_path" ]]; then
    echo "Update archive not found: $archive_path" >&2
    exit 66
fi

if [[ ! -x "$generate_appcast" ]]; then
    echo "generate_appcast not found: $generate_appcast" >&2
    exit 69
fi

case "${archive_path:e:l}" in
    dmg|zip) ;;
    *)
        echo "Sparkle updates must be a .dmg or .zip archive." >&2
        exit 65
        ;;
esac

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/codexmeter-appcast.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

cp "$archive_path" "$work_directory/"
cp "$project_directory/appcast.xml" "$work_directory/appcast.xml"

archive_stem="${archive_path:t:r}"
for notes_extension in html md txt; do
    notes_path="${archive_path:h}/${archive_stem}.${notes_extension}"
    if [[ -f "$notes_path" ]]; then
        cp "$notes_path" "$work_directory/"
        break
    fi
done

arguments=(
    --download-url-prefix "https://github.com/raycalrui/CodexMeter/releases/download/${release_tag}/"
    --full-release-notes-url "https://github.com/raycalrui/CodexMeter/releases/tag/${release_tag}"
    --link "https://github.com/raycalrui/CodexMeter/releases/tag/${release_tag}"
    --maximum-deltas 0
    -o "$project_directory/appcast.xml"
)

if [[ -n "$release_channel" ]]; then
    arguments+=(--channel "$release_channel")
fi

"$generate_appcast" "${arguments[@]}" "$work_directory"

echo "Updated $project_directory/appcast.xml"
echo "Verify the generated EdDSA signature before committing or publishing it."
