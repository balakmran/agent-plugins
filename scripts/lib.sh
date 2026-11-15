# shellcheck shell=bash disable=SC2034  # the settings are used by the scripts that source this
# Shared settings and helpers. Source this file; don't run it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG_DIR="$ROOT/catalog"
CLAUDE_FILE="$ROOT/.claude-plugin/marketplace.json"
COPILOT_FILE="$ROOT/.github/plugin/marketplace.json"
README_FILE="$ROOT/README.md"

MARKETPLACE_NAME="balakmran"
MARKETPLACE_OWNER="balakmran"
MARKETPLACE_DESCRIPTION="Agent plugins by balakmran: portable skills and tools for coding agents, built to the Agent Plugins spec."

# Agent Plugins (https://agent-plugins.org) versions a listed plugin's root
# plugin.json may target, and the spec commit whose schemas CI validates it
# against. The schema URLs themselves aren't served, so they come from GitHub.
SPEC_VERSIONS=("1.0.0" "1.1.0")
SPEC_REPO="agentplugins/agent-plugins-spec"
SPEC_COMMIT="6395e8906b30e2f333b792bfaa981d790993d56f"

# A catalog entry with this sha has never been released. It stays out of the
# marketplace files until scripts/pin.sh gives it a real one.
UNRELEASED_SHA="0000000000000000000000000000000000000000"

# Files that would be read instead of the two generated ones.
FORBIDDEN_FILES=(
  ".agents/plugins/marketplace.json"
  ".agents/plugins/api_marketplace.json"
  "marketplace.json"
  ".plugin/marketplace.json"
)

SHA_RE='^[0-9a-f]{40}$'
TAG_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
die() {
  echo "error: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

# A plugin name as Agent Plugins defines it: 1-64 characters of a-z, 0-9, '-'
# and '.', starting and ending alphanumeric, with no '--' or '..'.
valid_name() {
  local n="$1"
  [[ ${#n} -ge 1 && ${#n} -le 64 ]] \
    && [[ "$n" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
    && [[ "$n" != *--* && "$n" != *..* ]]
}

# fetch_manifest <repo> <sha> <path> <out>: the plugin's root plugin.json at sha.
fetch_manifest() {
  local repo="$1" sha="$2" path="$3" out="$4" file
  file="${path%/}/plugin.json"
  [[ "$path" == "." ]] && file="plugin.json"
  gh api "repos/$repo/contents/$file?ref=$sha" -H "Accept: application/vnd.github.raw" >"$out" \
    || die "$repo has no $file at $sha (an Agent Plugins plugin needs a root plugin.json)"
}

# check_manifest <manifest> <name> <version>: the fields this marketplace
# relies on. Full schema validation is in scripts/check.sh remote.
check_manifest() {
  local manifest="$1" name="$2" version="$3" schema v ok=0
  jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || die "$manifest: plugin.json is not a JSON object"
  schema="$(jq -r '."$schema" // ""' "$manifest")"
  for v in "${SPEC_VERSIONS[@]}"; do
    [[ "$schema" == "https://agent-plugins.org/schemas/$v/plugin.schema.json" ]] && ok=1
  done
  ((ok)) || die "plugin.json \$schema '$schema' is not an Agent Plugins version this marketplace accepts (${SPEC_VERSIONS[*]})"
  [[ "$(jq -r '.name // ""' "$manifest")" == "$name" ]] \
    || die "plugin.json name '$(jq -r '.name // ""' "$manifest")' must equal the entry name '$name'"
  [[ "$(jq -r '.version // ""' "$manifest")" == "$version" ]] \
    || die "plugin.json version '$(jq -r '.version // ""' "$manifest")' must equal the tag's version '$version'"
}

# check_claude_manifest <repo> <sha> <path> <name> <version>: Claude Code
# doesn't read the root plugin.json; it reads <path>/.claude-plugin/plugin.json,
# and that file's version wins over the marketplace entry's. If the file
# exists, its name must be the entry name and its version absent or equal.
check_claude_manifest() {
  local repo="$1" sha="$2" path="$3" name="$4" version="$5" file out err
  file="${path%/}/.claude-plugin/plugin.json"
  [[ "$path" == "." ]] && file=".claude-plugin/plugin.json"
  out="$(mktemp)" err="$(mktemp)"
  if ! gh api "repos/$repo/contents/$file?ref=$sha" -H "Accept: application/vnd.github.raw" >"$out" 2>"$err"; then
    if grep -q "HTTP 404" "$err"; then
      rm -f "$out" "$err"
      return 0
    fi
    cat "$err" >&2
    rm -f "$out" "$err"
    die "could not read $file from $repo at $sha"
  fi
  local got_name got_version
  got_name="$(jq -r '.name // ""' "$out")"
  got_version="$(jq -r '.version // ""' "$out")"
  rm -f "$out" "$err"
  [[ "$got_name" == "$name" ]] \
    || die "$file name '$got_name' must equal the entry name '$name'"
  [[ -z "$got_version" || "$got_version" == "$version" ]] \
    || die "$file version '$got_version' must be absent or equal '$version': Claude Code uses it over the marketplace entry's"
}

# Prints the catalog files, sorted, one per line.
catalog_files() {
  find "$CATALOG_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | LC_ALL=C sort
}

# Fails unless the catalog file is well formed.
check_catalog_file() {
  local file="$1" entry
  entry="$(basename "$file" .json)"
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || die "$file: not a JSON object"

  local key
  for key in name description category repo path tag sha version; do
    jq -e --arg k "$key" '.[$k] | type == "string" and length > 0' "$file" >/dev/null \
      || die "$file: '$key' must be a non-empty string"
  done
  jq -e '.keywords | type == "array" and all(type == "string")' "$file" >/dev/null \
    || die "$file: 'keywords' must be an array of strings"

  local extra
  extra="$(jq -r 'keys - ["name","description","category","keywords","repo","path","tag","sha","version"] | join(", ")' "$file")"
  [[ -z "$extra" ]] || die "$file: unknown keys: $extra"

  local name repo path tag sha version
  name="$(jq -r .name "$file")"
  repo="$(jq -r .repo "$file")"
  path="$(jq -r .path "$file")"
  tag="$(jq -r .tag "$file")"
  sha="$(jq -r .sha "$file")"
  version="$(jq -r .version "$file")"

  [[ "$name" == "$entry" ]] || die "$file: name '$name' must equal the file name '$entry'"
  valid_name "$name" || die "$file: name '$name' is not a valid Agent Plugins name"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "$file: repo '$repo' must be owner/name"
  [[ "$path" != /* && "$path" != ./* && "$path" != *..* ]] \
    || die "$file: path '$path' must be relative, without ./ or .."
  [[ "$sha" =~ $SHA_RE ]] || die "$file: sha must be 40 lowercase hex characters"
  [[ "$tag" =~ $TAG_RE ]] || die "$file: tag '$tag' must look like v<semver>"
  [[ "$version" == "${tag#v}" ]] || die "$file: version '$version' must be the tag without 'v'"
}
