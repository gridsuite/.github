#!/usr/bin/env bash
set -euo pipefail

# Bulk update of the rulesets for all non-archived gridsuite repos.
#
# For each non-archived repo in the organization:
#   - delete all existing rulesets,
#   - apply contributor-and-ci-protection, contributor-only-protection and
#     releasetag-protection,
#   - re-apply owners-protection if the repo had one before deletion,
#   - apply frontend-status-checks or backend-status-checks depending on the
#     repo type (unless explicitly excluded for repos that have no
#     build/analysis pipeline).
#
# Relies on apply-ruleset.sh and delete-all-rulesets.sh, present in this
# same directory.

usage() {
  echo "Usage: $0 <token> [--dry-run]" >&2
  exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

TOKEN="$1"
DRY_RUN=false
if [[ "${2:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif [[ -n "${2:-}" ]]; then
  usage
fi

ORG="gridsuite"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="https://api.github.com"

# ---------------------------------------------------------------------------
# Repos entirely excluded from this script, e.g. because they are private
# repos that cannot have rulesets. No API call is made on these repos at all.
# ---------------------------------------------------------------------------
GLOBALLY_EXCLUDED_REPOS=(
  azure-gitops
)

# ---------------------------------------------------------------------------
# Repos excluded from any status-checks ruleset (frontend or backend), e.g.
# because they have no SonarCloud/build pipeline. This exclusion takes
# priority over the frontend/backend detection.
# ---------------------------------------------------------------------------
BACKEND_OR_FRONTEND_EXCLUDE_REPOS=(
  documentation
  .github
  aggregator
  dependencies
  gridsuite-integration-test
  ci-cd-test
  gridsuite.github.io
  httpd-docker
  test-cases
  broadcast-event
)

FAILED_REPOS=()
COUNT_FRONTEND=0
COUNT_BACKEND=0
COUNT_EXCLUDED=0
COUNT_OWNERS=0
COUNT_GLOBALLY_EXCLUDED=0

gh_api_get() {
  curl --silent --show-error --fail-with-body \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

is_globally_excluded() {
  local repo="$1"
  local excluded
  for excluded in "${GLOBALLY_EXCLUDED_REPOS[@]}"; do
    [[ "$excluded" == "$repo" ]] && return 0
  done
  return 1
}

is_status_checks_excluded() {
  local repo="$1"
  local excluded
  for excluded in "${BACKEND_OR_FRONTEND_EXCLUDE_REPOS[@]}"; do
    [[ "$excluded" == "$repo" ]] && return 0
  done
  return 1
}

is_frontend() {
  local repo="$1"
  [[ "$repo" == "commons-ui" || "$repo" == "gridapp-template" || "$repo" =~ ^grid.*-app$ ]]
}

list_non_archived_repos() {
  local page=1
  local result=""
  while :; do
    local chunk
    chunk="$(gh_api_get "$API/orgs/$ORG/repos?per_page=100&page=$page" \
      | jq -r '.[] | select(.archived == false) | .name')"
    [[ -z "$chunk" ]] && break
    result+="$chunk"$'\n'
    page=$((page + 1))
  done
  printf '%s' "$result"
}

has_owners_protection_ruleset() {
  local repo="$1"
  gh_api_get "$API/repos/$ORG/$repo/rulesets" \
    | jq -r '.[].name' \
    | grep -qx "owners-protection"
}

run_delete_all() {
  local repo="$1"
  if $DRY_RUN; then
    local names
    names="$(gh_api_get "$API/repos/$ORG/$repo/rulesets" | jq -r '.[].name' | paste -sd ',' -)"
    echo "  [DRY-RUN] would delete all rulesets on $repo (${names:-none})"
  else
    "$SCRIPT_DIR/delete-all-rulesets.sh" "$ORG/$repo" "$TOKEN" >/dev/null
    echo "  deleted all existing rulesets on $repo"
  fi
}

run_apply() {
  local repo="$1"
  local json="$2"
  if $DRY_RUN; then
    echo "  [DRY-RUN] would apply $json on $repo"
  else
    "$SCRIPT_DIR/apply-ruleset.sh" "$ORG/$repo" "$TOKEN" "$SCRIPT_DIR/$json" >/dev/null
    echo "  applied $json on $repo"
  fi
}

process_repo() {
  local repo="$1"
  echo "=== $repo ==="

  if is_globally_excluded "$repo"; then
    echo "  skipping repo entirely (globally excluded, e.g. private repo without rulesets)"
    COUNT_GLOBALLY_EXCLUDED=$((COUNT_GLOBALLY_EXCLUDED + 1))
    return 0
  fi

  local had_owners=false
  if has_owners_protection_ruleset "$repo"; then
    had_owners=true
  fi

  run_delete_all "$repo"

  run_apply "$repo" "contributor-and-ci-protection.json"
  run_apply "$repo" "contributor-only-protection.json"
  run_apply "$repo" "releasetag-protection.json"

  if $had_owners; then
    run_apply "$repo" "owners-protection.json"
    COUNT_OWNERS=$((COUNT_OWNERS + 1))
  fi

  if is_status_checks_excluded "$repo"; then
    echo "  skipping status-checks ruleset (excluded)"
    COUNT_EXCLUDED=$((COUNT_EXCLUDED + 1))
  elif is_frontend "$repo"; then
    run_apply "$repo" "frontend-status-checks.json"
    COUNT_FRONTEND=$((COUNT_FRONTEND + 1))
  else
    run_apply "$repo" "backend-status-checks.json"
    COUNT_BACKEND=$((COUNT_BACKEND + 1))
  fi
}

if $DRY_RUN; then
  echo "### DRY-RUN mode: no changes will be made ###"
else
  echo "### WARNING ###"
  echo "This will DELETE all existing rulesets and re-apply the reference"
  echo "rulesets on every non-archived repository of the '$ORG' organization."
  echo "Run with --dry-run first if you want to preview the changes."
  read -r -p "Type 'yes' to continue: " CONFIRMATION
  if [[ "$CONFIRMATION" != "yes" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
fi

REPOS="$(list_non_archived_repos)"
TOTAL=0

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  TOTAL=$((TOTAL + 1))
  if ! process_repo "$repo"; then
    echo "  !! FAILED on $repo" >&2
    FAILED_REPOS+=("$repo")
  fi
done <<< "$REPOS"

echo
echo "### Summary ###"
echo "Repos processed : $TOTAL"
echo "Globally excluded (skipped entirely) : $COUNT_GLOBALLY_EXCLUDED"
echo "Frontend status-checks applied : $COUNT_FRONTEND"
echo "Backend status-checks applied  : $COUNT_BACKEND"
echo "Excluded from status-checks    : $COUNT_EXCLUDED"
echo "Owners-protection recreated    : $COUNT_OWNERS"

if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  echo "Failed repos: ${FAILED_REPOS[*]}" >&2
  exit 1
fi
