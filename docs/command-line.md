# Command-Line Interface

git-session can be driven entirely from the command line. When enough information is supplied the tool runs non-interactively and exits; when information is missing it opens the TUI at the step where the missing data is collected.

## Synopsis

```
git-session [--version | -v]
git-session [help | --help | -h]
git-session [--repository <name>]
git-session create  --repository <name> [--session <name>] [--branch <name>] [--prefix <name>]
git-session remove  --repository <name> [--session <name>]
git-session fix     --repository <name> [--session <name>]
git-session add-repo    <url> [--root <path>] [--name <name>] [--branch <name>] [--prefix <list>] [--yes | -y]
git-session remove-repo <name> [--yes | -y]
git-session config
git-session config add-root    [<path>]
git-session config remove-root [<path>] [--yes | -y]
```

## Global flags

| Flag | Description |
|---|---|
| `--version`, `-v` | Print the version and exit. |
| `help`, `--help`, `-h` | Print usage and exit. |
| `--repository <name>` | (TUI mode) Pre-select a repository and open the TUI at its action menu. |

## Session subcommands

All three session subcommands require `--repository`. They run non-interactively when every piece of required information is available; otherwise the TUI opens at the earliest step that still needs user input.

### `create`

Create a new session: git worktree + branch + tmux session.

```
git-session create --repository <name> [--session <name>] [--branch <name>] [--prefix <name>]
```

| Flag | Description |
|---|---|
| `--repository <name>` | **Required.** Repository name (directory name under a configured root). |
| `--session <name>` | Session name. Becomes the worktree directory and the final component of the branch name. Only letters, digits, `-`, and `_` are accepted. |
| `--branch <name>` | Base branch to create the worktree from (e.g. `main`). Must be one of the values in `start_branches` when that list is non-empty. |
| `--prefix <name>` | Branch prefix (e.g. `feature`). Must be one of the values in `branch_prefixes` when that list is non-empty. Use an empty string (`--prefix ""`) for no prefix. |

**Branch and prefix resolution:**

When `--branch` or `--prefix` are omitted, git-session resolves them automatically if the repository configuration leaves no ambiguity:

- If `start_branches` has exactly one entry, that branch is used automatically.
- If `start_branches` is empty, `main` is used.
- If `start_branches` has multiple entries and `--branch` is not given, the TUI opens at the branch-selection step.

The same logic applies to `--prefix` and `branch_prefixes`.

**Non-interactive mode** is triggered when `--session`, a resolved branch, and a resolved prefix are all available. Otherwise the TUI opens at the first step that still needs input.

**Examples:**

```bash
# Fully non-interactive (repo has one branch and one prefix configured)
git-session create --repository my-project --session login-page

# Provide branch explicitly
git-session create --repository my-project --session login-page --branch main

# Provide everything — always non-interactive
git-session create --repository my-project --session login-page --branch main --prefix feature

# Open TUI at the session-name input (branch and prefix are auto-resolved)
git-session create --repository my-project

# Open TUI with session name pre-filled, branch still needs picking
git-session create --repository my-project --session login-page
# (when start_branches has multiple entries)
```

After creating a session you are offered the chance to attach to it (when running inside tmux). Outside tmux the attach command is printed to stdout.

### `remove`

Remove an existing session: worktree, branch, session file, and tmux session.

```
git-session remove --repository <name> [--session <name>]
```

| Flag | Description |
|---|---|
| `--repository <name>` | **Required.** Repository name. |
| `--session <name>` | Session (worktree) name to remove. When omitted the TUI opens at the session-selection screen. |

**Examples:**

```bash
# Non-interactive removal
git-session remove --repository my-project --session login-page

# Open TUI at the session list for my-project
git-session remove --repository my-project
```

> **Note:** The tmux session is killed last, after the worktree and branch have been cleaned up, to ensure the git-session process finishes before tmux terminates it.

### `fix`

Recreate the tmux session for an existing worktree (useful after a reboot or when the tmux server was restarted).

```
git-session fix --repository <name> [--session <name>]
```

| Flag | Description |
|---|---|
| `--repository <name>` | **Required.** Repository name. |
| `--session <name>` | Session (worktree) name to fix. When omitted the TUI opens at the session-selection screen. |

**Examples:**

```bash
# Non-interactive fix
git-session fix --repository my-project --session login-page

# Open TUI at the session list for my-project
git-session fix --repository my-project
```

## Repository management

### `add-repo`

Clone a remote repository as a bare repo and register it with git-session. CLI counterpart to the TUI add-repository wizard.

```
git-session add-repo <url> [--root <path>] [--name <name>] [--branch <name>] [--prefix <list>] [--yes | -y]
```

| Argument / Flag | Description |
|---|---|
| `<url>` | **Required.** Clone URL (HTTPS or SSH). |
| `--root <path>` | Root folder to clone into. When the path is not yet in the configuration, you are asked whether to register it (default = yes); declining aborts. With `--yes` the path is registered silently. When omitted entirely, a numbered picker is shown and pressing Enter accepts the first configured root; with `--yes` the first root is used silently. |
| `--name <name>` | Repository name (the directory created under `<root>`). Defaults to the basename of `<url>` with any trailing `.git` stripped (e.g. `https://github.com/user/my-repo.git` -> `my-repo`). |
| `--branch <name>` | Default branch recorded in `start_branches`. Defaults to `main`. |
| `--prefix <list>` | Comma-separated branch prefixes recorded in `branch_prefixes`. Defaults to the global `default_branch_prefixes` list (`feature, bugfix, chore, refactor, docs, test` unless customized in `config.toml`). Pass an empty string to record an empty list. |
| `--yes`, `-y` | Skip every confirmation prompt: accepts the first configured root when `--root` is omitted, and silently registers a new root when `--root` points to a path not yet in the configuration. |

The clone is placed at `<root>/<name>/<name>.git` and a generated TOML configuration is written to `~/.config/git-session/repos/<name>.toml`.

If `<root>/<name>` already exists the command refuses to overwrite it and exits with code 1; remove the existing directory first or pass `--name` to disambiguate.

**Examples:**

```bash
# Interactive root picker (default = first root); everything else derived.
git-session add-repo git@github.com:user/my-repo.git

# Fully non-interactive: pick the first configured root silently.
git-session add-repo git@github.com:user/my-repo.git --yes

# Pick a specific root and override the derived name.
git-session add-repo git@github.com:user/legacy.git --root ~/Developer/Git --name legacy-app

# Use a brand-new root: prompts to register the path, then clones into it.
# (Pass --yes to register without the prompt.)
git-session add-repo git@github.com:user/api.git --root ~/Developer/NewRoot

# Use a non-default branch and multiple prefixes.
git-session add-repo https://github.com/user/api.git --branch develop --prefix feature,bugfix,hotfix

# Record no prefixes at all.
git-session add-repo https://github.com/user/api.git --prefix ""
```

> **Note:** This is the CLI counterpart to the TUI add-repository wizard (the `[a] Add a new repository` entry in the main menu). The two flows produce identical on-disk layouts and configuration files.

### `remove-repo`

Permanently remove a repository: deletes the on-disk directory (bare repo and every worktree), kills every tmux session associated with the repository, and removes the centralized config file at `~/.config/git-session/repos/<name>.toml`.

```
git-session remove-repo <name> [--yes | -y]
```

| Argument / Flag | Description |
|---|---|
| `<name>` | **Required.** Repository name (directory name under a configured root). |
| `--yes`, `-y` | Skip the confirmation prompt. Use with care -- the operation is irreversible. |

Without `--yes` the command prints a summary (location, session count, list of sessions, config path) and requires the user to type `yes` and press Enter to proceed. Any other input aborts.

**Examples:**

```bash
# Interactive: shows summary, asks for "yes" confirmation
git-session remove-repo my-project

# Non-interactive: skips the prompt
git-session remove-repo my-project --yes
```

> **Note:** This is the moral equivalent of `rm -rf <root>/<name>` plus a tmux cleanup. The TUI also exposes the same operation via the capital `D` key on the highlighted repository in the main menu.

## Config subcommands

Config commands manage the list of root folders where git-session looks for repositories. They never open the TUI.

### `config`

Print the currently configured root folders.

```bash
git-session config
```

### `config add-root`

Add a new root folder. Creates the directory if it does not exist. `~` is expanded to `$HOME`.

```bash
git-session config add-root [<path>]
```

When `<path>` is omitted you are prompted interactively.

```bash
git-session config add-root ~/Developer/Git
git-session config add-root /opt/Projects
```

### `config remove-root`

Remove a root folder from the configuration.

```bash
git-session config remove-root [<path>] [--yes | -y]
```

When `<path>` is given it is matched against the configured list (after `~` expansion) and removed directly. When `<path>` is omitted an interactive numbered list is shown.

If the chosen root contains at least one registered repository, the command lists them and asks whether to also remove their on-disk directories and tmux sessions. The default is **no** -- pressing Enter (or `n`) leaves the repositories on disk and only unhooks the root from the configuration. Answering `y` (or passing `--yes`/`-y`) cascades a full `remove-repo` for every repository under the doomed root before unhooking it.

After the cascade, the root folder itself is `rmdir`-ed when (and only when) it is empty. Anything in the root that is not a registered git-session repository (loose files, unrelated subdirectories) is left alone, and in that case the root folder is kept on disk with a note explaining why.

```bash
# Just unhook the path; any repos under it stay on disk.
git-session config remove-root ~/Developer/Old

# Cascade: also delete every registered repo under the path, non-interactively.
git-session config remove-root ~/Developer/Old --yes
```

The last remaining root cannot be removed.

## Error handling

| Situation | Behaviour |
|---|---|
| Unknown command or flag | Prints an error and usage, exits with code 1. |
| `--repository` not found | Prints an error, exits with code 1. |
| `--branch` not in `start_branches` | Prints an error listing the configured branches, exits with code 1. |
| `--prefix` not in `branch_prefixes` | Prints an error listing the configured prefixes, exits with code 1. |
| Branch already exists | Prints an error, exits with code 1 (create only). |
| Session not found (remove/fix) | Prints an error listing available sessions, exits with code 1. |
| Repository not found (remove-repo) | Prints an error, exits with code 1. |
| `remove-repo` confirmation declined | Prints `Aborted.` and exits with code 0. |
| `add-repo` `--root` not in configuration | Lists the configured roots and asks whether to register the new one. Declining prints `Aborted.` and exits with code 0. With `--yes`, the path is registered silently. |
| `add-repo` invalid root selection at the picker prompt | Prints an error, exits with code 1. |
| Unknown flag that matches a known subcommand (e.g. `--remove-repo`) | Prints `Unknown flag: ...` plus a hint that subcommands are positional, exits with code 1. |
| `config remove-root` on the last remaining root | Prints `Cannot remove the last root folder.` and exits with code 0. |
| `config remove-root` cascade encounters a per-repo failure | Prints a warning for the failing repo and continues with the rest. The root is still unhooked from the configuration at the end. |
| `add-repo` target directory already exists | Prints an error, exits with code 1 (no clone is attempted). |
| `add-repo` clone failed | Prints an error, removes the partially-created directory, exits with code 1. |
| Partial information provided (create / remove / fix) | Opens the TUI at the step where input is needed. |

## TUI pre-selection

When the TUI is opened with partial information, it starts at the first step that still requires input:

| Provided flags | TUI starts at |
|---|---|
| `create --repository` | Repository pre-selected, session-name input |
| `create --repository --session` | Session pre-filled, branch selection (if multiple) or prefix selection (if multiple) or confirmation |
| `create --repository --session --branch` | Session + branch pre-filled, prefix selection (if multiple) or confirmation |
| `remove --repository` | Repository pre-selected, session list |
| `fix --repository` | Repository pre-selected, session list |

When a session name is passed to `remove` or `fix` without `--session` being sufficient for non-interactive mode, the TUI opens with that session pre-highlighted in the list.
