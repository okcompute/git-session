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

## Windows

Define the windows created for each session using `[[window]]` sections. Each window has a `name` and an optional `command`. The same sections drive both multiplexers: with tmux they become tmux windows, with [Rex](#using-rex) they become tabs (Rex windows).

```toml
[[window]]
name = "vim"
command = "vim"

[[window]]
name = "git"
command = "git status"
```

- `name` — the window name (shown in the tmux status bar, or as the tab label in Rex)
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
- `fix_command` — (optional) command(s) to run instead of `command` when the session is restored with `fix`. Same forms as `command`. If the key is absent, `fix` runs `command`. Set `fix_command = ""` to open a plain shell on `fix`.

Windows are created in order. The first window receives focus after creation.

**If no `[[window]]` sections are defined**, a single shell window is created with no command.

### Different commands on `fix`

`fix` rebuilds a session for a worktree that already exists, for example after
a reboot. Some commands only make sense the first time a session is created. A
first build can be skipped, and an AI agent can resume its earlier conversation
instead of starting a new one:

```toml
[[window]]
name = "build"
command = "zig build"
fix_command = ""        # plain shell on fix

[[window]]
name = "ai"
command = "opencode --session \"ses_$GS_SESSION_SLUG\""
# no fix_command: fix runs the same command, which resumes the session
```

`opencode --session <id>` continues the session with that ID, or creates it if
it does not exist. With an ID built from `GS_SESSION_SLUG` (see below), `create`
starts a new OpenCode session and `fix` reopens the same one. OpenCode
session IDs must start with `ses`.

### Environment variables

Every window command runs with these environment variables set:

- `GS_REPO_PATH`: the session's worktree folder.
- `GS_SESSION_SLUG`: a stable slug made of the repository and session names,
  lowercase, with every run of characters other than letters and digits
  replaced by `-`. For example, `my-project/login-page` becomes
  `my-project-login-page`. It stays the same across `create` and `fix`, so
  commands can use it to name things tied to the session.

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

With tmux, both variables are also available in any interactive shell in the
session and in windows or panes you open later. Requires tmux >= 3.0.

With Rex, both variables are set in the shell of every window git-session
creates, but not in tabs or splits you open yourself later (see
[Using Rex](#using-rex)).

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

## Terminal multiplexer

git-session creates one terminal session per worktree, using either
[tmux](https://github.com/tmux/tmux) (the default) or
[Rex](https://www.superlogical.com/rex/docs.md). The choice is a global setting
in `~/.config/git-session/config.toml`:

```toml
multiplexer = "rex"   # or "tmux"
```

How the backend is chosen, in order:

1. The `multiplexer` key, when set. An unknown value is an error.
2. Otherwise Rex, when git-session runs in a Rex terminal (`REX_SESSION` is set)
   that is not also inside tmux (`TMUX` is unset).
3. Otherwise tmux.

`git-session config` shows the current value.

**Switching backends.** Sessions are tied to worktrees, not to a backend:

- The remove and fix lists in the TUI show every worktree of the repository,
  tagged with where it currently has a live session: `[tmux]`, `[Rex]`, or
  `[tmux, Rex]`. No tag means no session is running in either.
- `fix` creates the session in the currently selected backend, which is how
  you move a worktree from one backend to the other.
- `remove` and `remove-repo` stop and kill the worktree's session in **both**
  backends, so switching backends never leaves orphaned sessions behind. tmux
  is always tried; Rex only when the `rex` CLI is found.

### Using Rex

[Rex](https://www.superlogical.com/rex/docs.md) is a terminal app and
multiplexer by Superlogical. git-session drives it through the `rex` CLI. Rex's
vocabulary maps onto tmux's: session = session, window (a tab in the app) =
window, block = pane.

**Requirements**

- The Rex app (macOS, public beta) must be running. On macOS the app runs the
  Rex server, and git-session never starts one itself. When the server is not
  reachable, git-session prints `the Rex server is not running` and exits with
  status 4, before it touches any worktree.
- The `rex` CLI must be on `PATH`, or in `$REX_BIN_DIR`. Rex sets both in its
  own terminals. To run git-session from another terminal, link the CLI
  shipped inside the app into a directory on your `PATH`, for example:
  ```bash
  ln -s "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex" ~/.local/bin/rex
  ```
  (The path inside the app bundle may change between Rex releases.)
- To let git-session switch the Rex app to a session ("Show session in Rex?"),
  turn on **Remote Control** in the Rex app's settings. Without it, everything
  else works and git-session tells you to pick the session in the Rex sidebar
  instead.

**What git-session does with Rex**

| Step | Rex command |
|---|---|
| Does the session exist? | `rex ls --json`, matching the label exactly |
| Create the session and first window | `rex new <label> --window <name> --cwd <worktree> …` |
| Add a window | `rex window new -s <session> <name> --cwd <worktree> --focus=false …` |
| Run a window's command | `rex send … <command>` then `rex send-key … enter` |
| Focus the first window | `rex window focus 1 -s <session>` |
| Show the session | `rex do session.select session_id=<id>` (needs Remote Control) |
| Stop programs before removal | `rex send-key -b <block> ctrl+c`, then `exit` + Enter, for every block |
| Kill the session | `rex kill <session-id>…` |

Every call passes `--autostart=false`, so a missing server is reported instead
of a throwaway server being started.

**Differences from tmux**

- **`GS_REPO_PATH` and `GS_SESSION_SLUG`.** Rex has no option to set an
  environment variable for a new terminal (no equivalent of tmux `-e`).
  git-session starts each window's shell as
  `/usr/bin/env GS_REPO_PATH=<worktree> GS_SESSION_SLUG=<slug> $SHELL -l`, so
  the variables are set for that shell and everything it runs. Tabs or splits
  you open later in the session start a normal shell without them.
- **Commands are typed into the shell**, as with tmux. They run with your
  interactive shell configuration (aliases and functions work), pipes and `&&`
  work, and the shell stays open after the command exits.
- **Session names** are shorter than tmux's: `<repository> · <session>`, for
  example `my-project · login-page` instead of
  `(my-project/feature/) - login-page`. Rex's session picker clips long labels
  at the end, so the branch prefix is left out. Labels longer than Rex's
  128-character limit are truncated.
- **Closed tabs.** A Rex session stays open after its last tab is closed,
  where tmux would end the session. git-session treats such an empty session
  as gone: `fix` replaces it with a new one, and the TUI lists don't tag it
  `[Rex]`.
- **Attaching.** Rex has no attach step: the app always shows a session. After
  `create` or `fix`, git-session offers to show the new session in the app,
  whether or not git-session itself runs inside Rex.
- **Removing the session you are in.** When git-session runs inside the session
  being removed, it asks the app to show the next session first (Rex has no
  "last session" action, unlike tmux's `switch-client -l`). It does not send
  Ctrl-C to its own terminal. Rex does not report which session the app is
  showing, so the tmux-only pop-up and status-line notification for "you
  switched away while git-session was working" are not shown with Rex.

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
