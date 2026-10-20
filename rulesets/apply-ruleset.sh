#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <owner/repo> <token> <ruleset.json>" >&2
  exit 1
fi

REPO="$1"
TOKEN="$2"
FILE="$3"

BASE_URL="https://api.github.com/repos/$REPO/rulesets"
ID=$(jq -r '.id // empty' "$FILE")

if [[ -n "$ID" ]]; then
  METHOD="PUT"
  URL="$BASE_URL/$ID"
else
  METHOD="POST"
  URL="$BASE_URL"
fi

curl --silent --show-error --fail-with-body \
  -X "$METHOD" \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Content-Type: application/json" \
  --data-binary @"$FILE" \
  "$URL"
