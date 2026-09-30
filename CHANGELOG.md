# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- CLI reference (`docs/command-line.md`) and configuration reference (`docs/configuration.md`).

[1.0.0]: https://github.com/okcompute/git-session/releases/tag/v1.0.0
