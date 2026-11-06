## Rulesets

All repositories are configured to use the same rulesets. The reference rulesets are defined in this repository.

The main entry point for maintaining this consistency is **`bulk-update-rulesets.sh`** (see "Applying rulesets everywhere" below): it re-applies the correct set of reference rulesets to every non-archived repository in one go, and should be the preferred way to roll out any change to the rulesets. The other, single-repository scripts are lower-level building blocks, mostly useful for debugging or one-off interventions on a single repository.


### Current rulesets overview

Six reference rulesets are defined, as JSON files in this directory, ready to be applied to any repository via the GitHub API (see "Applying rulesets everywhere" below).

#### Branch rulesets


- **`contributor-and-ci-protection.json`** (targets the default branch and `release-v*` branches): the base layer, applied systematically on **every** repository. It is the sole owner of the `deletion` and `non_fast_forward` rules, restricting **everyone** — contributors and the `gridsuite-actions` integration alike — with only organization admins keeping a bypass. This guarantees that neither a regular contributor nor the integration can ever delete a protected branch or force-push to it.

- **`contributor-only-protection.json`** (same target as `contributor-and-ci-protection`): also applied systematically on **every** repository, alongside `contributor-and-ci-protection`. It adds further constraints targeting regular contributors specifically — organization admins and the `gridsuite-actions` integration keep an "always" bypass on this ruleset. It requires:
  - a linear history (no merge commits),
  - a pull request with at least 1 approval, merged via **squash only**, with an extra approval required for unattributed changes.

  It does **not** require any status check, since not every repository has a build/analysis pipeline. It also does **not** cover branch deletion or non-fast-forward pushes — these are always enforced by `contributor-and-ci-protection` above, which must therefore always be applied alongside it.

  It is also the sole owner of the `creation` rule: since `main` already exists in every repository, this effectively only restricts the creation of new `release-v*` branches, which only organization admins and the `gridsuite-actions` integration can create — regular contributors cannot create one directly.

- **`backend-status-checks.json`** / **`frontend-status-checks.json`** (same target as `contributor-only-protection`): add-on rulesets, applied **in addition to** `contributor-only-protection`, on repositories that are respectively backend or frontend applications. Each one only adds the `required_status_checks` rule, requiring the `SonarCloud Code Analysis` and `build / build` status checks to pass, with branches kept up to date with their base before merging.

  The **frontend** variant additionally requires the `build / Check licenses headers` status check, to account for the extra license-header verification run on frontend repositories.

- **`owners-protection.json`** (targets `main` only): an add-on ruleset applied in addition to `contributor-only-protection`, on repositories that have a `CODEOWNERS` file. It enforces code owner review on pull requests targeting `main`, on top of the rules already required by `contributor-only-protection`.

#### Tag rulesets

- **`releasetag-protection.json`** (targets `v[0-9]*` tags): prevents release tags from being created, updated, or deleted once pushed, making releases immutable.

All these rulesets allow **organization admins** to always bypass them, and all of them except **`contributor-and-ci-protection.json`** also allow the **`gridsuite-actions`** integration to always bypass them.

### Applying rulesets everywhere (recommended)

Running this script requires a GitHub personal access token with `administration` permission on **every** non-archived repository of the organization (not just one), since it iterates over all of them.

The **`bulk-update-rulesets.sh <token> [--dry-run]`** script applies the reference rulesets to **every non-archived repository** of the `gridsuite` organization in one go. It relies on the low-level scripts described below, and for each repository it:
  - detects whether the repository already has an `owners-protection` ruleset, before touching anything,
  - deletes all existing rulesets on the repository,
  - applies `contributor-and-ci-protection.json`, `contributor-only-protection.json` and `releasetag-protection.json`,
  - re-applies `owners-protection.json` if it was detected in the first step,
  - applies `frontend-status-checks.json` or `backend-status-checks.json` depending on the repository name (`commons-ui`, `gridapp-template` and any `grid*-app` repository are considered frontend, everything else is considered backend), unless the repository is listed in the `BACKEND_OR_FRONTEND_EXCLUDE_REPOS` array declared at the top of the script — repositories without any build/analysis pipeline get no status-checks ruleset at all.

A summary (repositories processed, frontend/backend/excluded counts, owners-protection recreated, failed repositories) is printed at the end.

```bash
./bulk-update-rulesets.sh "$TOKEN" --dry-run   # simulate, no changes made
./bulk-update-rulesets.sh "$TOKEN"             # actually apply the changes, after a confirmation prompt
```

This is the script to use whenever the reference rulesets change, or to re-sync a repository that has drifted from the reference configuration. Running it with `--dry-run` first is strongly recommended to preview the changes before applying them for real.

### Low-level scripts (single-repository operations)

Four helper scripts are provided to manage rulesets on a given repository through the GitHub REST API. All of them take a GitHub personal access token with the appropriate `administration` permission on the target repository. `bulk-update-rulesets.sh` above uses `apply-ruleset.sh` and `delete-all-rulesets.sh` internally; use these scripts directly only for debugging or for one-off changes on a single repository.

- **`apply-ruleset.sh <owner/repo> <token> <ruleset.json>`**: creates the ruleset on the target repository, or updates it if the JSON file already contains an `id` field (as returned by a previous creation or by the GitHub API).

  ```bash
  ./apply-ruleset.sh gridsuite/my-repo "$TOKEN" contributor-and-ci-protection.json
  ```


- **`delete-ruleset.sh <owner/repo> <token> <ruleset_name>`**: looks up the ruleset by name on the target repository and deletes it. Fails if no ruleset or more than one ruleset matches the given name.

  ```bash
  ./delete-ruleset.sh gridsuite/my-repo "$TOKEN" contributor-only-protection
  ```

- **`delete-ruleset-by-id.sh <owner/repo> <token> <ruleset_id>`**: deletes a ruleset directly by its numeric ID, useful when the name lookup is ambiguous or unavailable.

  ```bash
  ./delete-ruleset-by-id.sh gridsuite/my-repo "$TOKEN" 123456
  ```

- **`delete-all-rulesets.sh <owner/repo> <token>`**: deletes **all** rulesets currently configured on the target repository, regardless of their name or origin. Use with caution.

  ```bash
  ./delete-all-rulesets.sh gridsuite/my-repo "$TOKEN"
  ```

### Protecting critical secrets

Critical secrets are not stored as repository-level secrets, which would be accessible from any workflow run, regardless of the branch or pull request that triggered it.

Instead, they are stored in a dedicated GitHub **environment**, configured with a custom deployment branch policy restricting its use to the branches covered by the reference rulesets: the default branch (`main`) and `release-v*` branches.

As a result, a workflow job can only access these secrets if:
- it explicitly targets that environment, and
- it runs from `main` or a `release-v*` branch.

Since these branches are protected by the reference rulesets (pull request with mandatory review, required status checks, no force-push), any workflow change made by an actor without bypass rights must go through a reviewed pull request before it can run with access to that secret. This prevents an unreviewed or malicious workflow change from exfiltrating the secret, except when pushed directly by an actor with an "always" ruleset bypass (organization admins and the `gridsuite-actions` integration — see above).

Organization admins can still bypass the environment protection, consistent with their ability to bypass the branch rulesets.
