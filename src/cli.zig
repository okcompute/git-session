const std = @import("std");
const main = @import("main.zig");
const term = @import("term.zig");
const config = @import("config.zig");
const repo = @import("repo.zig");
const git = @import("git.zig");
const tmux = @import("tmux.zig");
const validate = @import("git_branch_validate.zig");
const args_mod = @import("cli_args.zig");

pub const CliArgs = args_mod.CliArgs;
pub const CliOperation = args_mod.CliOperation;

/// Prints the version string to stdout.
pub fn printVersion(io: std.Io) void {
    term.print(io, "git-session {s}\n", .{main.version});
}

/// Prints the CLI usage/help text to stdout, listing available options
/// and commands.
pub fn printUsage(io: std.Io) void {
    term.print(io, 
        \\Usage: git-session [options] [command]
        \\
        \\Options:
        \\  --repository <name>  Pre-select a repository and open the TUI at its menu
        \\  --version, -v        Show version
        \\
        \\Commands:
        \\  (none)              Interactive session manager (TUI)
        \\  create              Create a new session
        \\  remove              Remove an existing session
        \\  fix                 Fix a session (recreate its tmux session)
        \\  add-repo            Add (clone) a new repository
        \\  remove-repo         Remove a repository (deletes directory and all sessions)
        \\  config              Show current configuration
        \\  config add-root     Add a root folder
        \\  config remove-root  Remove a root folder (optionally also its repositories)
        \\  help                Show this help message
        \\
        \\Session commands accept:
        \\  --repository <name>  Repository to operate on (required)
        \\  --session <name>     Session name (create/remove/fix)
        \\  --branch <name>      Base branch for the new session (create only)
        \\  --prefix <name>      Branch prefix, e.g. "feature" (create only)
        \\
        \\add-repo accepts:
        \\  <url>                Clone URL (positional, required)
        \\  --root <path>        Root folder to clone into. When omitted, prompts for confirmation
        \\                       (default = first configured root); pass --yes to accept silently.
        \\  --name <name>        Repository name (defaults to the basename of <url>)
        \\  --branch <name>      Default branch (defaults to "main")
        \\  --prefix <list>      Comma-separated branch prefixes (defaults to the
        \\                       configured default_branch_prefixes list)
        \\  --yes, -y            Skip the root-confirmation prompt
        \\
        \\remove-repo accepts:
        \\  <name>               Repository name to remove (positional, required)
        \\  --yes, -y            Skip the confirmation prompt
        \\
        \\When all required fields are provided the command runs non-interactively.
        \\Omitting optional fields opens the TUI at the step where input is needed.
        \\
    , .{});
}

/// Dispatches `config` sub-commands.
///
/// `args` is the full process argument list (including `argv[0]`).
/// Behaviour depends on the sub-command at `args[2]`:
///   - (none)        — displays the current root folders.
///   - `add-root`    — adds a new root (from `args[3]` or interactive prompt).
///   - `remove-root` — removes an existing root (from `args[3]` or interactive picker).
///
/// Calls `std.process.exit(1)` on unrecognised sub-commands.
pub fn handleConfigCommand(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len == 2) {
        // git-session config  ->  show current config
        var cfg = config.loadAppConfig(allocator, io, env) catch {
            term.print(io, "No configuration found. Run git-session to initialize.\n", .{});
            return;
        };
        defer config.freeAppConfig(allocator, &cfg);

        term.print(io, "Root folders:\n", .{});
        for (cfg.roots.items, 1..) |root, i| {
            term.print(io, "  {d}. {s}\n", .{ i, root });
        }

        term.print(io, "\nDefault branch prefixes:\n", .{});
        if (cfg.default_branch_prefixes.items.len == 0) {
            term.print(io, "  (none)\n", .{});
        } else {
            for (cfg.default_branch_prefixes.items, 1..) |prefix, i| {
                term.print(io, "  {d}. {s}\n", .{ i, prefix });
            }
        }
        return;
    }

    if (args.len >= 3 and std.mem.eql(u8, args[2], "add-root")) {
        if (args.len < 4) {
            term.print(io, "New root folder: ", .{});
            var buf: [1024]u8 = undefined;
            const input = try term.readLine(io, &buf);
            if (input.len == 0) {
                term.eprint(io, "Path cannot be empty.\n", .{});
                std.process.exit(1);
            }
            try addRoot(allocator, io, env, input);
        } else {
            try addRoot(allocator, io, env, args[3]);
        }
        return;
    }

    if (args.len >= 3 and std.mem.eql(u8, args[2], "remove-root")) {
        var cfg = config.loadAppConfig(allocator, io, env) catch {
            term.print(io, "No configuration found.\n", .{});
            return;
        };
        defer config.freeAppConfig(allocator, &cfg);

        if (cfg.roots.items.len <= 1) {
            term.eprint(io, "Cannot remove the last root folder.\n", .{});
            return;
        }

        // Parse the rest of `remove-root`'s arguments: an optional
        // positional path, plus `--yes` / `-y` to skip the
        // "also delete repositories" prompt.
        var assume_yes = false;
        var positional_path: ?[]const u8 = null;
        {
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                const a = args[i];
                if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) {
                    assume_yes = true;
                } else if (std.mem.startsWith(u8, a, "-")) {
                    term.eprint(io, "Unknown flag: {s}\n\n", .{a});
                    printUsage(io);
                    std.process.exit(1);
                } else {
                    if (positional_path != null) {
                        term.eprint(io, "Error: 'config remove-root' takes a single path.\n\n", .{});
                        printUsage(io);
                        std.process.exit(1);
                    }
                    positional_path = a;
                }
            }
        }

        const idx: usize = if (positional_path) |raw_path| blk: {
            const path = try term.expandTilde(allocator, env, raw_path);
            defer allocator.free(path);

            for (cfg.roots.items, 0..) |root, i| {
                if (std.mem.eql(u8, root, path)) break :blk i;
            }

            term.eprint(io, "Root '{s}' not found in configuration.\n", .{path});
            term.eprint(io, "Configured roots:\n", .{});
            for (cfg.roots.items, 1..) |root, n| {
                term.eprint(io, "  {d}. {s}\n", .{ n, root });
            }
            std.process.exit(1);
        } else blk: {
            term.print(io, "\nRoot folders:\n", .{});
            break :blk term.pickFromList(io, cfg.roots.items, "Select root to remove: ") orelse return;
        };

        try removeRootAndOptionallyContents(allocator, io, env, &cfg, idx, assume_yes);
        return;
    }

    term.eprint(io, "Unknown config command: {s}\n\n", .{args[2]});
    printUsage(io);
    std.process.exit(1);
}

/// Adds a new root folder to the application configuration.
///
/// `raw_path` may contain a leading `~` which is expanded to `$HOME`.
/// The directory is created on disk if it does not already exist, and the
/// path is appended to the persisted config. Duplicate entries are
/// detected and reported to the user without adding a duplicate. Calls `std.process.exit(1)` when the
/// directory cannot be created.
pub fn addRoot(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, raw_path: []const u8) !void {
    const path = try term.expandTilde(allocator, env, raw_path);
    defer allocator.free(path);

    std.Io.Dir.cwd().createDirPath(io, path) catch |err| {
        term.eprint(io, "Error creating directory '{s}': {any}\n", .{ path, err });
        std.process.exit(1);
    };

    var cfg = config.loadAppConfig(allocator, io, env) catch blk: {
        var new_cfg = config.AppConfig{ .roots = .empty, .default_branch_prefixes = .empty };
        // Seed the standard prefix template so a config created via
        // `config add-root` (before the first-run wizard ran) still
        // records the default list.
        config.seedStandardPrefixes(allocator, &new_cfg.default_branch_prefixes) catch {};
        break :blk new_cfg;
    };

    // Check for duplicates
    for (cfg.roots.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            term.print(io, "Root '{s}' already exists.\n", .{path});
            config.freeAppConfig(allocator, &cfg);
            return;
        }
    }

    try cfg.roots.append(allocator, try allocator.dupe(u8, path));
    try config.saveAppConfig(allocator, io, env, cfg);
    config.freeAppConfig(allocator, &cfg);
    term.print(io, "Root added: {s}\n", .{path});
}

/// Removes the root at `cfg.roots.items[idx]` from the configuration,
/// optionally also tearing down every git-session repository registered
/// under it.
///
/// When the root has at least one registered repository:
///   - With `assume_yes` true, every repo is removed via
///     `removeRepositoryFully` (kills tmux, deletes the on-disk tree,
///     removes the centralized config file).
///   - With `assume_yes` false, the user is shown the list and prompted
///     `[y/N]`. The default (and pressing `n`/anything else) leaves the
///     repos on disk but still unhooks the root from the configuration.
///
/// Repository teardown is best-effort across the list: a failure on one
/// repo is reported and the loop continues so the user is not left with
/// a half-cleaned state. The config save at the end is unconditional --
/// the root is always unhooked, even if some repo deletions failed.

/// Outcome of trying to remove the root folder itself, mapped to a
/// small enum so the message-classification logic can stay pure (no
/// dependency on `std.fs` errors).
const RootDiskOutcome = enum {
    /// We did not call `deleteDir` (e.g. the user kept registered
    /// repos in place, so the root must stay too).
    not_attempted,
    /// `deleteDir` succeeded -- the folder is gone from disk.
    removed,
    /// `deleteDir` returned `error.DirNotEmpty`: the cascade left
    /// loose files or unrelated subdirectories behind.
    dir_not_empty,
    /// `deleteDir` returned `error.FileNotFound`: the folder was
    /// already missing on disk before we tried.
    file_not_found,
    /// `deleteDir` failed with some other error (already warned
    /// about by the caller).
    other_error,
};

/// User-facing classification of what happened to the root folder
/// after a `config remove-root` invocation. Exists so the final
/// status message accurately reflects on-disk state instead of
/// implying the folder is gone whenever the config was updated.
const RootDiskState = enum {
    /// Folder was removed from disk.
    removed,
    /// Folder kept on disk because registered repos were left in
    /// place (user declined the cascade).
    kept_repos,
    /// Folder kept on disk because it still contains other files
    /// (loose files or unrelated subdirectories) after the cascade.
    kept_other_files,
    /// Folder did not exist on disk to begin with.
    never_existed,
    /// Folder kept on disk because `deleteDir` failed with a non-
    /// expected error (a warning was already printed at the call
    /// site).
    kept_warning,
};

/// Pure mapping from the on-disk outcome to the user-facing state.
/// Extracted so the branchy "did the rmdir succeed and what does
/// that mean?" decision can be unit-tested without touching the
/// filesystem.
fn classifyRootDiskState(outcome: RootDiskOutcome) RootDiskState {
    return switch (outcome) {
        .not_attempted => .kept_repos,
        .removed => .removed,
        .dir_not_empty => .kept_other_files,
        .file_not_found => .never_existed,
        .other_error => .kept_warning,
    };
}

fn removeRootAndOptionallyContents(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: *config.AppConfig,
    idx: usize,
    assume_yes: bool,
) !void {
    const root = cfg.roots.items[idx];

    // Find every registered repo under this single root. We hand
    // `listAllRepositories` a one-element slice so the resulting
    // `RepoEntry.root` fields all point at our `root` (no extra
    // allocation, no per-repo filtering needed).
    //
    // Pass `quiet=true` because the strict-match warnings about repos
    // belonging to *other* configured roots are off-topic in this
    // narrow "what lives under this one root?" question. Those repos
    // are intentionally excluded from the result; warning about them
    // here would mislead the user into thinking the cascade is
    // misbehaving.
    const single_root = [_][]const u8{root};
    var entries = repo.listAllRepositories(allocator, io, env, &single_root, true) catch std.ArrayList(repo.RepoEntry).empty;
    defer repo.freeRepoEntries(allocator, &entries);

    var should_delete_repos = false;
    if (entries.items.len > 0) {
        if (assume_yes) {
            should_delete_repos = true;
        } else {
            term.print(io, "\nThe following repositories live under '{s}':\n", .{root});
            for (entries.items, 1..) |e, n| {
                term.print(io, "  {d}. {s}\n", .{ n, e.name });
            }
            term.print(io, "\nAlso remove these repositories and their tmux sessions? [y/N] ", .{});
            var buf: [8]u8 = undefined;
            const input = term.readLine(io, &buf) catch "";
            should_delete_repos = input.len > 0 and (input[0] == 'y' or input[0] == 'Y');
            if (!should_delete_repos) {
                term.print(io, "Repositories left on disk; only unhooking the root from the configuration.\n", .{});
            }
        }
    }

    if (should_delete_repos) {
        for (entries.items) |entry| {
            const repo_root = std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.root, entry.name }) catch {
                term.eprint(io, "Warning: skipping '{s}' (allocation failure).\n", .{entry.name});
                continue;
            };
            defer allocator.free(repo_root);

            // Snapshot the worktree list now; `removeRepositoryFully`
            // expects it as input. A missing/unreadable repo dir
            // produces an empty list which the helper tolerates.
            var worktrees = repo.listWorktrees(allocator, io, repo_root) catch std.ArrayList([]u8).empty;
            defer {
                for (worktrees.items) |w| allocator.free(w);
                worktrees.deinit(allocator);
            }

            term.print(io, "Removing repository '{s}'...\n", .{entry.name});
            removeRepositoryFully(allocator, io, env, entry.name, entry.root, repo_root, worktrees.items) catch |err| {
                term.eprint(io, "Warning: failed to fully remove '{s}': {any}\n", .{ entry.name, err });
                // Continue so other repos still get cleaned up.
            };
        }
    } else if (entries.items.len > 0) {
        // The user declined the full cascade but we are still unhooking
        // this root from the configuration. The centralized per-repo
        // configs for repos under this root would become orphaned —
        // unreachable by any listing or command — so clean them up now.
        // The on-disk repo folders and worktrees are intentionally left
        // untouched (the user said "no" to deletion).
        for (entries.items) |entry| {
            config.deleteCentralRepoConfig(allocator, io, env, entry.name) catch |err| switch (err) {
                error.NoHome => {},
                else => {
                    term.eprint(io, "Warning: could not remove config for '{s}': {any}\n", .{ entry.name, err });
                },
            };
        }
        term.print(io, "Removed {d} centralized config(s) for repos under this root.\n", .{entries.items.len});
    }

    // Decide whether to try removing the root folder itself.
    //
    // We attempt the `rmdir` whenever there are no registered repos
    // standing in the way -- either the cascade just ran, or there were
    // never any repos to begin with. We never `deleteTree` the root, so
    // loose files / unrelated subdirectories are preserved and reported.
    //
    // When the user kept repos on disk, the root obviously must stay.
    const tried_rmdir = should_delete_repos or entries.items.len == 0;

    // Run the rmdir (when applicable) and classify what happened on
    // disk so the final message can describe it accurately. Without
    // this, users see a flat "Removed root" line and reasonably
    // assume the on-disk folder is gone even when alien files kept
    // it around.
    var outcome: RootDiskOutcome = .not_attempted;
    if (tried_rmdir) {
        if (std.Io.Dir.cwd().deleteDir(io, root)) {
            outcome = .removed;
        } else |err| switch (err) {
            error.DirNotEmpty => outcome = .dir_not_empty,
            error.FileNotFound => outcome = .file_not_found,
            else => {
                term.eprint(io, "Warning: could not remove root folder '{s}': {any}\n", .{ root, err });
                outcome = .other_error;
            },
        }
    }

    const disk_state = classifyRootDiskState(outcome);

    // Final status line. We print BEFORE freeing the config slice that
    // `root` points into, otherwise the path would render as freed
    // memory (use-after-free).
    switch (disk_state) {
        .removed => term.print(io, "Removed root '{s}' (folder removed from disk).\n", .{root}),
        .never_existed => term.print(io, "Removed root '{s}' (folder did not exist on disk).\n", .{root}),
        .kept_repos => term.print(io, "Unhooked root '{s}' from configuration. Folder kept on disk: registered repositories were left in place.\n", .{root}),
        .kept_other_files => term.print(io, "Unhooked root '{s}' from configuration. Folder kept on disk: it still contains other files.\n", .{root}),
        .kept_warning => term.print(io, "Unhooked root '{s}' from configuration. Folder kept on disk (see warning above).\n", .{root}),
    }

    // Unhook the root from the configuration. This always happens --
    // the user asked to remove it, and a stale on-disk situation
    // shouldn't leave an orphan in the config file.
    allocator.free(cfg.roots.items[idx]);
    _ = cfg.roots.orderedRemove(idx);
    try config.saveAppConfig(allocator, io, env, cfg.*);
}

// ---------------------------------------------------------------------------
// Session commands
// ---------------------------------------------------------------------------

/// Resolves the repository entry for `repo_name` from the configured roots.
/// Exits with an error message and code 1 when not found.
fn findRepo(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, app_config: config.AppConfig, repo_name: []const u8) !repo.RepoEntry {
    // Pass `quiet=false`: when the user explicitly named a repo via
    // `--repository <name>`, skipped vanished repos are useful diagnostic
    // signal (e.g. they help explain why the lookup failed).
    var entries = try repo.listAllRepositories(allocator, io, env, app_config.roots.items, false);
    defer repo.freeRepoEntries(allocator, &entries);

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, repo_name)) {
            // Return a copy with an owned name so the list can be freed.
            return repo.RepoEntry{
                .name = try allocator.dupe(u8, entry.name),
                .root = entry.root, // points into app_config.roots, stays valid
            };
        }
    }

    term.eprint(io, "Error: repository '{s}' not found.\n", .{repo_name});
    std.process.exit(1);
}

/// Handles the `create` subcommand.
///
/// Returns `null` when the operation completed non-interactively.
/// Returns a `CliArgs` value when the TUI should be launched; the caller is
/// responsible for calling `tui.runTui` with the returned args.
pub fn handleCreateCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    app_config: config.AppConfig,
    cli_args: CliArgs,
) !?CliArgs {
    const repo_name = cli_args.repository orelse {
        term.eprint(io, "Error: 'create' requires --repository\n\n", .{});
        printUsage(io);
        std.process.exit(1);
    };

    // Validate session name characters when provided.
    if (cli_args.session) |sess| {
        for (sess) |c| {
            if (!validate.isAllowedBranchChar(c)) {
                term.eprint(io, "Error: invalid character '{c}' in session name. {s}\n", .{ c, validate.rejected_char_hint });
                std.process.exit(1);
            }
        }
        if (validate.validateBranchName(sess)) |err| {
            term.eprint(io, "Error: {s}\n", .{validate.validationMessage(err)});
            std.process.exit(1);
        }
    }

    // Load repo.
    const entry = try findRepo(allocator, io, env, app_config, repo_name);
    defer allocator.free(entry.name);

    var selected = (try repo.openRepo(allocator, io, env, entry.root, entry.name)) orelse std.process.exit(1);
    defer repo.freeSelectedRepo(allocator, &selected);

    // Validate --branch against config if config is non-empty.
    if (cli_args.branch) |b| {
        if (selected.config.start_branches.items.len > 0) {
            var ok = false;
            for (selected.config.start_branches.items) |sb| {
                if (std.mem.eql(u8, sb, b)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) {
                term.eprint(io, "Error: branch '{s}' is not in start_branches for '{s}'.\n", .{ b, repo_name });
                term.eprint(io, "Configured branches:", .{});
                for (selected.config.start_branches.items) |sb| term.eprint(io, " {s}", .{sb});
                term.eprint(io, "\n", .{});
                std.process.exit(1);
            }
        }
    }

    // Validate --prefix against config if config is non-empty.
    if (cli_args.prefix) |p| {
        if (selected.config.branch_prefixes.items.len > 0) {
            var ok = false;
            for (selected.config.branch_prefixes.items) |bp| {
                if (std.mem.eql(u8, bp, p)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) {
                term.eprint(io, "Error: prefix '{s}' is not in branch_prefixes for '{s}'.\n", .{ p, repo_name });
                term.eprint(io, "Configured prefixes:", .{});
                for (selected.config.branch_prefixes.items) |bp| term.eprint(io, " {s}", .{bp});
                term.eprint(io, "\n", .{});
                std.process.exit(1);
            }
        }
    }

    // Resolve branch: explicit CLI arg > auto-select if only one configured.
    const resolved_branch: ?[]const u8 = if (cli_args.branch != null)
        cli_args.branch
    else if (selected.config.start_branches.items.len == 0)
        "main"
    else if (selected.config.start_branches.items.len == 1)
        selected.config.start_branches.items[0]
    else
        null; // multiple options — needs user input

    // Resolve prefix: explicit CLI arg > auto-select if only one configured.
    const resolved_prefix: ?[]const u8 = if (cli_args.prefix != null)
        cli_args.prefix
    else if (selected.config.branch_prefixes.items.len == 0)
        ""
    else if (selected.config.branch_prefixes.items.len == 1)
        selected.config.branch_prefixes.items[0]
    else
        null; // multiple options — needs user input

    // Run non-interactively only when every required field is available.
    if (cli_args.session != null and resolved_branch != null and resolved_prefix != null) {
        try runCreateNonInteractive(
            allocator,
            io,
            env,
            selected,
            cli_args.session.?,
            resolved_branch.?,
            resolved_prefix.?,
        );
        return null;
    }

    // Otherwise delegate to the TUI with what we already know.
    // Only pass through user-provided CLI values; auto-resolved values
    // point into `selected.config` which will be freed when this function
    // returns.  The TUI performs its own auto-resolution for configs with
    // zero or one entry.
    return CliArgs{
        .repository = repo_name,
        .operation = .create,
        .session = cli_args.session,
        .branch = cli_args.branch,
        .prefix = cli_args.prefix,
    };
}

/// Handles the `remove` subcommand.
///
/// Returns `null` when the operation completed non-interactively.
/// Returns `CliArgs` when the TUI should be launched.
pub fn handleRemoveCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    app_config: config.AppConfig,
    cli_args: CliArgs,
) !?CliArgs {
    const repo_name = cli_args.repository orelse {
        term.eprint(io, "Error: 'remove' requires --repository\n\n", .{});
        printUsage(io);
        std.process.exit(1);
    };

    if (cli_args.session) |session_name| {
        const entry = try findRepo(allocator, io, env, app_config, repo_name);
        defer allocator.free(entry.name);

        var selected = (try repo.openRepo(allocator, io, env, entry.root, entry.name)) orelse std.process.exit(1);
        defer repo.freeSelectedRepo(allocator, &selected);

        try runRemoveNonInteractive(allocator, io, env, selected, session_name);
        return null;
    }

    // No session provided — open TUI at the remove-session screen.
    return CliArgs{
        .repository = repo_name,
        .operation = .remove,
        .session = null,
    };
}

/// Handles the `fix` subcommand.
///
/// Returns `null` when the operation completed non-interactively.
/// Returns `CliArgs` when the TUI should be launched.
pub fn handleFixCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    app_config: config.AppConfig,
    cli_args: CliArgs,
) !?CliArgs {
    const repo_name = cli_args.repository orelse {
        term.eprint(io, "Error: 'fix' requires --repository\n\n", .{});
        printUsage(io);
        std.process.exit(1);
    };

    if (cli_args.session) |session_name| {
        const entry = try findRepo(allocator, io, env, app_config, repo_name);
        defer allocator.free(entry.name);

        var selected = (try repo.openRepo(allocator, io, env, entry.root, entry.name)) orelse std.process.exit(1);
        defer repo.freeSelectedRepo(allocator, &selected);

        try runFixNonInteractive(allocator, io, env, selected, session_name);
        return null;
    }

    // No session provided — open TUI at the fix-session screen.
    return CliArgs{
        .repository = repo_name,
        .operation = .fix,
        .session = null,
    };
}

// ---------------------------------------------------------------------------
// Non-interactive operation implementations
// ---------------------------------------------------------------------------

/// Runs the full session-creation flow without TUI interaction.
///
/// Creates a git worktree, saves session metadata, and creates the tmux
/// session. Offers to attach when running inside tmux; otherwise prints
/// the attach command.
fn runCreateNonInteractive(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    selected: repo.SelectedRepo,
    session_name: []const u8,
    base_branch: []const u8,
    prefix: []const u8,
) !void {
    // Build branch name: "<prefix>/<session>" or just "<session>".
    var branch_name_buf: [512]u8 = undefined;
    const branch_name = if (prefix.len > 0)
        std.fmt.bufPrint(&branch_name_buf, "{s}/{s}", .{ prefix, session_name }) catch {
            term.eprint(io, "Error: branch name too long.\n", .{});
            std.process.exit(1);
        }
    else
        session_name;

    const bare_repo_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.git",
        .{ selected.root, selected.config.bare_repo },
    );
    defer allocator.free(bare_repo_path);

    // Guard against duplicate branches.
    if (git.gitBranchExists(allocator, io, bare_repo_path, branch_name)) {
        term.eprint(io, "Error: branch '{s}' already exists.\n", .{branch_name});
        std.process.exit(1);
    }

    // Create the worktree (fetches the base branch first).
    term.print(io, "Creating session '{s}' from '{s}'...\n", .{ session_name, base_branch });
    git.gitCreateWorktree(
        allocator,
        io,
        selected.root,
        selected.config.bare_repo,
        session_name,
        branch_name,
        base_branch,
    ) catch {
        term.eprint(io, "Error: failed to create worktree.\n", .{});
        std.process.exit(1);
    };

    // Persist session metadata.
    repo.saveSessionFile(allocator, io, base_branch, branch_name, bare_repo_path, session_name) catch {
        term.eprint(io, "Error: failed to save session file.\n", .{});
        std.process.exit(1);
    };

    // Create tmux session; roll back on failure.
    const wt_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ selected.root, session_name });
    defer allocator.free(wt_path);

    const tmux_name = try tmux.tmuxSessionName(allocator, session_name, branch_name, selected.name);
    defer allocator.free(tmux_name);

    tmux.tmuxCreateSession(allocator, io, tmux_name, wt_path, selected.config.windows.items) catch {
        _ = git.gitRemoveWorktree(allocator, io, bare_repo_path, session_name) catch {};
        repo.deleteSessionFile(allocator, io, bare_repo_path, session_name);
        term.eprint(io, "Error: failed to create tmux session.\n", .{});
        std.process.exit(1);
    };

    term.print(io, "Session '{s}' created.\n", .{session_name});
    offerAttach(allocator, io, env, tmux_name);
}

/// Runs the full session-removal flow without TUI interaction.
///
/// Verifies the session exists, resolves its branch, switches away from
/// the tmux session if it is currently active, removes the worktree,
/// deletes the session file, deletes the branch, and kills the tmux
/// session as the very last step.
fn runRemoveNonInteractive(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    selected: repo.SelectedRepo,
    session_name: []const u8,
) !void {
    // Verify the session worktree exists.
    var worktrees = try repo.listWorktrees(allocator, io, selected.root);
    defer {
        for (worktrees.items) |w| allocator.free(w);
        worktrees.deinit(allocator);
    }

    var found = false;
    for (worktrees.items) |wt| {
        if (std.mem.eql(u8, wt, session_name)) {
            found = true;
            break;
        }
    }
    if (!found) {
        term.eprint(io, "Error: session '{s}' not found in repository '{s}'.\n", .{ session_name, selected.name });
        term.eprint(io, "Available sessions:", .{});
        for (worktrees.items) |wt| term.eprint(io, " {s}", .{wt});
        term.eprint(io, "\n", .{});
        std.process.exit(1);
    }

    const bare_repo_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.git",
        .{ selected.root, selected.config.bare_repo },
    );
    defer allocator.free(bare_repo_path);

    // Resolve branch name from the session file or git.
    // Only tolerate a missing file; propagate real I/O errors.
    const info = repo.parseSessionFile(allocator, io, bare_repo_path, session_name) catch |err| switch (err) {
        error.SessionInfoNotFound => repo.SessionInfo{ .branch = "", .branch_name = "" },
        else => return err,
    };
    defer {
        if (info.branch.len > 0) allocator.free(info.branch);
        if (info.branch_name.len > 0) allocator.free(info.branch_name);
    }

    const branch_name: ?[]const u8 = if (info.branch_name.len > 0)
        allocator.dupe(u8, info.branch_name) catch null
    else blk: {
        const wt_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ selected.root, session_name }) catch break :blk null;
        defer allocator.free(wt_path);
        break :blk git.gitWorktreeBranch(allocator, io, wt_path);
    };
    defer if (branch_name) |bn| allocator.free(bn);

    const tmux_name: ?[]const u8 = if (branch_name) |bn|
        tmux.tmuxSessionName(allocator, session_name, bn, selected.name) catch null
    else
        null;
    defer if (tmux_name) |tn| allocator.free(tn);

    // Switch away from the session being removed so we're not killed mid-cleanup.
    if (tmux_name) |tn| tmux.tmuxSwitchAwayIfCurrent(allocator, io, env, tn);

    // Kill the tmux session as the very last step (deferred).
    defer {
        if (tmux_name) |tn| {
            if (tmux.tmuxSessionExists(allocator, io, tn)) {
                tmux.tmuxKillSession(allocator, io, tn) catch {};
            }
        }
    }

    // Give processes inside the session a moment to release the directory.
    if (tmux_name) |tn| {
        if (tmux.tmuxSessionExists(allocator, io, tn)) {
            tmux.tmuxSendExitToAllPanes(allocator, io, tn);
            var attempts: u8 = 0;
            while (attempts < 10) : (attempts += 1) {
                if (!tmux.tmuxSessionExists(allocator, io, tn)) break;
                io.sleep(.fromMilliseconds(50), .awake) catch {};
            }
        }
    }

    // Remove the git worktree.
    const wt_err = git.gitRemoveWorktree(allocator, io, bare_repo_path, session_name) catch {
        term.eprint(io, "Error: failed to remove worktree.\n", .{});
        std.process.exit(1);
    };
    if (wt_err) |err_msg| {
        defer allocator.free(err_msg);
        term.eprint(io, "Error: {s}\n", .{err_msg});
        std.process.exit(1);
    }

    // Clean up metadata and branch.
    repo.deleteSessionFile(allocator, io, bare_repo_path, session_name);

    if (branch_name) |bn| {
        git.gitDeleteBranch(allocator, io, bare_repo_path, bn) catch {
            term.eprint(io, "Warning: could not delete branch '{s}'.\n", .{bn});
        };
    }

    term.print(io, "Session '{s}' removed.\n", .{session_name});
}

/// Handles the `remove-repo` subcommand.
///
/// Always runs non-interactively (the TUI has its own remove-repo flow,
/// triggered by the `D` key on a selected repository in the main menu).
/// `repo_name` is the positional argument; when `assume_yes` is false a
/// confirmation prompt is shown on stdin.
pub fn handleRemoveRepoCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    app_config: config.AppConfig,
    repo_name: []const u8,
    assume_yes: bool,
) !void {
    const entry = try findRepo(allocator, io, env, app_config, repo_name);
    defer allocator.free(entry.name);

    // Count sessions so the user knows what they're about to delete.
    const repo_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.root, entry.name });
    defer allocator.free(repo_root);

    var worktrees = repo.listWorktrees(allocator, io, repo_root) catch std.ArrayList([]u8).empty;
    defer {
        for (worktrees.items) |w| allocator.free(w);
        worktrees.deinit(allocator);
    }
    const session_count = worktrees.items.len;

    if (!assume_yes) {
        term.print(io, "\nThis will permanently delete:\n", .{});
        term.print(io, "  Repository: {s}\n", .{entry.name});
        term.print(io, "  Location:   {s}\n", .{repo_root});
        term.print(io, "  Sessions:   {d}\n", .{session_count});
        if (session_count > 0) {
            for (worktrees.items) |wt| term.print(io, "    - {s}\n", .{wt});
        }
        term.print(io, "  Config:     ~/.config/git-session/repos/{s}.toml (if present)\n", .{entry.name});
        term.print(io, "\nType 'yes' to confirm: ", .{});

        var buf: [16]u8 = undefined;
        const input = term.readLine(io, &buf) catch "";
        if (!std.mem.eql(u8, input, "yes")) {
            term.print(io, "Aborted.\n", .{});
            return;
        }
    }

    try removeRepositoryFully(allocator, io, env, entry.name, entry.root, repo_root, worktrees.items);

    term.print(io, "Repository '{s}' removed.\n", .{entry.name});
}

/// Handles the `add-repo` subcommand.
///
/// Required: `url` (positional). When `root_arg` is null and `assume_yes`
/// is false, an interactive numbered picker is shown so the user can
/// confirm or pick a different root (default = first configured root).
/// When `assume_yes` is true and `root_arg` is null, the first configured
/// root is used silently. `name`, `branch`, and `prefix` fall back to
/// sensible defaults (basename of `url`, `"main"`, and the configured
/// `default_branch_prefixes` list respectively).
///
/// On success the repository is cloned into `<root>/<name>/<name>.git`
/// (configured as a bare repository so worktrees can be added next to
/// it) and a generated TOML is written to
/// `~/.config/git-session/repos/<name>.toml`.
pub fn handleAddRepoCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    app_config: config.AppConfig,
    url: []const u8,
    root_arg: ?[]const u8,
    name_arg: ?[]const u8,
    branch_arg: ?[]const u8,
    prefix_arg: ?[]const u8,
    assume_yes: bool,
) !void {
    if (url.len == 0) {
        term.eprint(io, "Error: 'add-repo' requires a clone URL.\n\n", .{});
        printUsage(io);
        std.process.exit(1);
    }

    // Defensive guard: every other branch below assumes at least one
    // configured root (the picker asserts it; the --yes branch indexes
    // [0] directly). `main.zig` arranges this via `runInitFlow`, but
    // surface a clear error if a future caller hands us an empty list.
    if (app_config.roots.items.len == 0) {
        term.eprint(io, "Error: no root folders configured. Run `git-session config add-root <path>` first.\n", .{});
        std.process.exit(1);
    }

    // Resolve the target root. When the user passes a `--root` that is
    // not yet in the configuration, we offer to register it (via
    // `addRoot`) and continue with the new path. In that case the
    // chosen root is heap-allocated and stored in `owned_root` so it
    // outlives the resolution block.
    var owned_root: ?[]u8 = null;
    defer if (owned_root) |o| allocator.free(o);

    const root: []const u8 = if (root_arg) |r| blk: {
        // Match the user-provided path against the configured roots
        // (after `~` expansion) so that typos are caught before any
        // network or filesystem work happens.
        const expanded = try term.expandTilde(allocator, env, r);

        for (app_config.roots.items) |configured| {
            if (std.mem.eql(u8, configured, expanded)) {
                allocator.free(expanded);
                break :blk configured;
            }
        }

        // Not in the configuration. Offer to register it on the spot
        // (or do so silently with --yes); otherwise abort with the same
        // listing the previous behaviour produced.
        if (!assume_yes) {
            term.print(io, "\nRoot '{s}' is not in your configuration.\n", .{expanded});
            term.print(io, "Configured roots:\n", .{});
            for (app_config.roots.items, 1..) |c, i| {
                term.print(io, "  {d}. {s}\n", .{ i, c });
            }
            term.print(io, "Add this root to your configuration? [Y/n] ", .{});

            var buf: [8]u8 = undefined;
            const input = term.readLine(io, &buf) catch "";
            const accepted = input.len == 0 or input[0] == 'y' or input[0] == 'Y';
            if (!accepted) {
                allocator.free(expanded);
                term.print(io, "Aborted.\n", .{});
                std.process.exit(0);
            }
        }

        // Register the new root (creates the directory if missing and
        // persists the global config). `addRoot` re-expands `~` itself,
        // so we hand it the original `r`.
        try addRoot(allocator, io, env, r);

        // Take ownership of the expanded path so it outlives this
        // block; the in-memory `app_config` we received is now stale
        // but we don't iterate it again.
        owned_root = expanded;
        break :blk expanded;
    } else blk: {
        // No --root: use the first configured root, but ask the user to
        // confirm (or pick a different one) unless --yes was passed.
        // The empty-roots case is rejected by the guard at the top of
        // this function, so indexing [0] here is safe.
        if (assume_yes) break :blk app_config.roots.items[0];

        term.print(io, "\nRoot folder:\n", .{});
        const idx = term.pickFromListWithDefault(
            io,
            app_config.roots.items,
            "Select root [Enter for default]: ",
            0,
        ) orelse {
            term.eprint(io, "Error: invalid selection.\n", .{});
            std.process.exit(1);
        };
        break :blk app_config.roots.items[idx];
    };

    // Resolve the repository name (defaults to the basename of the URL).
    const repo_name: []const u8 = if (name_arg) |n| n else git.deriveRepoName(url);
    if (repo_name.len == 0) {
        term.eprint(io, "Error: could not derive a repository name from '{s}'. Pass --name explicitly.\n", .{url});
        std.process.exit(1);
    }

    // Refuse to clobber an existing directory at <root>/<name>. This is
    // intentionally strict -- the user can pass --name to disambiguate
    // or remove the existing directory first.
    const repo_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, repo_name });
    defer allocator.free(repo_dir);

    if (repo.dirExists(io, repo_dir)) {
        term.eprint(io, "Error: '{s}' already exists. Refusing to overwrite.\n", .{repo_dir});
        std.process.exit(1);
    }

    const default_branch: []const u8 = branch_arg orelse "main";

    // When --prefix is omitted, fall back to the configured default
    // branch-prefix list (seeded from the standard list when config.toml
    // does not specify one). `default_prefixes_csv` is owned here.
    const default_prefixes_csv: ?[]u8 = if (prefix_arg == null)
        try config.joinPrefixesCsv(allocator, app_config.default_branch_prefixes.items)
    else
        null;
    defer if (default_prefixes_csv) |c| allocator.free(c);

    const prefixes_raw: []const u8 = prefix_arg orelse (default_prefixes_csv orelse "");

    // Create the parent directory before cloning so a missing root
    // folder produces a clear error rather than a confusing git failure.
    std.Io.Dir.cwd().createDirPath(io, repo_dir) catch |err| {
        term.eprint(io, "Error creating directory '{s}': {any}\n", .{ repo_dir, err });
        std.process.exit(1);
    };

    // Note: `gitCloneForSession` itself prints `Cloning '<url>' ...`,
    // so we only announce the destination here to avoid repeating the URL.
    term.print(io, "Destination: {s}\n", .{repo_dir});
    git.gitCloneForSession(allocator, io, url, repo_dir, repo_name) catch {
        // Roll back the directory we just created so the user can retry
        // without first cleaning up a half-finished clone.
        std.Io.Dir.cwd().deleteTree(io, repo_dir) catch {};
        term.eprint(io, "Error: clone failed.\n", .{});
        std.process.exit(1);
    };

    // Build the centralized TOML and persist it. `url` and `root` are
    // recorded as recovery metadata so that `repo.ensureBareRepo` can
    // re-clone if the user accidentally deletes the bare repository
    // (or its parent folders) later.
    const toml_content = config.generateRepoConfigToml(allocator, repo_name, default_branch, prefixes_raw, url, root) catch {
        term.eprint(io, "Error: failed to generate repository config.\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(toml_content);

    config.writeCentralRepoConfig(allocator, io, env, repo_name, toml_content) catch |err| {
        const msg = switch (err) {
            error.NoHome => "Error writing config: HOME is not set",
            else => "Error writing config",
        };
        term.eprint(io, "{s}\n", .{msg});
        std.process.exit(1);
    };

    term.print(io, "Repository '{s}' added at {s}.\n", .{ repo_name, repo_dir });
}

/// Performs the full repository removal: kills every tmux session for
/// the repo, deletes the on-disk directory tree, and removes the
/// centralized config file. Best-effort: tmux failures are tolerated
/// (the session may not exist), but filesystem failures propagate.
///
/// Used by both `handleRemoveRepoCommand` (single-repo CLI flow) and
/// `handleConfigCommand` (when `remove-root` cascades into deleting
/// every repository under the doomed root).
pub fn removeRepositoryFully(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    repo_name: []const u8,
    root: []const u8,
    repo_root: []const u8,
    worktrees: []const []u8,
) !void {
    // Kill any tmux sessions associated with the repo. We need the
    // bare repo name from the repo's config to compute tmux names, but
    // if loading fails we fall back to using `repo_name` itself which
    // is the conventional bare repo name.
    var bare_repo_name_owned: ?[]u8 = null;
    defer if (bare_repo_name_owned) |b| allocator.free(b);

    const cfg_result = repo.loadRepoConfig(allocator, io, env, repo_root);
    if (cfg_result) |loaded_cfg| {
        var cfg = loaded_cfg;
        defer repo.freeRepoConfig(allocator, &cfg);
        if (cfg.bare_repo.len > 0) {
            bare_repo_name_owned = try allocator.dupe(u8, cfg.bare_repo);
        }
    } else |_| {}

    const bare_repo_name = bare_repo_name_owned orelse repo_name;
    const bare_repo_path = try std.fmt.allocPrint(allocator, "{s}/{s}.git", .{ repo_root, bare_repo_name });
    defer allocator.free(bare_repo_path);

    for (worktrees) |session_name| {
        // Resolve the branch name to compute the tmux session name.
        const info = repo.parseSessionFile(allocator, io, bare_repo_path, session_name) catch
            repo.SessionInfo{ .branch = "", .branch_name = "" };
        defer {
            if (info.branch.len > 0) allocator.free(info.branch);
            if (info.branch_name.len > 0) allocator.free(info.branch_name);
        }

        const branch_name: ?[]const u8 = if (info.branch_name.len > 0)
            allocator.dupe(u8, info.branch_name) catch null
        else blk: {
            const wt_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, session_name }) catch break :blk null;
            defer allocator.free(wt_path);
            break :blk git.gitWorktreeBranch(allocator, io, wt_path);
        };
        defer if (branch_name) |bn| allocator.free(bn);

        const tmux_name: ?[]u8 = if (branch_name) |bn|
            tmux.tmuxSessionName(allocator, session_name, bn, repo_name) catch null
        else
            null;
        defer if (tmux_name) |tn| allocator.free(tn);

        if (tmux_name) |tn| {
            // Switch the user away if they happen to be inside this
            // session, then ask processes to exit before we kill it.
            tmux.tmuxSwitchAwayIfCurrent(allocator, io, env, tn);
            if (tmux.tmuxSessionExists(allocator, io, tn)) {
                tmux.tmuxSendExitToAllPanes(allocator, io, tn);
                var attempts: u8 = 0;
                while (attempts < 10) : (attempts += 1) {
                    if (!tmux.tmuxSessionExists(allocator, io, tn)) break;
                    io.sleep(.fromMilliseconds(50), .awake) catch {};
                }
                if (tmux.tmuxSessionExists(allocator, io, tn)) {
                    tmux.tmuxKillSession(allocator, io, tn) catch {};
                }
            }
        }
    }

    // Delete the on-disk repository tree (bare repo + every worktree).
    try repo.removeRepositoryDirectory(allocator, io, root, repo_name);

    // Delete the centralized config file (best-effort: a missing HOME
    // is the only error worth surfacing, and even then a missing config
    // is fine).
    config.deleteCentralRepoConfig(allocator, io, env, repo_name) catch |err| switch (err) {
        error.NoHome => {},
        else => return err,
    };
}

/// Runs the full session-fix flow without TUI interaction.
///
/// Recreates the tmux session for an existing worktree and offers to
/// attach when running inside tmux.
fn runFixNonInteractive(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    selected: repo.SelectedRepo,
    session_name: []const u8,
) !void {
    // Verify the session worktree exists.
    var worktrees = try repo.listWorktrees(allocator, io, selected.root);
    defer {
        for (worktrees.items) |w| allocator.free(w);
        worktrees.deinit(allocator);
    }

    var found = false;
    for (worktrees.items) |wt| {
        if (std.mem.eql(u8, wt, session_name)) {
            found = true;
            break;
        }
    }
    if (!found) {
        term.eprint(io, "Error: session '{s}' not found in repository '{s}'.\n", .{ session_name, selected.name });
        term.eprint(io, "Available sessions:", .{});
        for (worktrees.items) |wt| term.eprint(io, " {s}", .{wt});
        term.eprint(io, "\n", .{});
        std.process.exit(1);
    }

    const wt_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ selected.root, session_name });
    defer allocator.free(wt_path);

    const bare_repo_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.git",
        .{ selected.root, selected.config.bare_repo },
    );
    defer allocator.free(bare_repo_path);

    // Resolve branch from session file, or fall back to git.
    // Only tolerate a missing file; propagate real I/O errors.
    const info = repo.parseSessionFile(allocator, io, bare_repo_path, session_name) catch |err| switch (err) {
        error.SessionInfoNotFound => repo.SessionInfo{ .branch = "", .branch_name = "" },
        else => return err,
    };
    defer {
        if (info.branch.len > 0) allocator.free(info.branch);
        if (info.branch_name.len > 0) allocator.free(info.branch_name);
    }

    const git_branch: ?[]const u8 = if (info.branch_name.len == 0 and info.branch.len == 0)
        git.gitWorktreeBranch(allocator, io, wt_path)
    else
        null;
    defer if (git_branch) |gb| allocator.free(gb);

    const branch_for_name: []const u8 = if (info.branch_name.len > 0)
        info.branch_name
    else if (info.branch.len > 0)
        info.branch
    else
        git_branch orelse {
            term.eprint(io, "Error: could not determine branch for session '{s}'.\n", .{session_name});
            std.process.exit(1);
        };

    const tmux_name = try tmux.tmuxSessionName(allocator, session_name, branch_for_name, selected.name);
    defer allocator.free(tmux_name);

    term.print(io, "Recreating tmux session for '{s}'...\n", .{session_name});
    tmux.tmuxCreateSession(allocator, io, tmux_name, wt_path, selected.config.windows.items) catch {
        term.eprint(io, "Error: failed to create tmux session.\n", .{});
        std.process.exit(1);
    };

    term.print(io, "Session '{s}' fixed.\n", .{session_name});
    offerAttach(allocator, io, env, tmux_name);
}

/// Offers to attach to `tmux_name` when running inside a tmux server.
/// When not inside tmux, prints the attach command instead.
fn offerAttach(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, tmux_name: []const u8) void {
    if (tmux.isInsideTmux(env)) {
        term.print(io, "Attach to session? [Y/n] ", .{});
        var buf: [8]u8 = undefined;
        const input = term.readLine(io, &buf) catch "";
        if (input.len == 0 or input[0] == 'y' or input[0] == 'Y') {
            tmux.tmuxAttachOrSwitch(allocator, io, env, tmux_name) catch {};
        }
    } else {
        term.print(io, "To connect: tmux attach -t '{s}'\n", .{tmux_name});
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "classifyRootDiskState: not_attempted -> kept_repos" {
    try testing.expectEqual(RootDiskState.kept_repos, classifyRootDiskState(.not_attempted));
}

test "classifyRootDiskState: removed -> removed" {
    try testing.expectEqual(RootDiskState.removed, classifyRootDiskState(.removed));
}

test "classifyRootDiskState: dir_not_empty -> kept_other_files" {
    try testing.expectEqual(RootDiskState.kept_other_files, classifyRootDiskState(.dir_not_empty));
}

test "classifyRootDiskState: file_not_found -> never_existed" {
    try testing.expectEqual(RootDiskState.never_existed, classifyRootDiskState(.file_not_found));
}

test "classifyRootDiskState: other_error -> kept_warning" {
    try testing.expectEqual(RootDiskState.kept_warning, classifyRootDiskState(.other_error));
}

test "classifyRootDiskState: every outcome maps to a unique state" {
    // Pin the mapping so a future refactor doesn't accidentally make
    // two outcomes produce the same user-facing message.
    const outcomes = [_]RootDiskOutcome{
        .not_attempted,
        .removed,
        .dir_not_empty,
        .file_not_found,
        .other_error,
    };
    var seen: [outcomes.len]RootDiskState = undefined;
    for (outcomes, 0..) |o, i| seen[i] = classifyRootDiskState(o);

    var i: usize = 0;
    while (i < seen.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < seen.len) : (j += 1) {
            try testing.expect(seen[i] != seen[j]);
        }
    }
}


