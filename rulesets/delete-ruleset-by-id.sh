#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <owner/repo> <token> <ruleset_id>" >&2
  exit 1
fi

REPO="$1"
TOKEN="$2"
RULESET_ID="$3"

curl --silent --show-error --fail-with-body \
  -X DELETE \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -w "\nHTTP %{http_code}\n" \
  "https://api.github.com/repos/${REPO}/rulesets/${RULESET_ID}"
