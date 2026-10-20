#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <owner/repo> <token>" >&2
  exit 1
fi

REPO="$1"
TOKEN="$2"

API="https://api.github.com/repos/${REPO}/rulesets"

IDS="$(
  curl --silent --show-error --fail-with-body \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API" \
  | jq -r '.[].id'
)"

if [ -z "$IDS" ]; then
  echo "Aucun ruleset trouvé sur $REPO." >&2
  exit 0
fi

echo "$IDS" | while IFS= read -r RULESET_ID; do
  [ -z "$RULESET_ID" ] && continue
  echo "Suppression du ruleset id=$RULESET_ID sur $REPO..."
  curl --silent --show-error --fail-with-body \
    -X DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -w "\nHTTP %{http_code}\n" \
    "${API}/${RULESET_ID}"
done
