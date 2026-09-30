# Repository Configuration

Each repository managed by git-session can be configured with a TOML file that controls how sessions are created within it.

## Location

git-session looks for the configuration in two places, in this order:

**1. Centralized (default)**
```
~/.config/git-session/repos/<repo-name>.toml
```
This is the location used by the add-repo wizard and the recommended one for ongoing edits. The entire `~/.config/git-session/` directory can be version-controlled and symlinked, making it easy to share session configurations across machines via a dotfiles repository.

**2. Per-repository (legacy fallback)**
```
<root-folder>/<repo-name>/.git-session.toml
```
Read only when no centralized config exists for the repository. Kept for backward compatibility with repos created by older versions of git-session; new repos do not write to this location.

When both files exist for the same repository, the centralized file takes priority.

**Example dotfiles layout**
```
~/.config/git-session/
├── config.toml          # root folders (machine-specific)
└── repos/
    ├── my-api.toml
    ├── frontend.toml
    └── infra.toml
```

## Fields

### `bare_repo`

Name of the bare repository subfolder, without the `.git` extension. Defaults to the directory name if omitted.

```toml
bare_repo = "my-project"
```

This means git-session expects the cloned repository at `<repo-name>/my-project.git/`.

### `start_branches`

An array of branch names that worktrees can be based on. When creating a session, the user selects one of these as the starting point.

```toml
start_branches = ["main"]
```

If multiple branches are listed, the user is prompted to choose:

```toml
start_branches = ["main", "develop", "release"]
```

If the array is empty, the user is prompted to type a branch name manually.

### `branch_prefixes`

An array of prefixes prepended to the session name to form the Git branch name. For example, with prefix `feature` and session name `login-page`, the branch becomes `feature/login-page`.

```toml
branch_prefixes = ["feature", "bugfix"]
```

If only one prefix is configured, it is used automatically. If the array is empty, no prefix is added and the branch name equals the session name.

When a repository is first added (via the TUI wizard or `add-repo`), this list is pre-filled from the global `default_branch_prefixes` setting in `~/.config/git-session/config.toml` (defaulting to `["feature", "bugfix", "chore", "refactor", "docs", "test"]`). You can edit the per-repo list afterwards, or change the global default to alter the template applied to future repositories.

### `origin_url` and `root` (recovery fields)

These two fields are written by the add-repo wizard into the centralized config and used to automatically recover the bare repository if it (or its parent folders) is accidentally deleted from disk:

```toml
origin_url = "git@github.com:user/my-project.git"
root = "/Users/me/Developer"
```

- `origin_url` — the clone URL git-session will re-clone from when the bare repository is missing.
- `root` — the absolute path of the parent folder under which the repo lives (i.e. the bare repo will be re-created at `<root>/<repo-name>/<bare_repo>.git`).

Both fields are optional. If they are absent on a repository that was added before this feature existed, git-session will silently backfill them the next time it opens the repository (reading `origin_url` from the bare repo's `origin` remote and `root` from the configured root folder being scanned). After backfill, future deletions can be auto-recovered.

Recovery is only attempted when the centralized config exists; repositories configured exclusively via the legacy `<repo>/.git-session.toml` file are *not* eligible because that file lives inside the repo folder and is therefore deleted along with it.

When recovery runs, git-session prints a single line to stderr describing what it is doing and then proceeds to re-clone — there is no confirmation prompt.

## TMUX Windows

Define the TMUX windows created for each session using `[[window]]` sections. Each window has a `name` and an optional `command`.

```toml
[[window]]
name = "vim"
command = "vim"

[[window]]
name = "git"
command = "git status"
```

- `name` — the TMUX window name (shown in the status bar)
- `command` — (optional) command(s) to execute in the window after `cd`-ing to the worktree. If omitted or empty, the window opens a plain shell. Supports two forms:
  - **Single command:** `command = "vim"`
  - **Multiple commands:** use a triple-quoted multi-line string where each line is a separate command, executed in order:
    ```toml
    command = """
    fnm use
    npm install
    npm run dev
    """
    ```

Windows are created in order. The first window receives focus after creation.

**If no `[[window]]` sections are defined**, a single shell window is created with no command.

### Environment variables

Every window command runs with the `GS_REPO_PATH` environment variable set to
the session's worktree folder.

Commands already start with their working directory set to the worktree, so you
do not need `GS_REPO_PATH` to reference files in the repository directly (just
use relative paths). It is useful when a command changes directory but still
needs an absolute path back to the repository — for example a tool run from
elsewhere that takes the repository as a target path:

```toml
[[window]]
name = "build"
command = "pushd ~/tools && ./run-build.sh --target \"$GS_REPO_PATH\""
```

`GS_REPO_PATH` is also available in any interactive shell in the session and in
windows or panes you open later. Requires tmux >= 3.0.

### Examples

#### Minimal (shell only)

```toml
bare_repo = "my-project"
start_branches = ["main"]
branch_prefixes = ["feature"]
```

Creates sessions with a single empty shell window.

#### Standard development

```toml
bare_repo = "my-project"
start_branches = ["main"]
branch_prefixes = ["feature", "bugfix"]

[[window]]
name = "vim"
command = "vim"

[[window]]
name = "git"
command = "git status"
```

#### Node.js project

```toml
bare_repo = "my-api"
start_branches = ["main", "develop"]
branch_prefixes = ["feature"]

[[window]]
name = "editor"
command = "vim"

[[window]]
name = "git"
command = "git status"

[[window]]
name = "server"
command = """
fnm use
npm install
npm run dev
"""

[[window]]
name = "test"
command = """
fnm use
npm test -- --watch
"""
```

The `server` and `test` windows each run multiple commands in sequence: first setting the correct Node version with `fnm use`, then running the desired command.

#### Project with a custom root folder

```toml
bare_repo = "game-engine"
start_branches = ["main"]
branch_prefixes = ["feature"]

[[window]]
name = "editor"
command = "vim"

[[window]]
name = "git"
command = "git status"

[[window]]
name = "build"
```

The `build` window has no command, so it opens as a plain shell ready for manual build commands.

## Full Example

```toml
# Git Session configuration for my-project
bare_repo = "my-project"
start_branches = ["main"]
branch_prefixes = ["feature", "bugfix"]

[[window]]
name = "vim"
command = "vim"

[[window]]
name = "git"
command = "git status"

[[window]]
name = "server"
command = "npm run dev"

[[window]]
name = "ai"
command = "aider"
```
