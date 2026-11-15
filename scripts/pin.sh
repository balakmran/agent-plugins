#!/usr/bin/env bash
# Pins a plugin to a released tag, then regenerates the marketplace files.
#
#   scripts/pin.sh <entry> <tag> <sha>
#   scripts/pin.sh sterling v0.2.0 0123456789abcdef0123456789abcdef01234567
#
# Updates tag, sha and version in catalog/<entry>.json, and copies description
# and keywords from the plugin's root plugin.json (Agent Plugins manifest) at
# that sha, so the marketplace lists what the release ships. The catalog file
# must already exist. Needs jq, and gh with a token that can read the repo.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require jq
require gh

(($# == 3)) || die "usage: scripts/pin.sh <entry> <tag> <sha>"
entry="$1" tag="$2" sha="$3"

valid_name "$entry" || die "entry '$entry' is not a valid Agent Plugins name"
[[ "$tag" =~ $TAG_RE ]] || die "tag '$tag' must look like v<semver>, for example v1.2.3"
[[ "$sha" =~ $SHA_RE ]] || die "sha '$sha' must be a full commit SHA: 40 lowercase hex characters"
[[ "$sha" != "$UNRELEASED_SHA" ]] || die "sha must not be all zeros"

file="$CATALOG_DIR/$entry.json"
[[ -f "$file" ]] || die "$file does not exist; add the catalog entry first (see README.md)"

tmp="$(mktemp)" manifest="$(mktemp)"
trap 'rm -f "$tmp" "$manifest"' EXIT
fetch_manifest "$(jq -r .repo "$file")" "$sha" "$(jq -r .path "$file")" "$manifest"
check_manifest "$manifest" "$entry" "${tag#v}"
check_claude_manifest "$(jq -r .repo "$file")" "$sha" "$(jq -r .path "$file")" "$entry" "${tag#v}"

jq --arg tag "$tag" --arg sha "$sha" --arg version "${tag#v}" --slurpfile m "$manifest" '
  .tag = $tag | .sha = $sha | .version = $version
  | .description = ($m[0].description // .description)
  | .keywords = ($m[0].keywords // .keywords)' "$file" >"$tmp"
cat "$tmp" >"$file"

"$ROOT/scripts/generate.sh"
echo "Pinned $entry to $tag ($sha)."
