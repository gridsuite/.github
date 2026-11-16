#!/usr/bin/env bash
set -euo pipefail

# Bulk update of the rulesets for all non-archived gridsuite repos.
#
# For each non-archived repo in the organization:
#   - apply (create or update, matched by name) contributor-and-ci-protection,
#     contributor-only-protection and releasetag-protection,
#   - re-apply owners-protection on the repos listed in
#     OWNERS_PROTECTION_REPOS (explicit, curated list of critical repos),
#   - apply frontend-status-checks or backend-status-checks depending on the
#     repo type (unless explicitly excluded for repos that have no
#     build/analysis pipeline),
#   - only if --prune is passed, delete any pre-existing ruleset whose name
#     is not part of the reference set above (leftover/obsolete rulesets).
#     Without --prune, orphan rulesets are left untouched.
#
# The new rulesets are applied before any deletion happens, so that a repo
# is never left without any ruleset during the process.
#
# Relies on apply-ruleset.sh and delete-ruleset-by-id.sh, present in this
# same directory.

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

# ---------------------------------------------------------------------------
# Repos considered critical/core, where owners-protection (code-owner review
# required on main) must be applied
# ---------------------------------------------------------------------------
OWNERS_PROTECTION_REPOS=(
  network-modification
  network-modification-server
  gateway
  commons-ui
  documentation
)

usage() {
  echo "Usage: $0 <token> [--dry-run] [--prune]" >&2
  exit 1
}

if [[ $# -lt 1 || $# -gt 3 ]]; then
  usage
fi

TOKEN="$1"
shift

DRY_RUN=false
PRUNE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --prune) PRUNE=true ;;
    *) usage ;;
  esac
done

ORG="gridsuite"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="https://api.github.com"

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

is_fork() {
  local fork="$1"
  [[ "$fork" == "true" ]]
}

# Returns one "<name>\t<fork>" line per non-archived repo, where <fork> is
# the literal string "true" or "false" as reported by the GitHub API.
list_non_archived_repos() {
  local page=1
  local result=""
  while :; do
    local raw page_size chunk
    raw="$(gh_api_get "$API/orgs/$ORG/repos?per_page=100&page=$page")"
    page_size="$(jq 'length' <<< "$raw")"
    # Stop once the API returns an empty page (no more repos at all), not
    # just when the current page happens to contain only archived repos.
    [[ "$page_size" -eq 0 ]] && break
    chunk="$(jq -r '.[] | select(.archived == false) | "\(.name)\t\(.fork)"' <<< "$raw")"
    [[ -n "$chunk" ]] && result+="$chunk"$'\n'
    page=$((page + 1))
  done
  printf '%s' "$result"
}

# Returns the existing rulesets of a repo as "<id>\t<name>" lines.
list_existing_rulesets() {
  local repo="$1"
  gh_api_get "$API/repos/$ORG/$repo/rulesets" | jq -r '.[] | "\(.id)\t\(.name)"'
}

is_owners_protection_repo() {
  local repo="$1"
  local target
  for target in "${OWNERS_PROTECTION_REPOS[@]}"; do
    [[ "$target" == "$repo" ]] && return 0
  done
  return 1
}

# Deletes the rulesets listed in $existing whose name is not part of the
# reference names applied for this repo (orphan/obsolete rulesets). This is
# run after the reference rulesets have been applied, so the repo is never
# left without any ruleset in between.
run_delete_orphans() {
  local repo="$1"
  local existing="$2"
  shift 2
  local target_names=("$@")

  local id name is_target found_name
  while IFS=$'\t' read -r id name; do
    [[ -z "$id" ]] && continue
    is_target=false
    for found_name in "${target_names[@]}"; do
      if [[ "$found_name" == "$name" ]]; then
        is_target=true
        break
      fi
    done
    if ! $is_target; then
      if $DRY_RUN; then
        echo "  ⚠️  [DRY-RUN] WOULD DELETE orphan ruleset '$name' (id=$id) on $repo"
      else
        "$SCRIPT_DIR/delete-ruleset-by-id.sh" "$ORG/$repo" "$TOKEN" "$id" >/dev/null
        echo "  ⚠️  DELETED orphan ruleset '$name' (id=$id) on $repo"
      fi
    fi
  done <<< "$existing"
}

run_apply() {
  local repo="$1"
  local json="$2"
  if $DRY_RUN; then
    "$SCRIPT_DIR/apply-ruleset.sh" "$ORG/$repo" "$TOKEN" "$SCRIPT_DIR/$json" --dry-run
  else
    if ! "$SCRIPT_DIR/apply-ruleset.sh" "$ORG/$repo" "$TOKEN" "$SCRIPT_DIR/$json"; then
      echo "  !! failed to apply $json on $repo" >&2
      return 1
    fi
  fi
}

process_repo() {
  local repo="$1"
  local fork="$2"
  echo "=== $repo ==="

  if is_globally_excluded "$repo"; then
    echo "  skipping repo entirely (globally excluded, e.g. private repo without rulesets)"
    COUNT_GLOBALLY_EXCLUDED=$((COUNT_GLOBALLY_EXCLUDED + 1))
    return 0
  fi

  local existing
  existing="$(list_existing_rulesets "$repo")"

  local needs_owners=false
  if is_owners_protection_repo "$repo"; then
    needs_owners=true
  fi

  local target_names=(
    "contributor-and-ci-protection"
    "contributor-only-protection"
    "releasetag-protection"
  )

  # releasetag-protection-fork.json is identical to releasetag-protection.json
  # except that it explicitly sets update_allows_fetch_and_merge: false on the
  # "update" rule. GitHub only returns/accepts this parameter for forks, so
  # keeping it out of the non-fork file avoids a spurious diff (and therefore
  # a needless update) on every run of apply-ruleset.sh for non-fork repos.
  local releasetag_json="releasetag-protection.json"
  if is_fork "$fork"; then
    releasetag_json="releasetag-protection-fork.json"
  fi

  # If any apply fails, stop processing this repo right away and skip the
  # orphan cleanup, so a failed update never results in deleting rulesets
  # that could not be replaced.
  if ! run_apply "$repo" "contributor-and-ci-protection.json"; then
    return 1
  fi
  if ! run_apply "$repo" "contributor-only-protection.json"; then
    return 1
  fi
  if ! run_apply "$repo" "$releasetag_json"; then
    return 1
  fi

  if $needs_owners; then
    if ! run_apply "$repo" "owners-protection.json"; then
      return 1
    fi
    target_names+=("owners-protection")
    COUNT_OWNERS=$((COUNT_OWNERS + 1))
  fi

  if is_status_checks_excluded "$repo"; then
    echo "  skipping status-checks ruleset (excluded)"
    COUNT_EXCLUDED=$((COUNT_EXCLUDED + 1))
  elif is_frontend "$repo"; then
    if ! run_apply "$repo" "frontend-status-checks.json"; then
      return 1
    fi
    target_names+=("frontend-status-checks")
    COUNT_FRONTEND=$((COUNT_FRONTEND + 1))
  else
    if ! run_apply "$repo" "backend-status-checks.json"; then
      return 1
    fi
    target_names+=("backend-status-checks")
    COUNT_BACKEND=$((COUNT_BACKEND + 1))
  fi

  if $PRUNE; then
    run_delete_orphans "$repo" "$existing" "${target_names[@]}"
  else
    echo "  skipping orphan ruleset cleanup (use --prune to enable deletion)"
  fi
}

if $DRY_RUN; then
  echo "### DRY-RUN mode: no changes will be made ###"
  if $PRUNE; then
    echo "### PRUNE mode: orphan rulesets would be deleted ###"
  fi
else
  echo "### WARNING ###"
  echo "This will apply the reference rulesets (creating or updating them by"
  echo "name) on every non-archived repository of the '$ORG' organization."
  if $PRUNE; then
    echo "It will then also DELETE any pre-existing ruleset that is no longer"
    echo "part of the reference set (--prune is enabled)."
  else
    echo "Orphan rulesets will NOT be deleted (pass --prune to enable deletion)."
  fi
  echo "Run with --dry-run first if you want to preview the changes."
  read -r -p "Type 'yes' to continue: " CONFIRMATION
  if [[ "$CONFIRMATION" != "yes" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
fi

REPOS="$(list_non_archived_repos)"
TOTAL=0

while IFS=$'\t' read -r repo fork; do
  [[ -z "$repo" ]] && continue
  TOTAL=$((TOTAL + 1))
  if ! process_repo "$repo" "$fork"; then
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
echo "Owners-protection applied      : $COUNT_OWNERS"
echo "Orphan ruleset cleanup (prune) : $($PRUNE && echo enabled || echo disabled)"

if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  echo "Failed repos: ${FAILED_REPOS[*]}" >&2
  exit 1
fi
