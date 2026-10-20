#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "Usage: $0 <owner/repo> <token> <ruleset.json> [--dry-run]" >&2
  exit 1
fi

REPO="$1"
TOKEN="$2"
FILE="$3"
DRY_RUN=false
if [[ "${4:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif [[ -n "${4:-}" ]]; then
  echo "Usage: $0 <owner/repo> <token> <ruleset.json> [--dry-run]" >&2
  exit 1
fi

BASE_URL="https://api.github.com/repos/$REPO/rulesets"
NAME=$(jq -r '.name // empty' "$FILE")

if [[ -z "$NAME" ]]; then
  echo "Error: '.name' field missing in $FILE" >&2
  exit 1
fi

# Look up an existing ruleset by its name instead of its id, since the
# definition file does not necessarily contain the GitHub ruleset id.
# NB: pagination of the API is not handled (we assume < 30 rulesets on the repo).
EXISTING_RULESETS_JSON=$(curl --silent --show-error --fail-with-body \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$BASE_URL")

MATCHING_COUNT=$(jq -r --arg name "$NAME" '[.[] | select(.name == $name)] | length' <<< "$EXISTING_RULESETS_JSON")
if [[ "$MATCHING_COUNT" -gt 1 ]]; then
  echo "Warning: $REPO has $MATCHING_COUNT rulesets named '$NAME'; using the last one returned by the API, which may not be deterministic." >&2
fi

# If multiple rulesets share the same name (rare case), keep the last one
# found in the API response.
EXISTING_ID=$(jq -r --arg name "$NAME" '[.[] | select(.name == $name)] | last | .id // empty' <<< "$EXISTING_RULESETS_JSON")

if [[ -n "$EXISTING_ID" ]]; then
  METHOD="PUT"
  URL="$BASE_URL/$EXISTING_ID"
else
  METHOD="POST"
  URL="$BASE_URL"
fi

NEW_FILTERED=$(jq -S . "$FILE")
HAS_DIFF=true
EXISTING_FILTERED=""

if [[ -n "$EXISTING_ID" ]]; then
  # Fetch the full existing ruleset and only keep the keys that are present
  # in the local file, so that server-managed fields (id, created_at,
  # updated_at, node_id, _links, source, etc.) do not pollute the comparison.
  EXISTING_JSON=$(curl --silent --show-error --fail-with-body \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$URL")

  EXISTING_FILTERED=$(jq -S --argjson keys "$(jq -c 'keys' "$FILE")" \
    'with_entries(select(.key as $k | $keys | index($k)))' <<< "$EXISTING_JSON")

  # NB: `jq -S` only sorts object keys, not the order of array elements
  # (e.g. `rules`, `bypass_actors`, `required_status_checks`). If GitHub
  # returns these arrays in a different order than the local file, this
  # comparison may report a difference even though the ruleset is
  # functionally identical, triggering a harmless but unnecessary update.
  if [[ "$EXISTING_FILTERED" == "$NEW_FILTERED" ]]; then
    HAS_DIFF=false
  fi
fi

if $DRY_RUN; then
  if [[ -z "$EXISTING_ID" ]]; then
    echo "[DRY-RUN] $REPO: would CREATE ruleset '$NAME'"
  elif ! $HAS_DIFF; then
    echo "[DRY-RUN] $REPO: ruleset '$NAME' already up to date (id=$EXISTING_ID), nothing to do"
  else
    echo "[DRY-RUN] $REPO: ruleset '$NAME' already exists (id=$EXISTING_ID), would UPDATE it"
    echo "[DRY-RUN] $REPO: differences for '$NAME' (current -> new):"
    diff <(echo "$EXISTING_FILTERED") <(echo "$NEW_FILTERED") || true
  fi
  exit 0
fi

if [[ -n "$EXISTING_ID" ]] && ! $HAS_DIFF; then
  echo "$REPO: ruleset '$NAME' already up to date (id=$EXISTING_ID), skipping" >&2
  exit 0
fi

if [[ -z "$EXISTING_ID" ]]; then
  echo "$REPO: ruleset '$NAME' does not exist, creating it"
else
  echo "$REPO: ruleset '$NAME' differs (id=$EXISTING_ID), updating it"
  echo "$REPO: differences for '$NAME' (current -> new):"
  diff <(echo "$EXISTING_FILTERED") <(echo "$NEW_FILTERED") || true
fi

if ! RESPONSE=$(curl --silent --show-error --fail-with-body \
  -X "$METHOD" \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Content-Type: application/json" \
  --data-binary @"$FILE" \
  "$URL"); then
  STATUS=$?
  echo "$RESPONSE" >&2
  exit "$STATUS"
fi

if [[ -z "$EXISTING_ID" ]]; then
  NEW_ID=$(jq -r '.id // empty' <<< "$RESPONSE")
  echo "$REPO: ruleset '$NAME' created (id=$NEW_ID)"
else
  echo "$REPO: ruleset '$NAME' updated (id=$EXISTING_ID)"
fi
