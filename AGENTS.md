# Agent Guidelines

## Pull Requests

This is a personal project. There is no Jira integration or ticket requirement.

When creating PRs:
- Do not include a JIRA section in the PR description.
- Do not look for Jira ticket IDs in branch names or commit messages.
- Do not ask the user for a Jira ticket reference. Skip any Jira-related steps entirely.
- PR title format: a short, descriptive summary of the changes.
- PR description should contain a "Change details" section and a "PR Checklist" with at minimum a self-review checkbox.
- Before creating a PR, run a code review using the `git-session-review` skill (located at `.agents/skills/git-session-review/`).

When checking if the branch needs to be pushed before creating a PR:
- Do NOT rely solely on `git status` to determine if commits have been pushed. It can report "ahead" even when the remote is up to date if the local tracking ref is stale.
- Always run `git fetch origin` first to ensure remote refs are up to date.
- Then check whether the branch exists on the remote by running `git rev-parse origin/<branch> 2>/dev/null`. Do NOT rely solely on `@{u}` (the upstream tracking ref) — a branch can exist on the remote without having a local tracking ref configured (e.g., if pushed with `git push origin <branch>` without `-u`).
- If `origin/<branch>` exists, compare `git rev-parse HEAD` with `git rev-parse origin/<branch>`. If they match, the branch is up to date — do not push or prompt to push.
- If `origin/<branch>` does not exist, the branch has not been pushed. Inform the user that they need to push — do not push on the agent's behalf (see Git Push Policy).

## Git Push Policy

Agents must NEVER push to the remote repository. Only humans are allowed to push. If the branch needs to be pushed before a PR can be created, inform the user and wait for them to push it themselves.

Agents must NEVER run git write operations such as `git push`, `git commit`, `git rebase`, `git merge`, `git reset`, `git checkout`, `git branch -d`, or `git stash`. Read-only git commands (`git status`, `git log`, `git diff`, `git fetch`, `git rev-parse`, `git branch --list`) are allowed.

## Changelog

Every PR that changes application code must include an update to `CHANGELOG.md`. The changelog follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Entries go under an `[Unreleased]` section at the top, using the appropriate category (`Added`, `Changed`, `Fixed`, `Removed`).

Changes that do NOT require a changelog entry:
- CI-only changes (workflow files)
- Agent configuration (AGENTS.md, skills)
- Documentation-only changes that don't affect the app

When creating commits or PRs, always verify that `CHANGELOG.md` has been updated if the change touches application code (`src/`, `build.zig`, `build.zig.zon`).

## Releases

Releases are cut by pushing a `v*` tag (e.g. `v1.0.0`); the `Release` workflow (`.github/workflows/release.yml`) builds prebuilt binaries for Linux and macOS and publishes them with a `SHA256SUMS` file. Keep the `build.zig.zon` version, the `CHANGELOG.md` section, and the tag in sync — the tag is embedded as the binary's `--version`, so a mismatch ships the wrong version string silently.

## Linting

This project uses [zlint](https://github.com/DonIsaac/zlint) for static analysis. Agents must run `zlint` from the repository root before considering any code change complete. The configuration lives in `zlint.json`.

- Run `zlint` after making code changes and fix any reported errors or warnings.
- If zlint is not installed, install it with: `curl -fsSL https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/tasks/install.sh | bash -s -- v0.7.9`
- Do not disable rules in `zlint.json` without explicit user approval.
- Do not use `// zlint-disable` file-level directives — they trigger a known zlint bug (hang/OOM). If a rule produces false positives, disable it in `zlint.json` instead.

## Locked Skills

Skills tracked in `skills-lock.json` are installed via the skills package manager and must NEVER be modified by agents. If a locked skill needs changes, create or update a repository-specific skill instead.
