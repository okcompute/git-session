const std = @import("std");
const term = @import("term.zig");
const config = @import("config.zig");
const git = @import("git.zig");

// ---------------------------------------------------------------------------
// Per-repository configuration (.git-session.toml)
// ---------------------------------------------------------------------------

pub const repo_config_filename = ".git-session.toml";

/// Describes a single tmux window to create when starting a session.
pub const WindowConfig = struct {
    name: []const u8,
    commands: std.ArrayList([]const u8), // empty = just open a shell
};

/// Per-repository configuration loaded from `.git-session.toml`.
///
/// `origin_url` and `root` are recovery metadata that are only present
/// (and only meaningful) when the configuration lives in the centralized
/// location (`~/.config/git-session/repos/<name>.toml`). They allow
/// `ensureBareRepo` to re-clone the bare repository if the user has
/// accidentally deleted it (or its parent repo/root folders). Both
/// fields default to the empty string when absent.
pub const RepoConfig = struct {
    bare_repo: []const u8,
    start_branches: std.ArrayList([]const u8),
    branch_prefixes: std.ArrayList([]const u8),
    windows: std.ArrayList(WindowConfig),
    origin_url: []const u8 = "",
    root: []const u8 = "",
};

/// Reads and parses a `.git-session.toml`-format file at the given absolute
/// path. Returns `error.ConfigNotFound` when the file does not exist.
/// All strings in the returned `RepoConfig` are heap-allocated; release them
/// with `freeRepoConfig`.
fn parseRepoConfigFile(allocator: std.mem.Allocator, io: std.Io, filepath: []const u8) !RepoConfig {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, filepath, allocator, .limited(16 * 1024)) catch {
        return error.ConfigNotFound;
    };
    defer allocator.free(contents);

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = "",
        .root = "",
    };

    // Track whether we're inside a [[window]] section
    var in_window = false;
    var cur_win_name: []const u8 = "";
    var cur_win_cmds: std.ArrayList([]const u8) = .empty;

    // Track whether we're inside a triple-quoted multi-line string for `command`
    var in_multiline_cmd = false;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        // When collecting multi-line command lines, preserve content but trim \r
        if (in_multiline_cmd) {
            const ml_line = std.mem.trimEnd(u8, raw_line, "\r");
            // Check for closing triple quotes (must be on its own line)
            const trimmed = std.mem.trim(u8, ml_line, " \t");
            if (std.mem.eql(u8, trimmed, "\"\"\"")) {
                in_multiline_cmd = false;
                continue;
            }
            // Add non-empty lines as individual commands
            if (trimmed.len > 0) {
                try cur_win_cmds.append(allocator, try allocator.dupe(u8, trimmed));
            }
            continue;
        }

        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Check for [[window]] header
        if (std.mem.eql(u8, line, "[[window]]")) {
            // Finalize previous window if any
            if (in_window) {
                try cfg.windows.append(allocator, .{
                    .name = cur_win_name,
                    .commands = cur_win_cmds,
                });
            }
            in_window = true;
            cur_win_name = "";
            cur_win_cmds = .empty;
            continue;
        }

        if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
            const key = std.mem.trim(u8, line[0..eq_pos], " \t");
            const value_raw = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

            if (in_window) {
                // Parse window fields
                if (std.mem.eql(u8, key, "name")) {
                    cur_win_name = try allocator.dupe(u8, config.stripQuotes(value_raw));
                } else if (std.mem.eql(u8, key, "command")) {
                    // Check for triple-quoted multi-line string
                    if (std.mem.startsWith(u8, value_raw, "\"\"\"")) {
                        const after_quotes = std.mem.trim(u8, value_raw[3..], " \t");
                        if (after_quotes.len > 0 and std.mem.endsWith(u8, after_quotes, "\"\"\"")) {
                            // Single-line triple-quoted: command = """something"""
                            const inner = after_quotes[0 .. after_quotes.len - 3];
                            const trimmed_inner = std.mem.trim(u8, inner, " \t");
                            if (trimmed_inner.len > 0) {
                                try cur_win_cmds.append(allocator, try allocator.dupe(u8, trimmed_inner));
                            }
                        } else {
                            // Start of multi-line: command = """
                            in_multiline_cmd = true;
                            // If there's content after """ on the same line, capture it
                            if (after_quotes.len > 0) {
                                try cur_win_cmds.append(allocator, try allocator.dupe(u8, after_quotes));
                            }
                        }
                    } else {
                        // Single command: command = "vim"
                        const cmd = config.stripQuotes(value_raw);
                        if (cmd.len > 0) {
                            try cur_win_cmds.append(allocator, try allocator.dupe(u8, cmd));
                        }
                    }
                }
            } else {
                // Parse top-level fields
                if (std.mem.eql(u8, key, "bare_repo")) {
                    cfg.bare_repo = try allocator.dupe(u8, config.stripQuotes(value_raw));
                } else if (std.mem.eql(u8, key, "start_branches")) {
                    cfg.start_branches = try config.parseTomlArray(allocator, value_raw);
                } else if (std.mem.eql(u8, key, "branch_prefixes")) {
                    cfg.branch_prefixes = try config.parseTomlArray(allocator, value_raw);
                } else if (std.mem.eql(u8, key, "origin_url")) {
                    cfg.origin_url = try allocator.dupe(u8, config.stripQuotes(value_raw));
                } else if (std.mem.eql(u8, key, "root")) {
                    cfg.root = try allocator.dupe(u8, config.stripQuotes(value_raw));
                }
            }
        }
    }

    // Finalize last window if any
    if (in_window) {
        try cfg.windows.append(allocator, .{
            .name = cur_win_name,
            .commands = cur_win_cmds,
        });
    }

    return cfg;
}

/// Loads only the centralized per-repo config for `repo_name` from
/// `~/.config/git-session/repos/<repo_name>.toml`. Returns
/// `error.ConfigNotFound` when the file does not exist or is empty,
/// and `error.NoHome` when `HOME` is unset. The returned config must be
/// released with `freeRepoConfig`.
///
/// Used by `listAllRepositories` to discover repositories whose on-disk
/// folder has been deleted (so that recovery via `ensureBareRepo` is
/// reachable through the normal listing).
pub fn loadCentralRepoConfig(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, repo_name: []const u8) !RepoConfig {
    const central_path = try config.getCentralRepoConfigPath(allocator, env, repo_name);
    defer allocator.free(central_path);
    return parseRepoConfigFile(allocator, io, central_path);
}

/// Attempts `central_path` first; falls back to `local_path`.
/// Returns `error.ConfigNotFound` when neither file exists.
fn loadRepoConfigFromPaths(allocator: std.mem.Allocator, io: std.Io, central_path: []const u8, local_path: []const u8) !RepoConfig {
    if (parseRepoConfigFile(allocator, io, central_path)) |cfg| return cfg else |_| {}
    return parseRepoConfigFile(allocator, io, local_path);
}

/// Loads and parses the per-repository configuration for the repository at
/// `repo_root`.
///
/// Lookup order (first match wins):
///   1. `~/.config/git-session/repos/<repo-name>.toml` (central / dotfiles)
///   2. `<repo_root>/.git-session.toml` (per-repository fallback)
///
/// Returns `error.ConfigNotFound` when neither file exists. All strings in
/// the returned `RepoConfig` are heap-allocated; release them with
/// `freeRepoConfig`.
pub fn loadRepoConfig(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, repo_root: []const u8) !RepoConfig {
    const repo_name = std.fs.path.basename(repo_root);

    const local_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ repo_root, repo_config_filename },
    );
    defer allocator.free(local_path);

    const central_path = config.getCentralRepoConfigPath(allocator, env, repo_name) catch {
        // HOME not set — skip central lookup, go straight to local.
        return parseRepoConfigFile(allocator, io, local_path);
    };
    defer allocator.free(central_path);

    return loadRepoConfigFromPaths(allocator, io, central_path, local_path);
}

/// Frees all heap-allocated strings and deinitialises the `ArrayList`s
/// inside a `RepoConfig`. The struct should not be used after this call.
pub fn freeRepoConfig(allocator: std.mem.Allocator, cfg: *RepoConfig) void {
    if (cfg.bare_repo.len > 0) allocator.free(cfg.bare_repo);
    for (cfg.start_branches.items) |s| allocator.free(s);
    cfg.start_branches.deinit(allocator);
    for (cfg.branch_prefixes.items) |s| allocator.free(s);
    cfg.branch_prefixes.deinit(allocator);
    for (cfg.windows.items) |*w| {
        if (w.name.len > 0) allocator.free(w.name);
        for (w.commands.items) |cmd| allocator.free(cmd);
        w.commands.deinit(allocator);
    }
    cfg.windows.deinit(allocator);
    if (cfg.origin_url.len > 0) allocator.free(cfg.origin_url);
    if (cfg.root.len > 0) allocator.free(cfg.root);
}

// ---------------------------------------------------------------------------
// Session metadata
// ---------------------------------------------------------------------------
// Session metadata is stored *outside* the worktree so that it never
// pollutes the user's working tree. The files live under a `git-session`
// directory inside the bare repository:
//
//   <bare-repo-path>/git-session/<worktree-name>.session
// ---------------------------------------------------------------------------

/// Metadata persisted in the session file inside the bare repo,
/// recording the base branch and full branch name.
pub const SessionInfo = struct {
    branch: []const u8,
    branch_name: []const u8,
};

const session_dir_name = "git-session";

/// Builds the path `<bare_repo_path>/git-session/<worktree_name>.session`.
fn sessionFilePath(allocator: std.mem.Allocator, bare_repo_path: []const u8, worktree_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}.session", .{ bare_repo_path, session_dir_name, worktree_name });
}

/// Reads the session metadata for `worktree_name` stored inside
/// `bare_repo_path`.
///
/// Returns `error.SessionInfoNotFound` when the file does not exist.
/// Both strings in the returned `SessionInfo` are heap-allocated; the
/// caller must free them when done.
pub fn parseSessionFile(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8, worktree_name: []const u8) !SessionInfo {
    const filepath = try sessionFilePath(allocator, bare_repo_path, worktree_name);
    defer allocator.free(filepath);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, filepath, allocator, .limited(4096)) catch {
        return error.SessionInfoNotFound;
    };
    defer allocator.free(contents);

    var branch: []const u8 = "";
    var branch_name: []const u8 = "";
    errdefer {
        if (branch.len > 0) allocator.free(branch);
        if (branch_name.len > 0) allocator.free(branch_name);
    }

    var iter = std.mem.splitScalar(u8, contents, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "branch=")) {
            if (branch.len > 0) allocator.free(branch);
            branch = try allocator.dupe(u8, line["branch=".len..]);
        } else if (std.mem.startsWith(u8, line, "branch_name=")) {
            if (branch_name.len > 0) allocator.free(branch_name);
            branch_name = try allocator.dupe(u8, line["branch_name=".len..]);
        }
    }

    // Treat a malformed file (no recognised keys) the same as missing.
    if (branch.len == 0 and branch_name.len == 0) return error.SessionInfoNotFound;

    return .{ .branch = branch, .branch_name = branch_name };
}

/// Writes session metadata for `worktree_name` into the `git-session`
/// directory inside `bare_repo_path`, recording `branch` (the
/// base/upstream branch the session was created from) and `branch_name`
/// (the full working branch name, e.g. `feature/my-session`). These
/// values are later read by `parseSessionFile` during session removal
/// and fix operations.
pub fn saveSessionFile(allocator: std.mem.Allocator, io: std.Io, branch: []const u8, branch_name: []const u8, bare_repo_path: []const u8, worktree_name: []const u8) !void {
    // Ensure the git-session subdirectory exists inside the bare repo.
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bare_repo_path, session_dir_name });
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDir(io, dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const filepath = try sessionFilePath(allocator, bare_repo_path, worktree_name);
    defer allocator.free(filepath);

    const data = try std.fmt.allocPrint(allocator, "branch={s}\nbranch_name={s}\n", .{ branch, branch_name });
    defer allocator.free(data);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filepath, .data = data });
}

/// Deletes the session metadata file for `worktree_name` from the
/// `git-session` directory inside `bare_repo_path`.
/// Errors are silently ignored -- the file may not exist.
pub fn deleteSessionFile(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8, worktree_name: []const u8) void {
    const filepath = sessionFilePath(allocator, bare_repo_path, worktree_name) catch return;
    defer allocator.free(filepath);
    std.Io.Dir.cwd().deleteFile(io, filepath) catch {};
}

/// Returns `true` when `worktree_name` has a session metadata file
/// inside `bare_repo_path`. Propagates allocation errors so callers
/// can distinguish "file missing" from "couldn't check".
pub fn sessionFileExists(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8, worktree_name: []const u8) !bool {
    const filepath = try sessionFilePath(allocator, bare_repo_path, worktree_name);
    defer allocator.free(filepath);
    std.Io.Dir.cwd().access(io, filepath, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Directory listing helpers
// ---------------------------------------------------------------------------

/// A repo entry tracks both its display name and which root it lives under.
pub const RepoEntry = struct {
    name: []u8,
    root: []const u8, // points into AppConfig.roots, not owned
};

/// Returns a list of visible (non-dot-prefixed) subdirectory names under
/// `root_path`. Each name is a heap-allocated copy; the caller owns the
/// list and its elements.
pub fn listSubdirectories(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !std.ArrayList([]u8) {
    var result: std.ArrayList([]u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
        term.eprint(io, "Cannot open directory '{s}': {any}\n", .{ root_path, err });
        return result;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;
        try result.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return result;
}

/// Scans every directory in `roots` and returns repositories that have either
/// a local `.git-session.toml` file or a centralized config at
/// `~/.config/git-session/repos/<name>.toml`. Each entry carries the
/// repository name and a reference to its parent root (borrowed from
/// `roots`, not duplicated). The caller owns the returned list and each
/// `name` inside it; release them with `freeRepoEntries`.
///
/// As a robustness measure, this also enumerates every `*.toml` file in
/// `~/.config/git-session/repos/` so that repositories whose on-disk
/// folder has been deleted by the user still appear in the list. Such
/// "vanished" entries are appended only when their centrally-recorded
/// `root` exactly matches one of the entries in `roots`; mismatched or
/// rootless entries are skipped (see `appendVanishedCentralRepos` for
/// the rationale).
///
/// `quiet` controls whether skipped vanished repos produce a one-line
/// stderr warning. Pass `false` for general listing flows (main menu,
/// `findRepo`) where the user benefits from knowing an unreachable
/// repo exists. Pass `true` for narrow flows where the warnings are
/// off-topic noise — notably the `config remove-root` cascade, which
/// invokes the function with a single doomed root and would otherwise
/// warn about every repo belonging to the *other* configured roots.
pub fn listAllRepositories(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, roots: []const []const u8, quiet: bool) !std.ArrayList(RepoEntry) {
    var result: std.ArrayList(RepoEntry) = .empty;
    errdefer freeRepoEntries(allocator, &result);

    // Pass 1: scan each configured root for on-disk repo folders.
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name[0] == '.') continue;

            const cfg_subpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, repo_config_filename });
            defer allocator.free(cfg_subpath);

            const has_local = blk: {
                dir.access(io, cfg_subpath, .{}) catch break :blk false;
                break :blk true;
            };
            const has_central = blk: {
                const central_path = config.getCentralRepoConfigPath(allocator, env, entry.name) catch break :blk false;
                defer allocator.free(central_path);
                std.Io.Dir.cwd().access(io, central_path, .{}) catch break :blk false;
                break :blk true;
            };
            if (!has_local and !has_central) continue;
            try result.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .root = root,
            });
        }
    }

    // Pass 2: enumerate centralized configs to surface "vanished" repos
    // whose on-disk folder has been deleted but whose central config
    // still records them.
    if (roots.len > 0) {
        try appendVanishedCentralRepos(allocator, io, env, roots, quiet, &result);
    }

    return result;
}

/// Helper for `listAllRepositories`: appends any repository that has a
/// centralized config but is not yet present in `result`, **strictly
/// matched** against `roots` by the centrally-recorded `root` field.
///
/// A vanished repo is only appended when its central `root` exactly
/// equals one of the entries in `roots`. Any vanished repo whose
/// central `root` is missing or doesn't match a configured root is
/// skipped. When `quiet` is `false`, each skip produces a one-line
/// stderr warning (so the user knows it exists and can use
/// `--repository <name>` to reach it). When `quiet` is `true`, the
/// skip is silent — appropriate for narrow flows like the
/// `config remove-root` cascade where warnings about other roots'
/// repos are off-topic noise.
///
/// **Why strict matching?** Earlier versions fell back to `roots[0]`
/// when no match was found. That caused a destructive bug in the
/// `config remove-root` cascade: passing a single doomed root would
/// wrongly attribute every "homeless" vanished repo to it, and the
/// cascade would delete those repos' central configs even though they
/// belonged to *other* roots. Strict matching makes the function safe
/// to call with any subset of configured roots.
fn appendVanishedCentralRepos(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    roots: []const []const u8,
    quiet: bool,
    result: *std.ArrayList(RepoEntry),
) !void {
    const repos_dir = config.getRepoConfigDir(allocator, env) catch return;
    defer allocator.free(repos_dir);

    return appendVanishedCentralReposFromDir(allocator, io, repos_dir, roots, quiet, result);
}

/// Path-explicit variant of `appendVanishedCentralRepos` exposed for
/// tests. `repos_dir` is the directory containing per-repo `*.toml`
/// files (in production, `~/.config/git-session/repos/`).
///
/// Behaves exactly like `appendVanishedCentralRepos` but lets tests
/// substitute a temporary directory rather than relying on `HOME`.
fn appendVanishedCentralReposFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    repos_dir: []const u8,
    roots: []const []const u8,
    quiet: bool,
    result: *std.ArrayList(RepoEntry),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, repos_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        const repo_name = entry.name[0 .. entry.name.len - ".toml".len];
        if (repo_name.len == 0) continue;

        // Skip if we already added this repo from an on-disk scan.
        var already_listed = false;
        for (result.items) |e| {
            if (std.mem.eql(u8, e.name, repo_name)) {
                already_listed = true;
                break;
            }
        }
        if (already_listed) continue;

        // Strictly match the centrally-recorded `root` against `roots`.
        // No fallback: when there is no match we skip the entry.
        const central_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repos_dir, entry.name });
        defer allocator.free(central_path);
        var cfg = parseRepoConfigFile(allocator, io, central_path) catch |err| switch (err) {
            error.ConfigNotFound => continue,
            else => return err,
        };
        defer freeRepoConfig(allocator, &cfg);

        if (cfg.root.len == 0) {
            if (!quiet) {
                term.eprint(io, 
                    "Warning: skipping centrally-configured repo '{s}': no 'root' recorded in {s}.toml. Use --repository {s} to access it directly.\n",
                    .{ repo_name, repo_name, repo_name },
                );
            }
            continue;
        }

        var bound_root: ?[]const u8 = null;
        for (roots) |r| {
            if (std.mem.eql(u8, r, cfg.root)) {
                bound_root = r;
                break;
            }
        }

        if (bound_root == null) {
            if (!quiet) {
                term.eprint(io, 
                    "Warning: skipping centrally-configured repo '{s}': its recorded root '{s}' is not among the passed roots. Use --repository {s} to access it directly.\n",
                    .{ repo_name, cfg.root, repo_name },
                );
            }
            continue;
        }

        try result.append(allocator, .{
            .name = try allocator.dupe(u8, repo_name),
            .root = bound_root.?,
        });
    }
}

/// Frees all heap-allocated `name` fields inside the list of `RepoEntry`
/// values and deinitialises the `ArrayList` itself.
pub fn freeRepoEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(RepoEntry)) void {
    for (entries.items) |e| allocator.free(e.name);
    entries.deinit(allocator);
}

/// Lists worktree directories under `repo_root` by returning all visible
/// subdirectories that do not end with `.git` (the bare repository is
/// excluded). The caller owns the returned list and each element.
pub fn listWorktrees(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) !std.ArrayList([]u8) {
    var all = try listSubdirectories(allocator, io, repo_root);
    var i: usize = 0;
    while (i < all.items.len) {
        if (std.mem.endsWith(u8, all.items[i], ".git")) {
            allocator.free(all.items[i]);
            _ = all.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    return all;
}

// ---------------------------------------------------------------------------
// Repository selection
// ---------------------------------------------------------------------------

/// Represents a repository that the user has selected for interaction,
/// bundling its name, on-disk root path, and parsed configuration.
pub const SelectedRepo = struct {
    name: []const u8,
    root: []u8, // allocator-owned: <session_root>/<name>
    config: RepoConfig,
};

/// Frees all allocator-owned memory inside a `SelectedRepo`, including
/// its name, root path, and embedded `RepoConfig`.
pub fn freeSelectedRepo(allocator: std.mem.Allocator, selected: *SelectedRepo) void {
    allocator.free(selected.name);
    allocator.free(selected.root);
    freeRepoConfig(allocator, &selected.config);
}

// ---------------------------------------------------------------------------
// Bare-repo recovery
// ---------------------------------------------------------------------------
// If a user accidentally deletes the bare repository, the repo folder, or
// even the entire root folder, we can re-create the missing pieces and
// re-clone from `origin_url`, provided that information is recorded in the
// centralized per-repo config (`~/.config/git-session/repos/<name>.toml`).
//
// Recovery is gated on the centralized config because:
//   - The legacy `<repo_root>/.git-session.toml` lives *inside* the repo
//     folder and is therefore deleted along with it.
//   - The centralized location survives any on-disk repo-folder deletion
//     and is the only place we can durably record `origin_url` and the
//     parent `root` path.
//
// The recovery itself is silent on the happy path (everything is already
// present) and prints a single human-readable message before re-cloning
// in the recovery path. There are no prompts: the user has explicitly
// asked for this behaviour by adding the repo via the central-config
// flow.
// ---------------------------------------------------------------------------

/// Returns the absolute path of the bare repository directory for
/// `repo_name`/`bare_repo_name` under `session_root`, namely
/// `<session_root>/<repo_name>/<bare_repo_name>.git`. The returned slice
/// is heap-allocated; the caller owns it.
fn bareRepoPath(allocator: std.mem.Allocator, session_root: []const u8, repo_name: []const u8, bare_repo_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}.git",
        .{ session_root, repo_name, bare_repo_name },
    );
}

/// Verifies that the bare repository for `repo_name` exists under
/// `session_root`, and if not, attempts to re-create it by cloning
/// from `cfg.origin_url`. Re-creates any missing parent directories
/// (the root folder and the repo folder) along the way.
///
/// Recovery only runs when the centralized per-repo config exists; if
/// the repo is configured only via the per-repository
/// `.git-session.toml` file, this function returns
/// `error.BareRepoMissingNoCentralConfig` so that the caller can show
/// a useful error message.
///
/// On the happy path (bare repo already present) this function is a
/// no-op. On the recovery path it prints a single human-readable
/// message describing what it is doing.
///
/// The `session_root` argument is the parent of the repo folder
/// (typically `app_config.roots[i]`). When the central config records
/// a `root`, it is preferred over `session_root` for the recovery
/// destination so that a fully-deleted repo is restored at exactly the
/// path the user originally chose.
pub fn ensureBareRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    session_root: []const u8,
    repo_name: []const u8,
    cfg: RepoConfig,
) !void {
    const central_path = config.getCentralRepoConfigPath(allocator, env, repo_name) catch {
        // No HOME -> no central config can ever exist; recovery is gated
        // on the centralized config being present.
        return ensureBareRepoAt(allocator, io, session_root, repo_name, cfg, "");
    };
    defer allocator.free(central_path);
    return ensureBareRepoAt(allocator, io, session_root, repo_name, cfg, central_path);
}

/// Path-explicit variant of `ensureBareRepo` exposed for tests.
/// `central_config_path` is the absolute path to the centralized
/// per-repo config; pass an empty string to indicate "no central
/// config" (which short-circuits recovery).
pub fn ensureBareRepoAt(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_root: []const u8,
    repo_name: []const u8,
    cfg: RepoConfig,
    central_config_path: []const u8,
) !void {
    const bare_name = if (cfg.bare_repo.len > 0) cfg.bare_repo else repo_name;

    // Prefer the centrally-recorded root over the caller-provided one
    // when present; this matters when recovering a repo whose folder
    // has fully vanished from disk and the caller is guessing the root.
    const effective_root = if (cfg.root.len > 0) cfg.root else session_root;

    const bare_path = try bareRepoPath(allocator, effective_root, repo_name, bare_name);
    defer allocator.free(bare_path);

    if (dirExists(io, bare_path)) return; // Happy path -- nothing to do.

    // Bare repo is missing. Recovery requires the centralized config
    // (so we can read/write `origin_url` durably) and an `origin_url`.
    if (central_config_path.len == 0 or !dirExists(io, central_config_path)) {
        return error.BareRepoMissingNoCentralConfig;
    }

    if (cfg.origin_url.len == 0) {
        return error.BareRepoMissingNoOriginUrl;
    }

    // Recreate the missing parent directories.
    const repo_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ effective_root, repo_name });
    defer allocator.free(repo_dir);

    std.Io.Dir.cwd().createDirPath(io, repo_dir) catch |err| {
        term.eprint(io, "Error: cannot create directory '{s}' during recovery: {any}\n", .{ repo_dir, err });
        return err;
    };

    term.eprint(io, 
        "Bare repository at '{s}' is missing -- re-cloning from {s} ...\n",
        .{ bare_path, cfg.origin_url },
    );

    git.gitCloneForSession(allocator, io, cfg.origin_url, repo_dir, bare_name) catch {
        return error.BareRepoRecloneFailed;
    };
}

/// Best-effort backfill of `origin_url` and `root` into the centralized
/// config for `repo_name` when they are absent. Reads the URL from the
/// existing bare repository's `origin` remote and writes both fields
/// back into `~/.config/git-session/repos/<repo_name>.toml`.
///
/// All failures are silent: this is a one-time data migration for
/// existing repos and we never want it to break a normal command. The
/// next successful `openRepo` after the upgrade will populate the
/// fields; subsequent calls are no-ops.
///
/// `cfg` is updated in place when the backfill succeeds, so the caller
/// can use the new values without reloading.
fn backfillRecoveryFields(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    session_root: []const u8,
    repo_name: []const u8,
    cfg: *RepoConfig,
) void {
    // No central config -> backfill is impossible; skip silently.
    const central_path = config.getCentralRepoConfigPath(allocator, env, repo_name) catch return;
    defer allocator.free(central_path);
    if (!dirExists(io, central_path)) return;

    // origin_url backfill: only when the bare repo currently exists and
    // has an origin remote we can read.
    if (cfg.origin_url.len == 0) {
        const bare_name = if (cfg.bare_repo.len > 0) cfg.bare_repo else repo_name;
        const bp = bareRepoPath(allocator, session_root, repo_name, bare_name) catch return;
        defer allocator.free(bp);
        if (dirExists(io, bp)) {
            if (git.gitGetOriginUrl(allocator, io, bp)) |url| {
                config.upsertTomlTopLevelString(allocator, io, central_path, "origin_url", url) catch {
                    allocator.free(url);
                    return;
                };
                cfg.origin_url = url; // transfer ownership into cfg
            }
        }
    }

    // root backfill: always safe to record the root we just opened from.
    if (cfg.root.len == 0 and session_root.len > 0) {
        config.upsertTomlTopLevelString(allocator, io, central_path, "root", session_root) catch return;
        cfg.root = allocator.dupe(u8, session_root) catch return;
    }
}

/// Opens the repository named `repo_name` inside `session_root` by
/// constructing its root path (`<session_root>/<repo_name>`) and loading
/// its `.git-session.toml` configuration. If `bare_repo` is not set in
/// the config, it defaults to `repo_name`. Returns `null` (and prints an
/// error) when the config cannot be parsed. The caller must release the
/// returned value with `freeSelectedRepo`.
///
/// As a robustness measure, this function also recovers from accidental
/// deletion of the bare repository (or the repo folder, or the parent
/// root folder) by re-cloning from the centrally-recorded `origin_url`
/// when one is available. See `ensureBareRepo` for the gating rules.
/// When the bare repository is present and the central config is
/// missing recovery metadata (`origin_url` / `root`), those fields are
/// silently backfilled so that future deletions can be recovered.
pub fn openRepo(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, session_root: []const u8, repo_name: []const u8) !?SelectedRepo {
    // First try to load the per-repo config. When the repo folder has
    // been deleted (the user nuked the entire repo directory or its
    // parent root), the local `.git-session.toml` won't exist either,
    // but the centralized config might -- so loadRepoConfig will still
    // succeed if the central file is present.
    var repo_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ session_root, repo_name });
    errdefer allocator.free(repo_root);

    var cfg = loadRepoConfig(allocator, io, env, repo_root) catch {
        term.eprint(io, "Error: could not parse {s} in '{s}'\n", .{ repo_config_filename, repo_name });
        return null;
    };
    errdefer freeRepoConfig(allocator, &cfg);

    if (cfg.bare_repo.len == 0) {
        cfg.bare_repo = try allocator.dupe(u8, repo_name);
    }

    // Decide where the repo *should* live: prefer the centrally
    // recorded `root` over the caller-provided `session_root` so that
    // a fully-deleted repo is restored to the user's original location.
    const effective_root = if (cfg.root.len > 0) cfg.root else session_root;
    if (!std.mem.eql(u8, effective_root, session_root)) {
        allocator.free(repo_root);
        repo_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ effective_root, repo_name });
    }

    // Recover the bare repo if it's missing (or fail with a clear
    // error indicating why we can't).
    ensureBareRepo(allocator, io, env, effective_root, repo_name, cfg) catch |err| {
        switch (err) {
            error.BareRepoMissingNoCentralConfig => {
                term.eprint(io, 
                    "Error: bare repository for '{s}' is missing and no centralized config exists at ~/.config/git-session/repos/{s}.toml -- cannot auto-recover.\n",
                    .{ repo_name, repo_name },
                );
            },
            error.BareRepoMissingNoOriginUrl => {
                term.eprint(io, 
                    "Error: bare repository for '{s}' is missing and no origin_url is recorded in ~/.config/git-session/repos/{s}.toml -- cannot auto-recover. Re-add the repository or add 'origin_url = \"...\"' to the config by hand.\n",
                    .{ repo_name, repo_name },
                );
            },
            error.BareRepoRecloneFailed => {
                term.eprint(io, "Error: failed to re-clone '{s}' during recovery.\n", .{repo_name});
            },
            else => {
                term.eprint(io, "Error: failed to recover '{s}': {any}\n", .{ repo_name, err });
            },
        }
        return null;
    };

    // Best-effort backfill so future deletions can be auto-recovered.
    backfillRecoveryFields(allocator, io, env, effective_root, repo_name, &cfg);

    return .{
        .name = try allocator.dupe(u8, repo_name),
        .root = repo_root,
        .config = cfg,
    };
}

// ---------------------------------------------------------------------------
// Repository removal
// ---------------------------------------------------------------------------

/// Deletes the on-disk repository directory at `<root>/<repo_name>`,
/// including the bare repo, every worktree (session), and any session
/// metadata. A missing directory is *not* an error so callers can treat
/// the operation as idempotent.
///
/// This function only touches the filesystem; it does **not** kill any
/// tmux sessions or remove the centralized config file. Callers (CLI /
/// TUI) are responsible for those steps so that this helper stays
/// trivially testable in a tmpDir.
pub fn removeRepositoryDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    repo_name: []const u8,
) !void {
    const repo_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, repo_name });
    defer allocator.free(repo_dir);

    // `deleteTree` is already idempotent: it returns success when the
    // target does not exist. We propagate any other I/O failures.
    try std.Io.Dir.cwd().deleteTree(io, repo_dir);
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

/// Returns `true` when `path` is accessible relative to the current
/// working directory. Note: does not verify that `path` is a directory;
/// any accessible filesystem entry will return `true`.
pub fn dirExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Helper: write a file inside a tmp dir and return the absolute path to the
/// parent directory so that `loadRepoConfig` / `parseSessionFile` can find it.
fn writeTmpFile(tmp_dir: *std.testing.TmpDir, sub_path: []const u8, data: []const u8) void {
    tmp_dir.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data }) catch unreachable;
}

// ---- loadRepoConfig tests -------------------------------------------------

test "loadRepoConfig parses minimal config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const toml =
        \\bare_repo = "my-project"
        \\start_branches = ["main", "develop"]
        \\branch_prefixes = ["feature", "bugfix"]
    ;
    writeTmpFile(&tmp, repo_config_filename, toml);

    // We need the real filesystem path for loadRepoConfig, which opens
    // the file via cwd-relative path. tmpDir gives us a Dir handle; we
    // can derive the path from it.
    const allocator = testing.allocator;
    var test_env = try std.process.Environ.createMap(testing.environ, allocator);
    defer test_env.deinit();
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(path);

    var cfg = try loadRepoConfig(allocator, testing.io, &test_env, path);
    defer freeRepoConfig(allocator, &cfg);

    try testing.expectEqualStrings("my-project", cfg.bare_repo);
    try testing.expectEqual(@as(usize, 2), cfg.start_branches.items.len);
    try testing.expectEqualStrings("main", cfg.start_branches.items[0]);
    try testing.expectEqualStrings("develop", cfg.start_branches.items[1]);
    try testing.expectEqual(@as(usize, 2), cfg.branch_prefixes.items.len);
    try testing.expectEqualStrings("feature", cfg.branch_prefixes.items[0]);
    try testing.expectEqualStrings("bugfix", cfg.branch_prefixes.items[1]);
    try testing.expectEqual(@as(usize, 0), cfg.windows.items.len);
}

test "loadRepoConfig parses windows with single commands" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const toml =
        \\bare_repo = "app"
        \\start_branches = ["main"]
        \\branch_prefixes = ["feature"]
        \\
        \\[[window]]
        \\name = "editor"
        \\command = "vim"
        \\
        \\[[window]]
        \\name = "shell"
    ;
    writeTmpFile(&tmp, repo_config_filename, toml);

    const allocator = testing.allocator;
    var test_env = try std.process.Environ.createMap(testing.environ, allocator);
    defer test_env.deinit();
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(path);

    var cfg = try loadRepoConfig(allocator, testing.io, &test_env, path);
    defer freeRepoConfig(allocator, &cfg);

    try testing.expectEqual(@as(usize, 2), cfg.windows.items.len);

    try testing.expectEqualStrings("editor", cfg.windows.items[0].name);
    try testing.expectEqual(@as(usize, 1), cfg.windows.items[0].commands.items.len);
    try testing.expectEqualStrings("vim", cfg.windows.items[0].commands.items[0]);

    try testing.expectEqualStrings("shell", cfg.windows.items[1].name);
    try testing.expectEqual(@as(usize, 0), cfg.windows.items[1].commands.items.len);
}

test "loadRepoConfig parses multi-line command block" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const toml =
        \\bare_repo = "app"
        \\start_branches = ["main"]
        \\branch_prefixes = []
        \\
        \\[[window]]
        \\name = "dev"
        \\command = """
        \\npm install
        \\npm run dev
        \\"""
    ;
    writeTmpFile(&tmp, repo_config_filename, toml);

    const allocator = testing.allocator;
    var test_env = try std.process.Environ.createMap(testing.environ, allocator);
    defer test_env.deinit();
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(path);

    var cfg = try loadRepoConfig(allocator, testing.io, &test_env, path);
    defer freeRepoConfig(allocator, &cfg);

    try testing.expectEqual(@as(usize, 1), cfg.windows.items.len);
    try testing.expectEqual(@as(usize, 2), cfg.windows.items[0].commands.items.len);
    try testing.expectEqualStrings("npm install", cfg.windows.items[0].commands.items[0]);
    try testing.expectEqualStrings("npm run dev", cfg.windows.items[0].commands.items[1]);
}

test "loadRepoConfig parses origin_url and root recovery fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const toml =
        \\bare_repo = "my-project"
        \\start_branches = ["main"]
        \\branch_prefixes = ["feature"]
        \\origin_url = "git@github.com:user/my-project.git"
        \\root = "/Users/me/Developer"
    ;
    writeTmpFile(&tmp, repo_config_filename, toml);

    const allocator = testing.allocator;
    var test_env = try std.process.Environ.createMap(testing.environ, allocator);
    defer test_env.deinit();
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(path);

    var cfg = try loadRepoConfig(allocator, testing.io, &test_env, path);
    defer freeRepoConfig(allocator, &cfg);

    try testing.expectEqualStrings("git@github.com:user/my-project.git", cfg.origin_url);
    try testing.expectEqualStrings("/Users/me/Developer", cfg.root);
}

test "loadRepoConfig defaults origin_url and root to empty when absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const toml =
        \\bare_repo = "my-project"
        \\start_branches = ["main"]
        \\branch_prefixes = ["feature"]
    ;
    writeTmpFile(&tmp, repo_config_filename, toml);

    const allocator = testing.allocator;
    var test_env = try std.process.Environ.createMap(testing.environ, allocator);
    defer test_env.deinit();
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(path);

    var cfg = try loadRepoConfig(allocator, testing.io, &test_env, path);
    defer freeRepoConfig(allocator, &cfg);

    try testing.expectEqualStrings("", cfg.origin_url);
    try testing.expectEqualStrings("", cfg.root);
}

test "loadRepoConfig returns error for missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    var test_env = try std.process.Environ.createMap(testing.environ, allocator);
    defer test_env.deinit();
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(path);

    const result = loadRepoConfig(allocator, testing.io, &test_env, path);
    try testing.expectError(error.ConfigNotFound, result);
}

test "loadRepoConfigFromPaths uses central config when only central exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    writeTmpFile(&tmp, "central.toml", "bare_repo = \"central-repo\"\nstart_branches = [\"main\"]\nbranch_prefixes = []\n");

    const central_path = try std.fmt.allocPrint(allocator, "{s}/central.toml", .{tmp_path});
    defer allocator.free(central_path);
    const local_path = try std.fmt.allocPrint(allocator, "{s}/nonexistent.toml", .{tmp_path});
    defer allocator.free(local_path);

    var cfg = try loadRepoConfigFromPaths(allocator, testing.io, central_path, local_path);
    defer freeRepoConfig(allocator, &cfg);

    try testing.expectEqualStrings("central-repo", cfg.bare_repo);
}

test "loadRepoConfigFromPaths prefers central config over local" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    writeTmpFile(&tmp, "local.toml", "bare_repo = \"local-repo\"\nstart_branches = [\"main\"]\nbranch_prefixes = []\n");
    writeTmpFile(&tmp, "central.toml", "bare_repo = \"central-repo\"\nstart_branches = [\"main\"]\nbranch_prefixes = []\n");

    const central_path = try std.fmt.allocPrint(allocator, "{s}/central.toml", .{tmp_path});
    defer allocator.free(central_path);
    const local_path = try std.fmt.allocPrint(allocator, "{s}/local.toml", .{tmp_path});
    defer allocator.free(local_path);

    var cfg = try loadRepoConfigFromPaths(allocator, testing.io, central_path, local_path);
    defer freeRepoConfig(allocator, &cfg);

    try testing.expectEqualStrings("central-repo", cfg.bare_repo);
}

// ---- parseSessionFile tests -----------------------------------------------

test "parseSessionFile reads from bare repo location" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Simulate bare repo layout: <tmp>/bare.git/git-session/my-wt.session
    try tmp.dir.createDirPath(testing.io, "bare.git/git-session");
    var session_dir = try tmp.dir.openDir(testing.io, "bare.git/git-session", .{});
    defer session_dir.close(testing.io);
    try session_dir.writeFile(testing.io, .{ .sub_path = "my-wt.session", .data = "branch=feature/my-feature\nbranch_name=my-feature\n" });

    const allocator = testing.allocator;
    const bare_path = try tmp.dir.realPathFileAlloc(testing.io, "bare.git", allocator);
    defer allocator.free(bare_path);

    const info = try parseSessionFile(allocator, testing.io, bare_path, "my-wt");
    defer {
        if (info.branch.len > 0) allocator.free(info.branch);
        if (info.branch_name.len > 0) allocator.free(info.branch_name);
    }

    try testing.expectEqualStrings("feature/my-feature", info.branch);
    try testing.expectEqualStrings("my-feature", info.branch_name);
}

test "parseSessionFile returns error when no file exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "bare.git", .default_dir);

    const allocator = testing.allocator;
    const bare_path = try tmp.dir.realPathFileAlloc(testing.io, "bare.git", allocator);
    defer allocator.free(bare_path);

    const result = parseSessionFile(allocator, testing.io, bare_path, "my-wt");
    try testing.expectError(error.SessionInfoNotFound, result);
}

// ---- saveSessionFile tests ------------------------------------------------

test "saveSessionFile creates file in bare repo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "bare.git", .default_dir);

    const allocator = testing.allocator;
    const bare_path = try tmp.dir.realPathFileAlloc(testing.io, "bare.git", allocator);
    defer allocator.free(bare_path);

    try saveSessionFile(allocator, testing.io, "main", "feature/test", bare_path, "my-wt");

    // Verify file was created at the right location
    const info = try parseSessionFile(allocator, testing.io, bare_path, "my-wt");
    defer {
        if (info.branch.len > 0) allocator.free(info.branch);
        if (info.branch_name.len > 0) allocator.free(info.branch_name);
    }

    try testing.expectEqualStrings("main", info.branch);
    try testing.expectEqualStrings("feature/test", info.branch_name);
}

// ---- deleteSessionFile tests ----------------------------------------------

test "deleteSessionFile removes file from bare repo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "bare.git", .default_dir);

    const allocator = testing.allocator;
    const bare_path = try tmp.dir.realPathFileAlloc(testing.io, "bare.git", allocator);
    defer allocator.free(bare_path);

    try saveSessionFile(allocator, testing.io, "main", "feature/test", bare_path, "my-wt");
    deleteSessionFile(allocator, testing.io, bare_path, "my-wt");

    const result = parseSessionFile(allocator, testing.io, bare_path, "my-wt");
    try testing.expectError(error.SessionInfoNotFound, result);
}

// ---- sessionFileExists tests ----------------------------------------------

test "sessionFileExists returns true when file exists in bare repo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "bare.git", .default_dir);

    const allocator = testing.allocator;
    const bare_path = try tmp.dir.realPathFileAlloc(testing.io, "bare.git", allocator);
    defer allocator.free(bare_path);

    try saveSessionFile(allocator, testing.io, "main", "feature/test", bare_path, "my-wt");
    try testing.expect(try sessionFileExists(allocator, testing.io, bare_path, "my-wt"));
}

test "sessionFileExists returns false when no file exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "bare.git", .default_dir);

    const allocator = testing.allocator;
    const bare_path = try tmp.dir.realPathFileAlloc(testing.io, "bare.git", allocator);
    defer allocator.free(bare_path);

    try testing.expect(!try sessionFileExists(allocator, testing.io, bare_path, "my-wt"));
}

// ---- removeRepositoryDirectory tests --------------------------------------

test "removeRepositoryDirectory deletes a populated repo tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Lay out a realistic repo: bare repo + two worktrees + session metadata
    // + central config sibling files. Only <root>/<repo_name> is targeted.
    try tmp.dir.createDirPath(testing.io, "my-project/my-project.git/git-session");
    try tmp.dir.createDirPath(testing.io, "my-project/feature-x");
    try tmp.dir.createDirPath(testing.io, "my-project/bugfix-y");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "my-project/my-project.git/git-session/feature-x.session",
        .data = "branch=main\nbranch_name=feature/feature-x\n",
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "my-project/feature-x/README.md", .data = "wt\n" });

    // A sibling repo that must NOT be deleted.
    try tmp.dir.createDirPath(testing.io, "other-project/other-project.git");

    const allocator = testing.allocator;
    const root_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root_path);

    try removeRepositoryDirectory(allocator, testing.io, root_path, "my-project");

    // Target dir is gone.
    const target = try std.fmt.allocPrint(allocator, "{s}/my-project", .{root_path});
    defer allocator.free(target);
    try testing.expect(!dirExists(testing.io, target));

    // Sibling is intact.
    const sibling = try std.fmt.allocPrint(allocator, "{s}/other-project", .{root_path});
    defer allocator.free(sibling);
    try testing.expect(dirExists(testing.io, sibling));
}

test "removeRepositoryDirectory is idempotent when target is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const root_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root_path);

    // Calling on a non-existent repo should succeed silently.
    try removeRepositoryDirectory(allocator, testing.io, root_path, "never-existed");

    // Calling twice in a row is safe.
    try tmp.dir.createDirPath(testing.io, "doomed/doomed.git");
    try removeRepositoryDirectory(allocator, testing.io, root_path, "doomed");
    try removeRepositoryDirectory(allocator, testing.io, root_path, "doomed");
}

test "removeRepositoryDirectory does not stray outside the named repo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two repos sharing a common prefix to guard against accidental
    // prefix-based matching.
    try tmp.dir.createDirPath(testing.io, "api/api.git");
    try tmp.dir.createDirPath(testing.io, "api-v2/api-v2.git");

    const allocator = testing.allocator;
    const root_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root_path);

    try removeRepositoryDirectory(allocator, testing.io, root_path, "api");

    const api = try std.fmt.allocPrint(allocator, "{s}/api", .{root_path});
    defer allocator.free(api);
    const api_v2 = try std.fmt.allocPrint(allocator, "{s}/api-v2", .{root_path});
    defer allocator.free(api_v2);

    try testing.expect(!dirExists(testing.io, api));
    try testing.expect(dirExists(testing.io, api_v2));
}

// ---- bareRepoPath tests ---------------------------------------------------

test "bareRepoPath constructs <root>/<repo>/<bare>.git" {
    const allocator = testing.allocator;
    const path = try bareRepoPath(allocator, "/home/user/Dev", "my-project", "my-project");
    defer allocator.free(path);
    try testing.expectEqualStrings("/home/user/Dev/my-project/my-project.git", path);
}

test "bareRepoPath handles distinct bare_repo_name" {
    const allocator = testing.allocator;
    const path = try bareRepoPath(allocator, "/root", "repo-folder", "custom-bare");
    defer allocator.free(path);
    try testing.expectEqualStrings("/root/repo-folder/custom-bare.git", path);
}

// ---- appendVanishedCentralReposFromDir tests ------------------------------

/// Convenience helper: writes `<repos_dir>/<name>.toml` with the given
/// contents inside a tmp dir. Returns the absolute repos_dir path so
/// tests can pass it to `appendVanishedCentralReposFromDir`.
fn writeCentralToml(tmp: *std.testing.TmpDir, name: []const u8, contents: []const u8) void {
    const sub = std.fmt.allocPrint(testing.allocator, "{s}.toml", .{name}) catch unreachable;
    defer testing.allocator.free(sub);
    tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = contents }) catch unreachable;
}

test "appendVanishedCentralReposFromDir lists repos whose central root matches a passed root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const repos_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(repos_dir);

    writeCentralToml(&tmp, "alpha", "bare_repo = \"alpha\"\norigin_url = \"u\"\nroot = \"/r1\"\n");

    const roots = [_][]const u8{ "/r1", "/r2" };
    var result: std.ArrayList(RepoEntry) = .empty;
    defer freeRepoEntries(allocator, &result);

    try appendVanishedCentralReposFromDir(allocator, testing.io, repos_dir, &roots, false, &result);

    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("alpha", result.items[0].name);
    try testing.expectEqualStrings("/r1", result.items[0].root);
}

test "appendVanishedCentralReposFromDir skips repos whose central root does not match any passed root" {
    // Regression: when called with a single doomed root during
    // `config remove-root`, vanished repos belonging to *other* roots
    // must NOT be reported under the doomed root. Previously the code
    // fell back to roots[0], causing the cascade to wrongly delete
    // central configs of unrelated repos.
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const repos_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(repos_dir);

    writeCentralToml(&tmp, "alpha", "bare_repo = \"alpha\"\norigin_url = \"u\"\nroot = \"/r-elsewhere\"\n");
    writeCentralToml(&tmp, "beta", "bare_repo = \"beta\"\norigin_url = \"u\"\nroot = \"/r-doomed\"\n");

    // Caller passes only the doomed root (mirrors the cascade path).
    const roots = [_][]const u8{"/r-doomed"};
    var result: std.ArrayList(RepoEntry) = .empty;
    defer freeRepoEntries(allocator, &result);

    try appendVanishedCentralReposFromDir(allocator, testing.io, repos_dir, &roots, false, &result);

    // Only `beta` (whose root matches) is included; `alpha` is
    // intentionally omitted to prevent the cascade misattribution.
    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("beta", result.items[0].name);
    try testing.expectEqualStrings("/r-doomed", result.items[0].root);
}

test "appendVanishedCentralReposFromDir skips repos with no recorded root" {
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const repos_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(repos_dir);

    // No `root = "..."` line.
    writeCentralToml(&tmp, "rootless", "bare_repo = \"rootless\"\norigin_url = \"u\"\n");

    const roots = [_][]const u8{"/r1"};
    var result: std.ArrayList(RepoEntry) = .empty;
    defer freeRepoEntries(allocator, &result);

    try appendVanishedCentralReposFromDir(allocator, testing.io, repos_dir, &roots, false, &result);

    try testing.expectEqual(@as(usize, 0), result.items.len);
}

test "appendVanishedCentralReposFromDir skips entries already in result (dedup)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const repos_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(repos_dir);

    writeCentralToml(&tmp, "alpha", "bare_repo = \"alpha\"\norigin_url = \"u\"\nroot = \"/r1\"\n");

    const roots = [_][]const u8{"/r1"};
    var result: std.ArrayList(RepoEntry) = .empty;
    defer freeRepoEntries(allocator, &result);

    // Pre-populate with `alpha` to simulate pass 1 having already
    // discovered it on disk.
    try result.append(allocator, .{
        .name = try allocator.dupe(u8, "alpha"),
        .root = "/r1",
    });

    try appendVanishedCentralReposFromDir(allocator, testing.io, repos_dir, &roots, false, &result);

    // Still exactly one entry -- no duplicate added.
    try testing.expectEqual(@as(usize, 1), result.items.len);
}

test "appendVanishedCentralReposFromDir tolerates a missing repos directory" {
    const allocator = testing.allocator;

    const roots = [_][]const u8{"/r1"};
    var result: std.ArrayList(RepoEntry) = .empty;
    defer freeRepoEntries(allocator, &result);

    // Should silently no-op when the dir does not exist.
    try appendVanishedCentralReposFromDir(allocator, testing.io, "/this/path/does/not/exist/abcxyz", &roots, false, &result);
    try testing.expectEqual(@as(usize, 0), result.items.len);
}

test "appendVanishedCentralReposFromDir quiet=true still skips mismatched repos and produces no warnings" {
    // The cascade in `config remove-root` passes a single doomed root
    // and `quiet=true`; vanished repos belonging to other roots must
    // be excluded *and* must not produce stderr warnings.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const repos_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(repos_dir);

    writeCentralToml(&tmp, "elsewhere", "bare_repo = \"elsewhere\"\norigin_url = \"u\"\nroot = \"/r-elsewhere\"\n");
    writeCentralToml(&tmp, "rootless", "bare_repo = \"rootless\"\norigin_url = \"u\"\n");
    writeCentralToml(&tmp, "doomed", "bare_repo = \"doomed\"\norigin_url = \"u\"\nroot = \"/r-doomed\"\n");

    const roots = [_][]const u8{"/r-doomed"};
    var result: std.ArrayList(RepoEntry) = .empty;
    defer freeRepoEntries(allocator, &result);

    // Note: we deliberately do NOT call `term.setQuiet(true)` here. With
    // `quiet=true` the function must suppress its own warnings without
    // relying on the global stderr-suppression switch -- otherwise the
    // cascade would still print warnings during normal user operation.
    try appendVanishedCentralReposFromDir(allocator, testing.io, repos_dir, &roots, true, &result);

    // Only the matching repo is included; warnings are suppressed.
    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("doomed", result.items[0].name);
}

// ---- ensureBareRepoAt tests -----------------------------------------------

const process = @import("process.zig");

/// Creates a real local bare git repository (with one commit) under
/// `tmp_dir` at sub-path `name.git` and returns the absolute path. Used
/// as a clonable "upstream" for ensureBareRepoAt tests. Returns
/// `error.SkipZigTest` when git is not available in the environment.
fn createTestUpstream(allocator: std.mem.Allocator, tmp_dir: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    // Create a working repo, make a commit, then convert to bare via
    // `git clone --bare` so we have a fetchable upstream.
    const work_dir = try std.fmt.allocPrint(allocator, "{s}/__upstream_work_{s}", .{ tmp_path, name });
    defer allocator.free(work_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, work_dir);

    inline for (.{
        &[_][]const u8{ "git", "init", "--quiet", "-b", "main" },
        &[_][]const u8{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init", "--quiet" },
    }) |argv| {
        const r = try process.exec(allocator, testing.io, argv, work_dir);
        process.freeExecResult(allocator, r);
        if (!r.exited_ok) return error.SkipZigTest;
    }

    const upstream_dir = try std.fmt.allocPrint(allocator, "{s}/{s}.git", .{ tmp_path, name });
    const clone_res = try process.exec(allocator, testing.io, &.{ "git", "clone", "--bare", "--quiet", work_dir, upstream_dir }, tmp_path);
    process.freeExecResult(allocator, clone_res);
    if (!clone_res.exited_ok) {
        allocator.free(upstream_dir);
        return error.SkipZigTest;
    }

    return upstream_dir;
}

/// Returns a `file://` URL for the absolute repo path so it can be
/// passed as a clone source.
fn fileUrl(allocator: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
}

test "ensureBareRepoAt is a no-op when bare repo already exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    // Pre-existing layout: <tmp>/my-repo/my-repo.git
    try tmp.dir.createDirPath(testing.io, "my-repo/my-repo.git");

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = "",
        .root = "",
    };
    defer freeRepoConfig(allocator, &cfg);

    // No central config and no origin_url, but bare repo exists -> success.
    try ensureBareRepoAt(allocator, testing.io, tmp_path, "my-repo", cfg, "");
}

test "ensureBareRepoAt re-clones missing bare repo when central config + origin_url present" {
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const upstream = createTestUpstream(allocator, &tmp, "my-repo") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(upstream);

    const url = try fileUrl(allocator, upstream);
    defer allocator.free(url);

    // The repo folder exists but the bare repo subdir does not.
    try tmp.dir.createDirPath(testing.io, "my-repo");

    // A central config file must exist (its contents are not parsed by
    // ensureBareRepoAt; only its presence is checked).
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "central.toml", .data = "x = 1\n" });
    const central = try std.fmt.allocPrint(allocator, "{s}/central.toml", .{tmp_path});
    defer allocator.free(central);

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = try allocator.dupe(u8, url),
        .root = "",
    };
    defer freeRepoConfig(allocator, &cfg);

    try ensureBareRepoAt(allocator, testing.io, tmp_path, "my-repo", cfg, central);

    // The bare repo should now exist.
    const bare = try std.fmt.allocPrint(allocator, "{s}/my-repo/my-repo.git", .{tmp_path});
    defer allocator.free(bare);
    try testing.expect(dirExists(testing.io, bare));
}

test "ensureBareRepoAt recreates the repo folder when missing" {
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const upstream = createTestUpstream(allocator, &tmp, "my-repo") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(upstream);

    const url = try fileUrl(allocator, upstream);
    defer allocator.free(url);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "central.toml", .data = "x = 1\n" });
    const central = try std.fmt.allocPrint(allocator, "{s}/central.toml", .{tmp_path});
    defer allocator.free(central);

    // Note: <tmp>/my-repo does NOT exist yet -- ensureBareRepoAt should create it.

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = try allocator.dupe(u8, url),
        .root = "",
    };
    defer freeRepoConfig(allocator, &cfg);

    try ensureBareRepoAt(allocator, testing.io, tmp_path, "my-repo", cfg, central);

    const bare = try std.fmt.allocPrint(allocator, "{s}/my-repo/my-repo.git", .{tmp_path});
    defer allocator.free(bare);
    try testing.expect(dirExists(testing.io, bare));
}

test "ensureBareRepoAt recreates the root folder when missing" {
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const upstream = createTestUpstream(allocator, &tmp, "my-repo") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(upstream);

    const url = try fileUrl(allocator, upstream);
    defer allocator.free(url);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "central.toml", .data = "x = 1\n" });
    const central = try std.fmt.allocPrint(allocator, "{s}/central.toml", .{tmp_path});
    defer allocator.free(central);

    // The root folder itself does not exist -- ensureBareRepoAt should
    // create the entire path.
    const missing_root = try std.fmt.allocPrint(allocator, "{s}/missing/root", .{tmp_path});
    defer allocator.free(missing_root);

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = try allocator.dupe(u8, url),
        .root = "",
    };
    defer freeRepoConfig(allocator, &cfg);

    try ensureBareRepoAt(allocator, testing.io, missing_root, "my-repo", cfg, central);

    const bare = try std.fmt.allocPrint(allocator, "{s}/my-repo/my-repo.git", .{missing_root});
    defer allocator.free(bare);
    try testing.expect(dirExists(testing.io, bare));
}

test "ensureBareRepoAt prefers centrally-recorded root over session_root" {
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const upstream = createTestUpstream(allocator, &tmp, "my-repo") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(upstream);

    const url = try fileUrl(allocator, upstream);
    defer allocator.free(url);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "central.toml", .data = "x = 1\n" });
    const central = try std.fmt.allocPrint(allocator, "{s}/central.toml", .{tmp_path});
    defer allocator.free(central);

    const wrong_root = try std.fmt.allocPrint(allocator, "{s}/wrong", .{tmp_path});
    defer allocator.free(wrong_root);
    const correct_root = try std.fmt.allocPrint(allocator, "{s}/correct", .{tmp_path});
    defer allocator.free(correct_root);

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = try allocator.dupe(u8, url),
        .root = try allocator.dupe(u8, correct_root),
    };
    defer freeRepoConfig(allocator, &cfg);

    // Caller passes the wrong root, but cfg.root says the correct one.
    try ensureBareRepoAt(allocator, testing.io, wrong_root, "my-repo", cfg, central);

    const bare_at_correct = try std.fmt.allocPrint(allocator, "{s}/my-repo/my-repo.git", .{correct_root});
    defer allocator.free(bare_at_correct);
    try testing.expect(dirExists(testing.io, bare_at_correct));

    // The wrong root should not have been touched.
    const bare_at_wrong = try std.fmt.allocPrint(allocator, "{s}/my-repo/my-repo.git", .{wrong_root});
    defer allocator.free(bare_at_wrong);
    try testing.expect(!dirExists(testing.io, bare_at_wrong));
}

test "ensureBareRepoAt returns BareRepoMissingNoCentralConfig when no central path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = try allocator.dupe(u8, "https://example.com/repo.git"),
        .root = "",
    };
    defer freeRepoConfig(allocator, &cfg);

    // Empty central path means "no central config" -> recovery refused.
    const result = ensureBareRepoAt(allocator, testing.io, tmp_path, "my-repo", cfg, "");
    try testing.expectError(error.BareRepoMissingNoCentralConfig, result);
}

test "ensureBareRepoAt returns BareRepoMissingNoCentralConfig when central path doesn't exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = try allocator.dupe(u8, "https://example.com/repo.git"),
        .root = "",
    };
    defer freeRepoConfig(allocator, &cfg);

    const ghost_path = try std.fmt.allocPrint(allocator, "{s}/ghost.toml", .{tmp_path});
    defer allocator.free(ghost_path);

    const result = ensureBareRepoAt(allocator, testing.io, tmp_path, "my-repo", cfg, ghost_path);
    try testing.expectError(error.BareRepoMissingNoCentralConfig, result);
}

test "ensureBareRepoAt returns BareRepoMissingNoOriginUrl when origin_url is empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "central.toml", .data = "x = 1\n" });
    const central = try std.fmt.allocPrint(allocator, "{s}/central.toml", .{tmp_path});
    defer allocator.free(central);

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = "",
        .root = "",
    };
    defer freeRepoConfig(allocator, &cfg);

    const result = ensureBareRepoAt(allocator, testing.io, tmp_path, "my-repo", cfg, central);
    try testing.expectError(error.BareRepoMissingNoOriginUrl, result);
}

test "ensureBareRepoAt returns BareRepoRecloneFailed on bad URL" {
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "central.toml", .data = "x = 1\n" });
    const central = try std.fmt.allocPrint(allocator, "{s}/central.toml", .{tmp_path});
    defer allocator.free(central);

    var cfg = RepoConfig{
        .bare_repo = "",
        .start_branches = .empty,
        .branch_prefixes = .empty,
        .windows = .empty,
        .origin_url = try allocator.dupe(u8, "file:///definitely/not/a/real/repo/path/abcxyz.git"),
        .root = "",
    };
    defer freeRepoConfig(allocator, &cfg);

    const result = ensureBareRepoAt(allocator, testing.io, tmp_path, "my-repo", cfg, central);
    try testing.expectError(error.BareRepoRecloneFailed, result);
}

// ---- dirExists tests ------------------------------------------------------

test "dirExists returns true for existing directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(path);

    try testing.expect(dirExists(testing.io, path));
}

test "dirExists returns false for non-existent path" {
    try testing.expect(!dirExists(testing.io, "/tmp/this_should_not_exist_abc123xyz"));
}
