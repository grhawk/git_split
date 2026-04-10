# Git Split

`git_split` is a small command-line agent for one specific Git maintenance job: taking a single commit and rewriting it into smaller, easier-to-review commits. It is intended for engineers who already have a local Git repository and need a safer, repeatable way to split history without manually driving `git rebase -i`.

Its main responsibilities are:
- inspect a target commit and list the files it changed
- rewrite one commit into one commit per file
- rewrite one commit by extracting a single file into its own commit while keeping the remaining changes under the original subject
- create a backup branch before rewriting so rollback is straightforward

This README is a living document. Keep it short, update it when commands or runtime behavior change, and split deeper operational notes into separate Markdown files once this project grows beyond a single script.

## Domain

The tool works in the Git history-rewrite domain. It does not manage application data, databases, or long-lived sessions. The main entities are:

- User: the engineer invoking the script from a shell
- Repository: the Git working tree being rewritten
- Target commit: the single non-merge commit selected for inspection or rewrite
- Changed file: a repo-relative path touched by the target commit
- Backup branch: a pre-rewrite recovery point named `backup/pre-split-<shortsha>-<timestamp>`
- Rebase state: the temporary paused state created when the script marks the target commit as `edit`

```text
Engineer
  |
  v
git_split.sh
  |
  +--> validate repo + commit + clean worktree
  +--> inspect changed files in target commit
  +--> optional: print file list
  \--> optional: rewrite history through interactive rebase automation
            |
            +--> backup branch
            +--> reset target commit
            +--> create replacement commits
            \--> continue rebase
```

## Architecture

This project is a single Bash script, [git_split.sh](/Users/rpetraglia/tmp/git_split/git_split.sh), built as a command dispatcher plus a Git orchestration layer.

The orchestration pattern is simple command-driven automation:
- `list` is read-only inspection
- `split` runs a scripted `git rebase -i` flow and replaces one commit with one commit per changed file
- `split-file` runs the same rebase flow but creates one extracted-file commit and one remainder commit

Important components:
- argument parsing and command dispatch
- repository safety checks
- commit metadata loader
- rebase todo editor created through `GIT_SEQUENCE_EDITOR`
- staging helpers that correctly handle modified, added, deleted, and renamed files
- cleanup and error traps

Major dependencies:
- Bash
- Git
- standard shell tools available on most Unix-like systems: `awk`, `date`, `mktemp`

There is no LLM provider, vector database, message bus, or external service dependency in the current design.

## Runbook

### Install and Configure

1. Ensure Bash and Git are installed.
2. Clone or copy this project locally.
3. Make the script executable:

```bash
chmod +x git_split.sh
```

Credentials and secrets:
- No API keys or cloud credentials are required.
- The script operates on your local Git checkout and uses your existing Git identity/config.
- Commit signing is temporarily disabled during the automated rewrite to avoid interactive GPG failures.
- `push-tag.sh` requires an `origin` remote and permission to push commits and tags.

### Run Locally

Run from inside the repository whose history you want to inspect or rewrite.

List files changed by a commit:

```bash
./git_split.sh list <commit-sha>
```

Split a commit into one commit per changed file:

```bash
./git_split.sh split <commit-sha>
```

Split only one file out of a commit:

```bash
./git_split.sh split-file <commit-sha> <repo-relative-path>
```

Example:

```bash
./git_split.sh list a1b2c3d
./git_split.sh split a1b2c3d
./git_split.sh split-file a1b2c3d src/app/config.yaml
```

Expected environment:
- you are inside a Git working tree
- the target commit exists
- the target commit is not a merge commit
- the working tree, index, and untracked-file set are clean before rewrite commands

### Run Tests

There is no formal test harness yet. Current verification is command-line based.

Syntax check:

```bash
bash -n git_split.sh
```

Recommended manual integration test:
1. Create a temporary Git repo.
2. Add a base commit.
3. Create a target commit that includes a mix of modified, added, deleted, and renamed files.
4. Run `list`, `split`, and `split-file`.
5. Inspect `git log --oneline --reverse` and `git status --short`.

Suggested CI command for the current project:

```bash
bash -n git_split.sh
```

If this project grows, add a small shell-based integration test suite and run it in CI against a temporary repository fixture.

GitHub Actions:
- `.github/workflows/release.yml` mirrors the useful parts of the GitLab pipeline for this repo
- pull requests fail if `CHANGELOG.md` is missing from the changeset
- pushes, pull requests, and tags run shell-script validation
- clean semver tags such as `0.1.0` must point to the default branch before a GitHub Release is created
- release notes come from the matching section in `CHANGELOG.md`

## Deployment

This project currently has no production service deployment. “Deployment” means publishing a new script revision for engineers to use.

Current release flow:
1. Make changes locally.
2. Run the syntax check and a temporary-repo integration test.
3. Open a pull request or otherwise request maintainer review.
4. Merge to the main branch after approval.
5. Update `CHANGELOG.md` under `## [Unreleased]`.
6. Create and push a plain semver tag such as `0.1.0`, or use `push-tag.sh`.
7. GitHub Actions validates the tag and creates the GitHub Release from the matching changelog section.
8. Consumers pull the updated script into their local checkout.

Example release commands:

```bash
git tag 0.1.0
git push origin 0.1.0
```

Or, if you are using the helper script:

```bash
./push-tag.sh 0.1.0
```

For clean semver releases, `push-tag.sh`:
- rotates `## [Unreleased]` into `## [<version>] - <date>` inside `CHANGELOG.md`
- commits the changelog update
- creates the Git tag
- pushes both the branch and the tag

Environments:
- Local development only today
- No staging or production runtime environment exists yet

Manual steps and approvals:
- A repo maintainer should review any change that affects history rewriting or safety checks.
- Changes to commit-message generation, backup behavior, or rebase flow deserve extra scrutiny because mistakes can rewrite history incorrectly.

Rollback:
- If a rewrite goes wrong, reset your branch to the generated backup branch.
- If a bad script revision is merged, revert the merge or restore the previous script version in Git.
- If a bad release tag is pushed, delete the GitHub release and tag, fix the issue, update `CHANGELOG.md`, and publish a new version tag.

## FAQ / Gotchas

Why does the script require a clean worktree?
- Rebase and reset operations become ambiguous when unrelated local changes exist. The script blocks early to avoid mixing user work with rewritten history.

Why are untracked files rejected?
- The current safety model is intentionally strict. Untracked files can be accidentally swept into a rewrite workflow or confuse recovery.

Why are merge commits unsupported?
- v1 assumes linear history only. Merge-commit rewriting has additional parent-selection and replay complexity.

Why is commit signing disabled during the rewrite?
- Automated rebases and repeated commits often fail when GPG signing prompts for input. The script disables signing for the rewrite commands to keep the flow non-interactive.

What happens with renames?
- The script stages both the old and new path so Git records the rename correctly, and it uses the new path in generated commit messages.

What if files depend on each other?
- The tool intentionally ignores inter-file dependencies. It performs a straightforward file-based split even if intermediate commits do not build or test cleanly.

What if `split-file` is used on a one-file commit?
- The command rejects that case because there is no meaningful “remainder” commit to preserve with the original subject.

Why do tags not start with `v`?
- `push-tag.sh` and the CI currently treat release tags as plain semver values like `0.1.0`, matching the GitLab rules this repo was modeled on.
