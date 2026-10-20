#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <owner/repo> <token> <ruleset_name>" >&2
  exit 1
fi

REPO="$1"
TOKEN="$2"
RULESET_NAME="$3"

API="https://api.github.com/repos/${REPO}/rulesets"

# Récupère les IDs dont le nom correspond exactement
MATCHING_IDS="$(
  curl --silent --show-error --fail-with-body \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API" \
  | jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .id'
)"

if [ -z "$MATCHING_IDS" ]; then
  echo "Aucun ruleset trouvé avec le nom: $RULESET_NAME" >&2
  exit 1
fi

COUNT="$(printf "%s\n" "$MATCHING_IDS" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$COUNT" -gt 1 ]; then
  echo "Plusieurs rulesets portent ce nom ($RULESET_NAME). IDs:" >&2
  printf "%s\n" "$MATCHING_IDS" >&2
  echo "Suppression annulée (ambigu)." >&2
  exit 1
fi

RULESET_ID="$MATCHING_IDS"

echo "Suppression du ruleset '$RULESET_NAME' (id=$RULESET_ID) sur $REPO..."
curl --silent --show-error --fail-with-body \
  -X DELETE \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -w "\nHTTP %{http_code}\n" \
  "${API}/${RULESET_ID}"
