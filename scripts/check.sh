#!/usr/bin/env bash
# Repository checks. CI runs each one; all of them also run locally.
#
#   scripts/check.sh files      forbidden files are absent; both marketplace
#                               files list the same entries, ref, sha, version
#   scripts/check.sh validate   claude plugin validate . --strict
#   scripts/check.sh remote     each pinned tag points at its sha, the plugin
#                               path exists at that sha, and its plugin.json
#                               conforms to Agent Plugins and matches the
#                               catalog (needs gh, git, check-jsonschema)
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require jq

check_files() {
  local f failed=0
  for f in "${FORBIDDEN_FILES[@]}"; do
    if [[ -e "$ROOT/$f" ]]; then
      echo "error: $f must not exist: it would be read instead of the generated marketplace files" >&2
      failed=1
    fi
  done
  ((failed == 0)) || exit 1

  local claude copilot
  claude="$(jq -S '[.plugins[] | {name, version, ref: .source.ref, sha: .source.sha, path: .source.path}] | sort_by(.name)' "$CLAUDE_FILE")"
  copilot="$(jq -S '[.plugins[] | {name, version, ref: .source.ref, sha: .source.sha, path: .source.path}] | sort_by(.name)' "$COPILOT_FILE")"
  if [[ "$claude" != "$copilot" ]]; then
    echo "error: the two marketplace files disagree" >&2
    diff <(echo "$claude") <(echo "$copilot") >&2 || true
    exit 1
  fi
  jq -e 'all(.plugins[]; .source.source == "git-subdir")' "$CLAUDE_FILE" >/dev/null \
    || die "$CLAUDE_FILE: every source must be git-subdir"
  jq -e 'all(.plugins[]; .source.source == "github")' "$COPILOT_FILE" >/dev/null \
    || die "$COPILOT_FILE: every source must be github"
  echo "files: ok ($(jq '.plugins | length' "$CLAUDE_FILE") entries)"
}

# claude plugin validate --strict fails on an empty marketplace ("Marketplace
# has no plugins defined"). Until the first entry is pinned, that one warning
# is allowed and anything else still fails.
check_validate() {
  require claude
  if jq -e '.plugins | length > 0' "$CLAUDE_FILE" >/dev/null; then
    claude plugin validate "$ROOT" --strict
    return
  fi
  local report status=0
  report="$(claude plugin validate "$ROOT" --json)" || status=$?
  ((status == 0)) || { echo "$report" >&2; die "claude plugin validate exited $status"; }
  # Match the warning by its path, not its wording, which may change.
  if ! jq -e '
      .success
      and (.manifest.errors | length == 0)
      and ([.manifest.warnings[].path] == ["plugins"])
      and ((.contents // []) | length == 0)
    ' <<<"$report" >/dev/null; then
    echo "$report" >&2
    die "claude plugin validate reported problems"
  fi
  echo "validate: ok (no plugins yet; --strict would fail only on that warning)"
}

check_remote() {
  require git
  require gh
  require check-jsonschema
  local f name repo path tag sha peeled commit spec_version
  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: $work is local
  trap "rm -rf '$work'" EXIT
  while IFS= read -r f; do
    check_catalog_file "$f"
    name="$(jq -r .name "$f")"
    repo="$(jq -r .repo "$f")"
    path="$(jq -r .path "$f")"
    tag="$(jq -r .tag "$f")"
    sha="$(jq -r .sha "$f")"
    if [[ "$sha" == "$UNRELEASED_SHA" ]]; then
      echo "$name: not released yet, skipped"
      continue
    fi
    # An annotated tag lists its commit as refs/tags/<tag>^{}; a lightweight one doesn't.
    local refs
    refs="$(git ls-remote "https://github.com/$repo.git" "refs/tags/$tag" "refs/tags/$tag^{}")"
    peeled="$(awk -v r="refs/tags/$tag^{}" '$2 == r { print $1 }' <<<"$refs")"
    commit="${peeled:-$(awk -v r="refs/tags/$tag" '$2 == r { print $1 }' <<<"$refs")}"
    [[ -n "$commit" ]] || die "$name: tag $tag not found in $repo"
    [[ "$commit" == "$sha" ]] || die "$name: tag $tag is $commit in $repo, but the catalog says $sha"
    gh api "repos/$repo/contents/$path?ref=$sha" --silent \
      || die "$name: $path does not exist in $repo at $sha"

    # Agent Plugins conformance: root plugin.json valid against its declared
    # schema, and the catalog lists what it says.
    fetch_manifest "$repo" "$sha" "$path" "$work/plugin.json"
    check_manifest "$work/plugin.json" "$name" "$(jq -r .version "$f")"
    check_claude_manifest "$repo" "$sha" "$path" "$name" "$(jq -r .version "$f")"
    spec_version="$(jq -r '."$schema"' "$work/plugin.json" | sed -E 's#.*/schemas/([^/]+)/.*#\1#')"
    [[ -f "$work/schema-$spec_version.json" ]] || gh api \
      "repos/$SPEC_REPO/contents/schemas/$spec_version/plugin.schema.json?ref=$SPEC_COMMIT" \
      -H "Accept: application/vnd.github.raw" >"$work/schema-$spec_version.json"
    check-jsonschema --schemafile "$work/schema-$spec_version.json" "$work/plugin.json" >/dev/null \
      || die "$name: plugin.json does not conform to Agent Plugins $spec_version"
    jq -e --slurpfile m "$work/plugin.json" \
      '.description == ($m[0].description // .description) and .keywords == ($m[0].keywords // .keywords)' \
      "$f" >/dev/null \
      || die "$name: catalog description or keywords differ from plugin.json; rerun scripts/pin.sh"
    echo "$name: $tag = $sha, $path exists, plugin.json conforms to Agent Plugins $spec_version"
  done < <(catalog_files)
}

case "${1:-}" in
  files) check_files ;;
  validate) check_validate ;;
  remote) check_remote ;;
  *) die "usage: scripts/check.sh files|validate|remote" ;;
esac
