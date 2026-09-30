# git-session

A TUI tool for managing Git worktree-based development sessions with TMUX. Written in Zig.

git-session handles:

- Creating Git worktrees from configured base branches
- Setting up TMUX sessions with customizable window layouts
- Cleaning up worktrees, branches, and TMUX sessions
- Reattaching to existing sessions

## Requirements

- [Zig](https://ziglang.org/) 0.16+
- Git
- TMUX

## Install

Clone the repository and run the install script:

```bash
git clone https://github.com/okcompute/git-session.git
cd git-session
./install.sh
```

The script checks that all prerequisites are present, builds the project, and installs the binary to `~/.local/bin`. To install to a different location:

```bash
./install.sh --prefix ~       # installs to ~/bin
```

## Quick Start

On first run, git-session prompts for a root folder where your repositories will be stored. Then press `a` to add a repository:

```
  Git Session Manager
  Select a repository

  > [a] Add a new repository
    [q] Quit

  j/k: navigate  enter: select  a: add repo  q: quit
```

The add-repo wizard walks you through cloning and configuring a repository step by step (URL, name, default branch, branch prefixes). It configures the repository for worktree-based development and writes a configuration file at `~/.config/git-session/repos/<repo-name>.toml`.

## Usage

### Interactive mode

```bash
git-session
```

Select a repository, then choose an operation:

```
  my-project
  ~/Developer/Git

  > [1] Create a new session
    [2] Remove a session
    [3] Fix a session (reattach)
    [q] Back

  j/k: navigate  enter: select  q/esc: back
```

- **Create a new session** -- creates a Git worktree and a TMUX session
- **Remove a session** -- deletes the worktree, branch, and TMUX session
- **Fix a session** -- recreates the TMUX session for an existing worktree

### Command-line interface

git-session can be driven entirely from the command line. When all required information is provided the tool runs non-interactively; when some fields are missing it opens the TUI at the step where input is needed.

```bash
# Create a session non-interactively
git-session create --repository my-project --session login-page --branch main --prefix feature

# Remove a session non-interactively
git-session remove --repository my-project --session login-page

# Fix a session non-interactively
git-session fix --repository my-project --session login-page

# Open TUI pre-selecting a repository
git-session --repository my-project

# Open TUI at the create screen for a specific repo
git-session create --repository my-project
```

See [docs/command-line.md](docs/command-line.md) for the full CLI reference.

### Configuration commands

```bash
git-session config                         # Show configured root folders
git-session config add-root [<path>]       # Add a root folder
git-session config remove-root [<path>]    # Remove a root folder (interactive if path omitted)
git-session help                           # Show usage
```

### Multiple root folders

Some projects need to live in specific directories. git-session supports multiple root folders:

```bash
git-session config add-root /opt/Projects
```

Repositories from all roots are aggregated in the main menu.

## How It Works

### Directory structure

Each managed repository follows this layout:

```
<root-folder>/
  my-project/
    my-project.git/       # Cloned repository (core.bare = true)
      .git/               # Standard Git internals
    feature-a/            # Worktree (session)
    feature-b/            # Worktree (session)
```

The repository is cloned normally then configured with `core.bare = true`, keeping the `.git` subfolder for compatibility with tools that expect it.

The per-repository configuration lives at `~/.config/git-session/repos/<repo-name>.toml` so the working tree stays untouched. A legacy `<repo>/.git-session.toml` file is still read as a fallback when no centralized file exists.

### Session creation flow

1. Pick a session name (e.g. `login-page`)
2. Select a base branch from the config (e.g. `main`)
3. Select a branch prefix from the config (e.g. `feature`)
4. git-session creates:
   - A worktree at `<repo>/login-page`
   - A branch named `feature/login-page` based on `main`
   - A TMUX session with the configured windows

## Configuration

See [docs/configuration.md](docs/configuration.md) for the full repository configuration reference.

### Example

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

[[window]]
name = "server"
command = "npm run dev"
```

Window commands can reference `$GS_REPO_PATH` (the session's worktree folder). See [docs/configuration.md](docs/configuration.md) for details.

## Global Configuration

Stored at `~/.config/git-session/config.toml`:

```toml
roots = ["/Users/you/Developer/Git", "/opt/Projects"]
default_branch_prefixes = ["feature", "bugfix", "chore", "refactor", "docs", "test"]
```

- `roots` — the root folders under which managed repositories are stored.
- `default_branch_prefixes` — the branch prefixes proposed by the add-repo flow (both the TUI wizard and the CLI `--prefix` default) when adding a new repository. Edit this list to customize the template applied to new repos. If the key is omitted, git-session falls back to the standard list shown above. Both a TOML array (`["feature", "bugfix"]`) and a quoted comma-separated string (`"feature,bugfix"`) are accepted.

## Contributing

### Build and test

```bash
zig build                   # compile
zig build run               # compile and run
zig build test              # run unit tests
```

### Linting

This project uses [zlint](https://github.com/DonIsaac/zlint) for static analysis. Install it and run from the repo root:

```bash
# install zlint
curl -fsSL https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/tasks/install.sh | bash -s -- v0.7.9

# run the linter
zlint
```

Configuration is in `zlint.json`.

### Changelog

This project uses a [CHANGELOG.md](CHANGELOG.md) following the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Every pull request that changes application code must include a changelog entry under the `[Unreleased]` section.

### CI

A GitHub Actions workflow runs on every push to `main` and on pull requests. It builds the project, runs all tests, runs zlint, and verifies the release binary on both Linux and macOS.

## License

MIT
