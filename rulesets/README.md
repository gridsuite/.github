## Rulesets

All repositories are configured to use the same rulesets. The reference rulesets are defined in this repository.


### Current rulesets overview

Five reference rulesets are defined, as JSON files in this directory, ready to be applied to any repository via the GitHub API (see "Applying / removing rulesets" below).

#### Branch rulesets

- **`base-protection-back.json`** / **`base-protection-front.json`** (target the default branch and `release-v*` branches): the standard protection for backend and frontend repositories. Both prevent branch deletion and non-fast-forward pushes, and require:
  - a linear history (no merge commits),
  - a pull request with at least 1 approval, merged via **squash only**, with an extra approval required for unattributed changes,
  - the `SonarCloud Code Analysis` and `build / build` status checks to pass, with branches kept up to date with their base before merging.

  The **front** variant additionally requires the `build / Check licenses headers` status check, to account for the extra license-header verification run on frontend repositories.

- **`app-protection.json`** (targets the default branch and `release-v*` branches, same as `base-protection-*`): an add-on ruleset, applied **in addition to** `base-protection-back`/`base-protection-front`, that re-enforces branch deletion and non-fast-forward protection without allowing the `gridsuite-actions` integration to bypass it. It duplicates the `deletion` and `non_fast_forward` rules already present in `base-protection-*`, but with a narrower bypass list (organization admins only). Since GitHub applies the most restrictive outcome when several rulesets cover the same rule on the same branch, this guarantees that the integration can never delete a protected branch or force-push to it, even though `base-protection-*` alone would allow it to do so.

- **`owners-protection.json`** (targets `main` only): an add-on ruleset applied in addition to `base-protection`, on repositories that have a `CODEOWNERS` file. It enforces code owner review on pull requests targeting `main`, on top of the rules already required by `base-protection`.

#### Tag rulesets

- **`releasetag-protection.json`** (targets `v[0-9]*` tags): prevents release tags from being created, updated, or deleted once pushed, making releases immutable.

All these rulesets allow **organization admins** to always bypass them, and all of them except **`app-protection.json`** also allow the **`gridsuite-actions`** integration to always bypass them.

### Applying / removing rulesets

Three helper scripts are provided to manage rulesets on a given repository through the GitHub REST API. All of them take a GitHub personal access token with the appropriate `administration` permission on the target repository.

- **`apply-ruleset.sh <owner/repo> <token> <ruleset.json>`**: creates the ruleset on the target repository, or updates it if the JSON file already contains an `id` field (as returned by a previous creation or by the GitHub API).

  ```bash
  ./apply-ruleset.sh gridsuite/my-repo "$TOKEN" base-protection-back.json
  ```

- **`delete-ruleset.sh <owner/repo> <token> <ruleset_name>`**: looks up the ruleset by name on the target repository and deletes it. Fails if no ruleset or more than one ruleset matches the given name.

  ```bash
  ./delete-ruleset.sh gridsuite/my-repo "$TOKEN" base-protection
  ```

- **`delete-ruleset-by-id.sh <owner/repo> <token> <ruleset_id>`**: deletes a ruleset directly by its numeric ID, useful when the name lookup is ambiguous or unavailable.

  ```bash
  ./delete-ruleset-by-id.sh gridsuite/my-repo "$TOKEN" 123456
  ```

### Protecting critical secrets

Critical secrets are not stored as repository-level secrets, which would be accessible from any workflow run, regardless of the branch or pull request that triggered it.

Instead, they are stored in a dedicated GitHub **environment**, configured with a custom deployment branch policy restricting its use to the branches covered by the reference rulesets: the default branch (`main`) and `release-v*` branches.

As a result, a workflow job can only access these secrets if:
- it explicitly targets that environment, and
- it runs from `main` or a `release-v*` branch.

Since these branches are protected by the reference rulesets (pull request with mandatory review, required status checks, no force-push), any workflow change made by an actor without bypass rights must go through a reviewed pull request before it can run with access to that secret. This prevents an unreviewed or malicious workflow change from exfiltrating the secret, except when pushed directly by an actor with an "always" ruleset bypass (organization admins and the `gridsuite-actions` integration — see above).

Organization admins can still bypass the environment protection, consistent with their ability to bypass the branch rulesets.
