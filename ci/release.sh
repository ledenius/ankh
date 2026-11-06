#!/usr/bin/env bash
# ci/release.sh <tag>: publishes a release's files on every public mirror.
# Push mirrors carry the tag; releases aren't part of git, so this creates
# each host's release and uploads ankh, ankh-verify and SHA256SUMS to it,
# then checks the result with ankh-verify against all of them.
# Tokens come from the environment: CODEBERG_TOKEN, GH_TOKEN. Each host is
# skipped (with a warning) when its token is unset. Safe to run again: an
# existing release is reused and files already there are left alone.
set -euo pipefail

tag="${1:?usage: ci/release.sh <tag>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEBERG_REPO="${CODEBERG_REPO:-lede/ankh}"
GH_REPO="${GH_REPO:-ledenius/ankh}"
WAIT_SECONDS="${WAIT_SECONDS:-1200}"

say() { printf 'release: %s\n' "$*" >&2; }
die() {
  say "$*"
  exit 1
}

# --- the files ---------------------------------------------------------------

ver="$(sed -n 's/^ANKH_VERSION="\([0-9A-Za-z.+-]*\)"$/\1/p' "$here/ankh" | head -n 1)"
[[ "v$ver" == "$tag" ]] || die "the tag is $tag but ankh says ANKH_VERSION=\"$ver\""
dist="$here/dist"
rm -rf "$dist"
mkdir "$dist"
cp "$here/ankh" "$here/ankh-verify" "$dist/"
(cd "$dist" && sha256sum ankh ankh-verify >SHA256SUMS)
cat "$dist/SHA256SUMS" >&2
files=(ankh ankh-verify SHA256SUMS)

notes="Check a copy before running it: read \`ankh-verify\`, then run \`./ankh-verify\` next to \`ankh\`. It compares \`ankh\` against \`SHA256SUMS\` on every mirror. Releases are not signed yet. Canonical home: https://codeberg.org/lede/ankh"
release_json() {
  # No jq in the runner image: the notes hold no quotes or backslashes.
  printf '{"tag_name":"%s","name":"ankh %s","body":"%s","draft":false,"prerelease":false}' "$tag" "$ver" "$notes"
}

# api <token> <method> <url> [curl args...]: the token goes through a curl
# config on stdin, never on the command line. Prints the body; fails on >=400.
api() {
  local token="$1" method="$2" url="$3"
  shift 3
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -K - -fsS -X "$method" "$@" "$url"
}

wait_for_tag() {
  # wait_for_tag <name> <url that answers once the mirror has the tag>
  local name="$1" url="$2" waited=0
  until curl -fsS -o /dev/null "$url"; do
    ((waited < WAIT_SECONDS)) || die "$name never got $tag (waited ${WAIT_SECONDS}s): is its push mirror working?"
    sleep 15
    waited=$((waited + 15))
  done
  say "$name has $tag"
}

# --- Codeberg (Forgejo API) ----------------------------------------------------

codeberg() {
  local api_base="https://codeberg.org/api/v1/repos/$CODEBERG_REPO" t="$CODEBERG_TOKEN" id body f
  wait_for_tag Codeberg "$api_base/tags/$tag"
  if body="$(api "$t" GET "$api_base/releases/tags/$tag" 2>/dev/null)"; then
    say "Codeberg: the release exists"
  else
    body="$(release_json | api "$t" POST "$api_base/releases" -H 'Content-Type: application/json' --data @-)"
    say "Codeberg: release created"
  fi
  id="$(grep -o '"id":[0-9]*' <<<"$body" | head -n 1 | cut -d: -f2)"
  [[ -n "$id" ]] || die "Codeberg: no release id"
  for f in "${files[@]}"; do
    if grep -q "\"name\":\"$f\"" <<<"$body"; then
      say "Codeberg: $f is there already"
      continue
    fi
    api "$t" POST "$api_base/releases/$id/assets?name=$f" -F "attachment=@$dist/$f" >/dev/null
    say "Codeberg: uploaded $f"
  done
}

# --- GitHub ------------------------------------------------------------------

github() {
  local api_base="https://api.github.com/repos/$GH_REPO" t="$GH_TOKEN" id body f
  local -a h=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  wait_for_tag GitHub "https://github.com/$GH_REPO/tree/$tag"
  if body="$(api "$t" GET "$api_base/releases/tags/$tag" "${h[@]}" 2>/dev/null)"; then
    say "GitHub: the release exists"
  else
    body="$(release_json | api "$t" POST "$api_base/releases" "${h[@]}" -H 'Content-Type: application/json' --data @-)"
    say "GitHub: release created"
  fi
  id="$(grep -o '"id": *[0-9]*' <<<"$body" | head -n 1 | grep -o '[0-9]*$')"
  [[ -n "$id" ]] || die "GitHub: no release id"
  for f in "${files[@]}"; do
    if grep -q "\"name\": *\"$f\"" <<<"$body"; then
      say "GitHub: $f is there already"
      continue
    fi
    api "$t" POST "https://uploads.github.com/repos/$GH_REPO/releases/$id/assets?name=$f" "${h[@]}" \
      -H 'Content-Type: application/octet-stream' --data-binary "@$dist/$f" >/dev/null
    say "GitHub: uploaded $f"
  done
}

done_hosts=0
if [[ -n "${CODEBERG_TOKEN:-}" ]]; then codeberg && done_hosts=$((done_hosts + 1)); else say "warning: no CODEBERG_TOKEN: Codeberg skipped"; fi
if [[ -n "${GH_TOKEN:-}" ]]; then github && done_hosts=$((done_hosts + 1)); else say "warning: no GH_TOKEN: GitHub skipped"; fi
[[ $done_hosts -gt 0 ]] || die "no host published"

# --- check it as a user would ---------------------------------------------------
# Every host published above must confirm the file, through its own
# SHA256SUMS, downloaded the way ankh-verify does.
cps=()
if [[ -n "${CODEBERG_TOKEN:-}" ]]; then cps+=(--checkpoint "https://codeberg.org/$CODEBERG_REPO/releases/download/$tag/SHA256SUMS"); fi
if [[ -n "${GH_TOKEN:-}" ]]; then cps+=(--checkpoint "https://github.com/$GH_REPO/releases/download/$tag/SHA256SUMS"); fi
out="$(bash "$here/ankh-verify" "$dist/ankh" --no-default-checkpoints "${cps[@]}" 2>&1)" || {
  printf '%s\n' "$out" >&2
  die "ankh-verify failed against the published release"
}
printf '%s\n' "$out" >&2
n="$(grep -c '^ankh-verify: ok: ' <<<"$out" || true)"
[[ "$n" -eq "$done_hosts" ]] || die "$n of $done_hosts host(s) confirm the release"
say "published $tag on $done_hosts host(s), and each confirms it"
