# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Windows can set a `fix_command` that runs instead of `command` when a session is restored with `fix`. Without it, `fix` runs `command` as before. `fix_command = ""` opens a plain shell, for example to skip a build that only matters on first creation.
- Window commands get a `GS_SESSION_SLUG` environment variable: a stable slug of the repository and session names (e.g. `my-project.login-page`). It lets a command name things after the session, such as `opencode --session "ses_$GS_SESSION_SLUG"`, which starts an OpenCode session on `create` and resumes it on `fix`.

## [1.1.0] - 2026-11-04

### Added

- Rex support: git-session can drive the [Rex](https://www.superlogical.com/rex/docs.md) terminal app instead of tmux. Set `multiplexer = "rex"` in `~/.config/git-session/config.toml`. When the key is not set, Rex is picked automatically when git-session runs in a Rex terminal outside tmux. tmux remains the default and behaves as before. The same `[[window]]` entries create Rex tabs with the configured labels, start in the worktree, and get their commands typed into the shell. `GS_REPO_PATH` is set in each of those windows.
- Rex sessions get a shorter label than tmux sessions, `<repository> · <session>` (e.g. `my-project · login-page`), because Rex's session picker clips long labels.
- With Rex, `create` and `fix` offer to show the session in the Rex app (requires Remote Control in the app's settings). `remove` and `remove-repo` stop running programs and kill the Rex session last, as with tmux.
- With Rex, git-session never starts a Rex server. When the Rex app is not running it prints a clear error and exits with status 4 before changing anything.
- `git-session config` now also prints the `multiplexer` setting.
- The TUI remove and fix lists tag each session with where it is running: `[tmux]`, `[Rex]`, or both.
- `remove` and `remove-repo` also clean up a session left in the other multiplexer after switching between tmux and Rex.

## [1.0.1] - 2026-10-21

### Fixed

- Creating a session in a repository cloned from an empty remote (no commits yet) no longer fails with a generic "Failed to create worktree" error. The session's branch is now created as an orphan branch (requires git >= 2.42).
- When worktree creation fails in the TUI, the error message now includes git's own error line instead of only a generic message.
- Removing a session whose branch has no commits yet no longer reports a "Failed to delete branch" error.
- Long messages in the TUI no longer overlap the "Press any key to continue..." hint.
- Determining a session's branch from its worktree now works on branches without commits and correctly reports nothing for a detached HEAD.

## [1.0.0] - 2026-09-30

Initial public release.

### Added

- Interactive TUI for managing Git worktree-based development sessions with tmux: create, remove, and reattach ("fix") sessions.
- Non-interactive CLI for the same operations: `git-session create|remove|fix` with `--repository`, `--session`, `--branch`, and `--prefix`. When some flags are omitted, the TUI opens at the step where input is still needed.
- `git-session add-repo <url>` and `git-session remove-repo <name>` to register and remove repositories. Adding clones into the `<root>/<name>/<name>.git` layout (a bare repository plus sibling worktrees) and writes a per-repository config.
- TUI remove-repository flow: press `D` on a highlighted repository in the main menu. The confirmation screen shows the repository, its location, and the number of sessions that will be deleted.
- `git-session config` commands: list configured roots, `add-root`, and `remove-root` (optionally cascading the removal of the repositories under a root and their tmux sessions).
- Multiple root folders; repositories from every root are aggregated in the main menu.
- Centralized per-repository configuration at `~/.config/git-session/repos/<name>.toml`, which takes priority over the legacy in-repo `.git-session.toml`. Configs can live in a dotfiles repository and be shared across machines.
- Configurable default branch prefixes for new repositories via `default_branch_prefixes` in the global config (`~/.config/git-session/config.toml`), accepting either a TOML array or a quoted comma-separated string.
- `GS_REPO_PATH`, exported to every tmux window in a session and set to the session's worktree folder so window commands and shells can reference it. Requires tmux >= 3.0.
- New worktrees are based on the latest origin state of the selected base branch.
- Automatic recovery of deleted bare repositories: if the bare repository, the repository folder, or an entire root folder is removed, git-session re-creates and re-clones from the recorded origin URL the next time the repository is opened.
- Vanished repositories (on-disk folder deleted but central config still present) remain listed so recovery can be triggered through the normal CLI/TUI flows.
- CLI reference (`docs/command-line.md`), configuration reference (`docs/configuration.md`), and installation guide (`docs/installation.md`).
- Prebuilt release binaries for Linux and macOS, published as GitHub Release assets alongside a `SHA256SUMS` checksum file. Pushing a `v*` tag builds and publishes them through the `Release` workflow, and the assets are served via GitHub's CDN.
- `install.sh` downloads the matching release binary by default (verifying its SHA-256 checksum) and falls back to building from source when no prebuilt binary is available. New options: `--version <tag>` to pick a release and `--from-source` to force a source build.

[Unreleased]: https://github.com/okcompute/git-session/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/okcompute/git-session/releases/tag/v1.1.0
[1.0.1]: https://github.com/okcompute/git-session/releases/tag/v1.0.1
[1.0.0]: https://github.com/okcompute/git-session/releases/tag/v1.0.0
