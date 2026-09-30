const std = @import("std");
const term = @import("term.zig");

// ---------------------------------------------------------------------------
// Global configuration (~/.config/git-session/config.toml)
//
// Format:
//   roots = ["/path/one", "/path/two"]
//   default_branch_prefixes = ["feature", "bugfix", "chore", "refactor", "docs", "test"]
// ---------------------------------------------------------------------------

/// The standard branch-prefix list proposed for newly added repositories
/// when the global config does not specify `default_branch_prefixes`.
/// Stored as a comma-separated string so it can be fed directly to
/// `buildTomlPrefixesArray` / `generateRepoConfigToml`.
pub const default_branch_prefixes_csv = "feature,bugfix,chore,refactor,docs,test";

/// Top-level application configuration holding the list of root folders
/// where managed repositories are stored, plus the default branch-prefix
/// list proposed when adding a new repository.
pub const AppConfig = struct {
    roots: std.ArrayList([]const u8),
    /// Default branch prefixes proposed by the add-repo flow (CLI and
    /// TUI). Populated from `default_branch_prefixes` in config.toml, or
    /// from `default_branch_prefixes_csv` when that key is absent.
    default_branch_prefixes: std.ArrayList([]const u8) = .empty,
};

/// Appends the entries of `default_branch_prefixes_csv` to `list` as
/// heap-duplicated strings. Used to seed `AppConfig.default_branch_prefixes`
/// when the global config omits the key. Caller owns the appended items.
pub fn seedStandardPrefixes(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) !void {
    var iter = std.mem.splitScalar(u8, default_branch_prefixes_csv, ',');
    while (iter.next()) |p_raw| {
        const p = std.mem.trim(u8, p_raw, " \t");
        if (p.len == 0) continue;
        // Dupe into a temporary first so a failing `append` (array-grow
        // OOM) frees the slice instead of orphaning it. Caller owns the
        // appended items and is responsible for freeing them on success.
        const dup = try allocator.dupe(u8, p);
        errdefer allocator.free(dup);
        try list.append(allocator, dup);
    }
}

/// Joins `prefixes` into a comma-separated string suitable for
/// `generateRepoConfigToml` / `buildTomlPrefixesArray`. An empty list
/// yields an empty string. Caller owns the returned slice.
pub fn joinPrefixesCsv(allocator: std.mem.Allocator, prefixes: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var first = true;
    for (prefixes) |p| {
        if (p.len == 0) continue;
        if (!first) try out.append(allocator, ',');
        try out.appendSlice(allocator, p);
        first = false;
    }

    return out.toOwnedSlice(allocator);
}

/// Returns the absolute path to the configuration directory
/// (`~/.config/git-session`). Caller owns the returned slice.
///
/// Returns `error.NoHome` when the `HOME` environment variable is not set.
pub fn getConfigDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/git-session", .{home});
}

/// Returns the absolute path to the centralized per-repo config directory
/// (`~/.config/git-session/repos`). Caller owns the returned slice.
///
/// Returns `error.NoHome` when the `HOME` environment variable is not set.
pub fn getRepoConfigDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const dir = try getConfigDir(allocator, env);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/repos", .{dir});
}

/// Returns the absolute path to the centralized config file for `repo_name`
/// (`~/.config/git-session/repos/<repo-name>.toml`). Caller owns the slice.
pub fn getCentralRepoConfigPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, repo_name: []const u8) ![]u8 {
    const repos_dir = try getRepoConfigDir(allocator, env);
    defer allocator.free(repos_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ repos_dir, repo_name });
}

/// Returns the absolute path to the configuration file
/// (`~/.config/git-session/config.toml`). Caller owns the returned slice.
pub fn getConfigPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const dir = try getConfigDir(allocator, env);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/config.toml", .{dir});
}

/// Writes the TOML `content` for `repo_name` into `repos_dir`, creating
/// the directory (and any missing parents) when necessary. The resulting
/// file path is `<repos_dir>/<repo_name>.toml`.
///
/// This is the path-explicit variant; `writeCentralRepoConfig` is the
/// production wrapper that resolves the user's centralized repos dir.
pub fn writeRepoConfigToDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    repos_dir: []const u8,
    repo_name: []const u8,
    content: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, repos_dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ repos_dir, repo_name });
    defer allocator.free(path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

/// Writes the TOML `content` for `repo_name` to the centralized location
/// (`~/.config/git-session/repos/<repo_name>.toml`), creating the repos
/// directory when missing. Returns `error.NoHome` when `HOME` is unset.
pub fn writeCentralRepoConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    repo_name: []const u8,
    content: []const u8,
) !void {
    const repos_dir = try getRepoConfigDir(allocator, env);
    defer allocator.free(repos_dir);

    try writeRepoConfigToDir(allocator, io, repos_dir, repo_name, content);
}

/// Upserts a single top-level `key = "value"` pair in the TOML file at
/// `path`. If a line `key = …` already exists at the top level (i.e.
/// outside any `[[…]]` section), it is replaced. Otherwise the new line
/// is appended right before the first `[[…]]` section header — or at the
/// end of the file when no section header is present — so that the new
/// pair is always parsed as a top-level key by `parseRepoConfigFile`.
///
/// Comment lines and blank lines are preserved. The file is rewritten
/// atomically only in the loose sense that we hold the entire contents
/// in memory and call `writeFile` once; readers may briefly observe the
/// new contents.
///
/// `value` is written verbatim inside double quotes; callers must ensure
/// it does not itself contain a literal double-quote (the only sources
/// today are clone URLs and absolute paths, neither of which legitimately
/// contain `"`). Returns `error.FileNotFound` when the file does not
/// exist — callers should gate on existence first.
pub fn upsertTomlTopLevelString(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(contents);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var inserted = false;
    var in_section = false;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        // splitScalar yields one final empty element when the input ends
        // with '\n'. Re-emit lines verbatim with their newline separator
        // restored, taking care not to add a trailing newline that the
        // original file did not have.
        if (!first) try out.append(allocator, '\n');
        first = false;

        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        // Track whether we have entered a `[[…]]` (or `[…]`) section so
        // that we don't accidentally rewrite a same-named key inside one.
        if (trimmed.len > 0 and trimmed[0] == '[') {
            // About to emit a section header. If we still need to insert
            // the key, do it just before this header.
            if (!inserted) {
                try writeKeyValue(&out, allocator, key, value);
                try out.append(allocator, '\n');
                inserted = true;
            }
            in_section = true;
            try out.appendSlice(allocator, raw_line);
            continue;
        }

        // Look for an existing top-level `key = …` line and replace it.
        if (!in_section and !inserted) {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const existing_key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                if (std.mem.eql(u8, existing_key, key)) {
                    try writeKeyValue(&out, allocator, key, value);
                    inserted = true;
                    continue;
                }
            }
        }

        try out.appendSlice(allocator, raw_line);
    }

    // No matching key and no section header — append at the very end.
    if (!inserted) {
        // Make sure the appended line is on its own line.
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try writeKeyValue(&out, allocator, key, value);
        try out.append(allocator, '\n');
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// Appends a `key = "value"` TOML pair (without trailing newline) to
/// `out`. Caller is responsible for any surrounding whitespace or
/// newlines. Used by `upsertTomlTopLevelString`.
fn writeKeyValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, " = \"");
    try out.appendSlice(allocator, value);
    try out.append(allocator, '"');
}

/// Deletes the per-repo config file `<repos_dir>/<repo_name>.toml` if it
/// exists. A missing file is *not* an error.
///
/// This is the path-explicit variant; `deleteCentralRepoConfig` is the
/// production wrapper that resolves the user's centralized repos dir.
pub fn deleteRepoConfigFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    repos_dir: []const u8,
    repo_name: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ repos_dir, repo_name });
    defer allocator.free(path);

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Deletes the centralized config file for `repo_name`
/// (`~/.config/git-session/repos/<repo_name>.toml`). Returns
/// `error.NoHome` when `HOME` is unset. A missing file is *not* an
/// error -- callers can use this to ensure the file is gone without
/// first checking whether it exists.
pub fn deleteCentralRepoConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    repo_name: []const u8,
) !void {
    const repos_dir = try getRepoConfigDir(allocator, env);
    defer allocator.free(repos_dir);

    try deleteRepoConfigFromDir(allocator, io, repos_dir, repo_name);
}

/// Reads and parses the global configuration file (`config.toml`).
///
/// Returns `error.ConfigNotFound` when the file is missing or contains
/// no root entries. All strings in the returned `AppConfig` are
/// heap-allocated; release them with `freeAppConfig`.
pub fn loadAppConfig(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !AppConfig {
    const path = try getConfigPath(allocator, env);
    defer allocator.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024)) catch {
        return error.ConfigNotFound;
    };
    defer allocator.free(contents);

    return parseAppConfig(allocator, contents);
}

/// Parses the global configuration from the raw TOML `contents` of a
/// `config.toml` file. This is the pure, file-IO-free core of
/// `loadAppConfig`.
///
/// Returns `error.ConfigNotFound` when no root entries are present. When
/// `default_branch_prefixes` is absent or an explicit empty array, the
/// standard prefix list (`default_branch_prefixes_csv`) is substituted
/// so existing installs and minimal configs get the full set without
/// editing config.toml by hand. All strings in the returned `AppConfig`
/// are heap-allocated; release them with `freeAppConfig`.
pub fn parseAppConfig(allocator: std.mem.Allocator, contents: []const u8) !AppConfig {
    var cfg = AppConfig{ .roots = .empty, .default_branch_prefixes = .empty };
    // Free everything allocated so far if any step below fails (e.g. an
    // allocation error while parsing a later key or while seeding the
    // standard prefix list). The success path returns `cfg` by value, at
    // which point this guard no longer fires.
    errdefer freeAppConfig(allocator, &cfg);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
            const key = std.mem.trim(u8, line[0..eq_pos], " \t");
            const value_raw = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
            // A hand-edited config could repeat a key. Free any previously
            // parsed list before overwriting it so the earlier allocation
            // does not leak (last occurrence wins).
            if (std.mem.eql(u8, key, "roots")) {
                freeArrayListOwned(allocator, &cfg.roots);
                cfg.roots = try parseTomlArray(allocator, value_raw);
            } else if (std.mem.eql(u8, key, "default_branch_prefixes")) {
                freeArrayListOwned(allocator, &cfg.default_branch_prefixes);
                cfg.default_branch_prefixes = try parseTomlArray(allocator, value_raw);
            }
        }
    }

    if (cfg.roots.items.len == 0) {
        return error.ConfigNotFound;
    }

    if (cfg.default_branch_prefixes.items.len == 0) {
        try seedStandardPrefixes(allocator, &cfg.default_branch_prefixes);
    }

    return cfg;
}

/// Serialises the given `AppConfig` to the configuration file on disk,
/// creating the config directory if it does not yet exist.
pub fn saveAppConfig(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, cfg: AppConfig) !void {
    const dir = try getConfigDir(allocator, env);
    defer allocator.free(dir);

    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        term.eprint(io, "Error creating config directory: {any}\n", .{err});
        return err;
    };

    const path = try getConfigPath(allocator, env);
    defer allocator.free(path);

    const out = try serializeAppConfig(allocator, cfg);
    defer allocator.free(out);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out });
}

/// Serialises `cfg` to its `config.toml` textual representation. This is
/// the pure, file-IO-free core of `saveAppConfig`. Caller owns the
/// returned slice.
pub fn serializeAppConfig(allocator: std.mem.Allocator, cfg: AppConfig) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "# Git Session Manager configuration\n");

    try appendTomlArrayLine(allocator, &out, "roots", cfg.roots.items);
    try appendTomlArrayLine(allocator, &out, "default_branch_prefixes", cfg.default_branch_prefixes.items);

    return out.toOwnedSlice(allocator);
}

/// Appends a `key = ["a", "b"]` TOML line (with trailing newline) to
/// `out`. An empty `items` slice renders as `key = []`. Used by
/// `saveAppConfig`.
fn appendTomlArrayLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    items: []const []const u8,
) !void {
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, " = [");
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.append(allocator, '"');
        try out.appendSlice(allocator, item);
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, "]\n");
}

/// Frees every heap-duplicated string in `list`, deinitialises the
/// backing array, and resets `list` to an empty state. Safe to call more
/// than once (the reset makes a subsequent free a no-op), which is what
/// lets `parseAppConfig` free-and-reassign on duplicate keys while still
/// relying on an `errdefer freeAppConfig` that may run afterwards.
fn freeArrayListOwned(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
    list.* = .empty;
}

/// Frees all heap-allocated strings inside `cfg` and deinitialises its
/// internal `ArrayList`s. The struct should not be used after this call.
pub fn freeAppConfig(allocator: std.mem.Allocator, cfg: *AppConfig) void {
    freeArrayListOwned(allocator, &cfg.roots);
    freeArrayListOwned(allocator, &cfg.default_branch_prefixes);
}

/// Runs the interactive first-run setup wizard. Prompts the user for a
/// root folder, creates it on disk, persists a new configuration file,
/// and returns the resulting `AppConfig`. Calls `std.process.exit(1)`
/// when the user provides an empty path or the directory cannot be created.
pub fn runInitFlow(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !AppConfig {
    term.print(io, "\n=== Git Session Manager - First Run Setup ===\n\n", .{});
    term.print(io, "git-session needs at least one root folder where your\n", .{});
    term.print(io, "managed repositories will be stored.\n\n", .{});
    term.print(io, "Root folder (e.g. ~/Developer/Git): ", .{});

    var buf: [1024]u8 = undefined;
    const input = try term.readLine(io, &buf);
    if (input.len == 0) {
        term.eprint(io, "Path cannot be empty.\n", .{});
        std.process.exit(1);
    }

    const path = try term.expandTilde(allocator, env, input);

    std.Io.Dir.cwd().createDirPath(io, path) catch |err| {
        term.eprint(io, "Error creating directory '{s}': {any}\n", .{ path, err });
        std.process.exit(1);
    };

    var cfg = AppConfig{ .roots = .empty, .default_branch_prefixes = .empty };
    try cfg.roots.append(allocator, path);

    // Seed the standard branch-prefix list so it is written into
    // config.toml as an editable template the user can customize later.
    try seedStandardPrefixes(allocator, &cfg.default_branch_prefixes);

    try saveAppConfig(allocator, io, env, cfg);
    term.print(io, "\nConfiguration saved to ~/.config/git-session/config.toml\n", .{});
    term.print(io, "Root: {s}\n\n", .{path});

    return cfg;
}

// ---------------------------------------------------------------------------
// TOML generation helpers
// ---------------------------------------------------------------------------

/// Builds a TOML inline-array literal from a comma-separated `raw` list
/// of prefixes. Each non-empty trimmed entry is rendered as a quoted
/// string; empty or whitespace-only entries are skipped. An empty or
/// all-whitespace input produces `[]`.
///
/// Used to format the `branch_prefixes = [...]` line in generated repo
/// configuration files. Caller owns the returned slice.
pub fn buildTomlPrefixesArray(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.append(allocator, '[');

    var iter = std.mem.splitScalar(u8, raw, ',');
    var first = true;
    while (iter.next()) |p_raw| {
        const p = std.mem.trim(u8, p_raw, " \t");
        if (p.len == 0) continue;
        if (!first) try list.appendSlice(allocator, ", ");
        try list.append(allocator, '"');
        try list.appendSlice(allocator, p);
        try list.append(allocator, '"');
        first = false;
    }
    try list.append(allocator, ']');

    return list.toOwnedSlice(allocator);
}

/// Generates the default per-repository TOML configuration produced by
/// the add-repository flow (both CLI and TUI). The output records:
///
///   - `bare_repo = "<repo_name>"`
///   - `start_branches = ["<default_branch>"]`
///   - `branch_prefixes = [...]` (parsed from `prefixes_raw`)
///   - `origin_url` and `root` recovery fields (used by
///     `repo.ensureBareRepo` to re-clone the bare repository if the
///     user accidentally deletes it or its parent folders).
///   - two default `[[window]]` blocks (`vim` and `git status`).
///
/// `prefixes_raw` is a comma-separated list (e.g. `"feature,bugfix"`);
/// see `buildTomlPrefixesArray` for the exact parsing rules.
///
/// `origin_url` is the clone URL git-session will re-clone from on
/// recovery; `root` is the absolute parent folder under which the repo
/// folder lives. Pass empty strings to omit either field (older
/// callers that don't yet have recovery information).
///
/// Caller owns the returned slice.
pub fn generateRepoConfigToml(
    allocator: std.mem.Allocator,
    repo_name: []const u8,
    default_branch: []const u8,
    prefixes_raw: []const u8,
    origin_url: []const u8,
    root: []const u8,
) ![]u8 {
    const toml_prefixes = try buildTomlPrefixesArray(allocator, prefixes_raw);
    defer allocator.free(toml_prefixes);

    return std.fmt.allocPrint(allocator,
        \\# Git Session configuration for {s}
        \\bare_repo = "{s}"
        \\start_branches = ["{s}"]
        \\branch_prefixes = {s}
        \\origin_url = "{s}"
        \\root = "{s}"
        \\
        \\[[window]]
        \\name = "vim"
        \\command = "vim"
        \\
        \\[[window]]
        \\name = "git"
        \\command = "git status"
        \\
    , .{ repo_name, repo_name, default_branch, toml_prefixes, origin_url, root });
}

// ---------------------------------------------------------------------------
// TOML parsing helpers
// ---------------------------------------------------------------------------

/// Removes surrounding double-quotes from `s` if present.
/// Returns the original slice unchanged when the string is not quoted.
pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

/// Parses a TOML value into an `ArrayList` of heap-duplicated, unquoted
/// strings. Three forms are accepted:
///
///   1. A TOML array:            `["a", "b"]`
///   2. A bracket-less list:     `a, b` or `"a", "b"`
///   3. A single quoted string
///      holding a comma list:    `"a,b"`  ->  `a`, `b`
///
/// Form 3 is a convenience: a user who writes
/// `default_branch_prefixes = "x,y,z"` (a quoted scalar rather than a
/// TOML array) gets the intuitive result `x`, `y`, `z` instead of a
/// single malformed entry. Each element is comma-separated, trimmed of
/// surrounding whitespace, and unquoted; empty elements are skipped.
///
/// `raw` is the right-hand side of a TOML key-value pair. The caller
/// owns every element in the returned list and the list itself.
pub fn parseTomlArray(allocator: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    // Free any partially-built result if an allocation fails mid-loop so
    // the in-flight list (which is never returned on error) does not leak.
    errdefer freeArrayListOwned(allocator, &result);
    var inner = raw;

    if (inner.len >= 2 and inner[0] == '[' and inner[inner.len - 1] == ']') {
        // Form 1: a real TOML array. Strip the brackets; individual
        // elements are unquoted per-item below.
        inner = inner[1 .. inner.len - 1];
    } else if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"' and
        std.mem.indexOfScalar(u8, inner[1 .. inner.len - 1], '"') == null)
    {
        // Form 3: a single quoted scalar (e.g. `"x,y,z"`). Strip the
        // outer quotes so the comma-separated contents are split into
        // individual prefixes rather than yielding one entry with
        // embedded commas. The "no interior quote" guard distinguishes
        // this from a bracket-less list of quoted items like
        // `"a", "b"`, where the outer chars happen to be quotes but the
        // value is not a single string.
        inner = inner[1 .. inner.len - 1];
    }

    var iter = std.mem.splitScalar(u8, inner, ',');
    while (iter.next()) |item_raw| {
        const item = std.mem.trim(u8, item_raw, " \t");
        if (item.len == 0) continue;
        const unquoted = stripQuotes(item);
        if (unquoted.len == 0) continue;
        // Duplicate into a temporary first so that if `append` fails (its
        // array-grow can OOM) the freshly-duped slice is freed rather than
        // orphaned — `result`'s errdefer only frees items already stored.
        const dup = try allocator.dupe(u8, unquoted);
        errdefer allocator.free(dup);
        try result.append(allocator, dup);
    }
    return result;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn freeArrayList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

test "buildTomlPrefixesArray formats single prefix" {
    const out = try buildTomlPrefixesArray(testing.allocator, "feature");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[\"feature\"]", out);
}

test "buildTomlPrefixesArray formats multiple comma-separated prefixes" {
    const out = try buildTomlPrefixesArray(testing.allocator, "feature,bugfix,hotfix");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[\"feature\", \"bugfix\", \"hotfix\"]", out);
}

test "buildTomlPrefixesArray trims whitespace around prefixes" {
    const out = try buildTomlPrefixesArray(testing.allocator, "  feature ,\tbugfix  ");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[\"feature\", \"bugfix\"]", out);
}

test "buildTomlPrefixesArray skips empty entries" {
    const out = try buildTomlPrefixesArray(testing.allocator, "feature,,bugfix,");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[\"feature\", \"bugfix\"]", out);
}

test "buildTomlPrefixesArray emits empty array for empty input" {
    const out = try buildTomlPrefixesArray(testing.allocator, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[]", out);
}

test "buildTomlPrefixesArray emits empty array for whitespace-only input" {
    const out = try buildTomlPrefixesArray(testing.allocator, "  ,  ,\t");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[]", out);
}

test "generateRepoConfigToml renders all expected fields" {
    const allocator = testing.allocator;
    const toml = try generateRepoConfigToml(
        allocator,
        "my-project",
        "main",
        "feature,bugfix",
        "git@github.com:me/my-project.git",
        "/Users/me/Developer",
    );
    defer allocator.free(toml);

    try testing.expect(std.mem.indexOf(u8, toml, "# Git Session configuration for my-project") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "bare_repo = \"my-project\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "start_branches = [\"main\"]") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "branch_prefixes = [\"feature\", \"bugfix\"]") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "origin_url = \"git@github.com:me/my-project.git\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "root = \"/Users/me/Developer\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "[[window]]") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "name = \"vim\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "name = \"git\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "command = \"git status\"") != null);
}

test "generateRepoConfigToml accepts empty prefix list" {
    const allocator = testing.allocator;
    const toml = try generateRepoConfigToml(allocator, "api", "develop", "", "", "");
    defer allocator.free(toml);

    try testing.expect(std.mem.indexOf(u8, toml, "branch_prefixes = []") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "start_branches = [\"develop\"]") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "bare_repo = \"api\"") != null);
    // Recovery fields are still emitted (as empty strings) so the
    // line-based reader sees them; an empty value just means "not
    // populated yet" and triggers the silent backfill in `openRepo`.
    try testing.expect(std.mem.indexOf(u8, toml, "origin_url = \"\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml, "root = \"\"") != null);
}

test "stripQuotes removes surrounding double quotes" {
    try testing.expectEqualStrings("hello", stripQuotes("\"hello\""));
}

test "stripQuotes leaves unquoted strings unchanged" {
    try testing.expectEqualStrings("hello", stripQuotes("hello"));
}

test "stripQuotes leaves single-char strings unchanged" {
    try testing.expectEqualStrings("x", stripQuotes("x"));
}

test "stripQuotes handles empty string" {
    try testing.expectEqualStrings("", stripQuotes(""));
}

test "stripQuotes only removes matching outer quotes" {
    try testing.expectEqualStrings("\"hello", stripQuotes("\"hello"));
    try testing.expectEqualStrings("hello\"", stripQuotes("hello\""));
}

test "stripQuotes handles string that is just two quotes" {
    try testing.expectEqualStrings("", stripQuotes("\"\""));
}

test "parseTomlArray parses bracketed quoted array" {
    const allocator = testing.allocator;
    var result = try parseTomlArray(allocator, "[\"path/one\", \"path/two\"]");
    defer freeArrayList(allocator, &result);

    try testing.expectEqual(@as(usize, 2), result.items.len);
    try testing.expectEqualStrings("path/one", result.items[0]);
    try testing.expectEqualStrings("path/two", result.items[1]);
}

test "parseTomlArray parses array without brackets" {
    const allocator = testing.allocator;
    var result = try parseTomlArray(allocator, "\"a\", \"b\", \"c\"");
    defer freeArrayList(allocator, &result);

    try testing.expectEqual(@as(usize, 3), result.items.len);
    try testing.expectEqualStrings("a", result.items[0]);
    try testing.expectEqualStrings("b", result.items[1]);
    try testing.expectEqualStrings("c", result.items[2]);
}

test "parseTomlArray handles single element" {
    const allocator = testing.allocator;
    var result = try parseTomlArray(allocator, "[\"only\"]");
    defer freeArrayList(allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("only", result.items[0]);
}

test "parseTomlArray handles empty array" {
    const allocator = testing.allocator;
    var result = try parseTomlArray(allocator, "[]");
    defer freeArrayList(allocator, &result);

    try testing.expectEqual(@as(usize, 0), result.items.len);
}

test "parseTomlArray handles unquoted values" {
    const allocator = testing.allocator;
    var result = try parseTomlArray(allocator, "[bare_value]");
    defer freeArrayList(allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("bare_value", result.items[0]);
}

test "parseTomlArray trims whitespace around elements" {
    const allocator = testing.allocator;
    var result = try parseTomlArray(allocator, "[  \"spaced\"  ,  \"out\"  ]");
    defer freeArrayList(allocator, &result);

    try testing.expectEqual(@as(usize, 2), result.items.len);
    try testing.expectEqualStrings("spaced", result.items[0]);
    try testing.expectEqualStrings("out", result.items[1]);
}

test "parseTomlArray splits a quoted comma-separated scalar" {
    // A user who writes `default_branch_prefixes = "x,y,z"` (a quoted
    // string rather than a TOML array) should get three prefixes, not a
    // single malformed entry.
    const allocator = testing.allocator;
    var result = try parseTomlArray(allocator, "\"x,y,z\"");
    defer freeArrayList(allocator, &result);

    try testing.expectEqual(@as(usize, 3), result.items.len);
    try testing.expectEqualStrings("x", result.items[0]);
    try testing.expectEqualStrings("y", result.items[1]);
    try testing.expectEqualStrings("z", result.items[2]);
}

test "parseTomlArray splits a quoted scalar with spaces" {
    const allocator = testing.allocator;
    var result = try parseTomlArray(allocator, "\"feature, bugfix , chore\"");
    defer freeArrayList(allocator, &result);

    try testing.expectEqual(@as(usize, 3), result.items.len);
    try testing.expectEqualStrings("feature", result.items[0]);
    try testing.expectEqualStrings("bugfix", result.items[1]);
    try testing.expectEqualStrings("chore", result.items[2]);
}

test "parseTomlArray handles a single quoted scalar without commas" {
    const allocator = testing.allocator;
    var result = try parseTomlArray(allocator, "\"feature\"");
    defer freeArrayList(allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("feature", result.items[0]);
}

test "writeRepoConfigToDir writes file to <dir>/<name>.toml" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const content = "bare_repo = \"my-project\"\n";
    try writeRepoConfigToDir(allocator, testing.io, tmp_path, "my-project", content);

    const expected_path = try std.fmt.allocPrint(allocator, "{s}/my-project.toml", .{tmp_path});
    defer allocator.free(expected_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, expected_path, allocator, .limited(4096));
    defer allocator.free(written);
    try testing.expectEqualStrings(content, written);
}

test "writeRepoConfigToDir creates the target directory when missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const repos_dir = try std.fmt.allocPrint(allocator, "{s}/nested/repos", .{tmp_path});
    defer allocator.free(repos_dir);

    try writeRepoConfigToDir(allocator, testing.io, repos_dir, "frontend", "bare_repo = \"frontend\"\n");

    const expected_path = try std.fmt.allocPrint(allocator, "{s}/frontend.toml", .{repos_dir});
    defer allocator.free(expected_path);

    var f = try std.Io.Dir.cwd().openFile(testing.io, expected_path, .{});
    f.close(testing.io);
}

test "writeRepoConfigToDir overwrites an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    try writeRepoConfigToDir(allocator, testing.io, tmp_path, "api", "old = true\n");
    try writeRepoConfigToDir(allocator, testing.io, tmp_path, "api", "new = true\n");

    const expected_path = try std.fmt.allocPrint(allocator, "{s}/api.toml", .{tmp_path});
    defer allocator.free(expected_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, expected_path, allocator, .limited(4096));
    defer allocator.free(written);
    try testing.expectEqualStrings("new = true\n", written);
}

test "deleteRepoConfigFromDir removes existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    try writeRepoConfigToDir(allocator, testing.io, tmp_path, "doomed", "bare_repo = \"doomed\"\n");

    const file_path = try std.fmt.allocPrint(allocator, "{s}/doomed.toml", .{tmp_path});
    defer allocator.free(file_path);

    // Sanity check: the file exists before deletion.
    {
        var f = try std.Io.Dir.cwd().openFile(testing.io, file_path, .{});
        f.close(testing.io);
    }

    try deleteRepoConfigFromDir(allocator, testing.io, tmp_path, "doomed");

    // After deletion the file is gone.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(testing.io, file_path, .{}));
}

test "deleteRepoConfigFromDir is a no-op when the file is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    // Should not error when nothing exists.
    try deleteRepoConfigFromDir(allocator, testing.io, tmp_path, "ghost");

    // And calling it twice in a row is fine.
    try writeRepoConfigToDir(allocator, testing.io, tmp_path, "doomed", "x = 1\n");
    try deleteRepoConfigFromDir(allocator, testing.io, tmp_path, "doomed");
    try deleteRepoConfigFromDir(allocator, testing.io, tmp_path, "doomed");
}

// ---- upsertTomlTopLevelString tests ---------------------------------------

test "upsertTomlTopLevelString appends when key is absent and no section" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    try writeRepoConfigToDir(allocator, testing.io, tmp_path, "repo", "bare_repo = \"repo\"\n");
    const file_path = try std.fmt.allocPrint(allocator, "{s}/repo.toml", .{tmp_path});
    defer allocator.free(file_path);

    try upsertTomlTopLevelString(allocator, testing.io, file_path, "origin_url", "https://example.com/repo.git");

    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, file_path, allocator, .limited(4096));
    defer allocator.free(written);

    try testing.expectEqualStrings(
        "bare_repo = \"repo\"\norigin_url = \"https://example.com/repo.git\"\n",
        written,
    );
}

test "upsertTomlTopLevelString replaces existing top-level key in place" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    try writeRepoConfigToDir(
        allocator,
        testing.io,
        tmp_path,
        "repo",
        "bare_repo = \"repo\"\norigin_url = \"old\"\nstart_branches = [\"main\"]\n",
    );
    const file_path = try std.fmt.allocPrint(allocator, "{s}/repo.toml", .{tmp_path});
    defer allocator.free(file_path);

    try upsertTomlTopLevelString(allocator, testing.io, file_path, "origin_url", "https://new/url.git");

    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, file_path, allocator, .limited(4096));
    defer allocator.free(written);

    try testing.expectEqualStrings(
        "bare_repo = \"repo\"\norigin_url = \"https://new/url.git\"\nstart_branches = [\"main\"]\n",
        written,
    );
}

test "upsertTomlTopLevelString inserts before first [[section]] header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    try writeRepoConfigToDir(
        allocator,
        testing.io,
        tmp_path,
        "repo",
        "bare_repo = \"repo\"\nstart_branches = [\"main\"]\n\n[[window]]\nname = \"vim\"\ncommand = \"vim\"\n",
    );
    const file_path = try std.fmt.allocPrint(allocator, "{s}/repo.toml", .{tmp_path});
    defer allocator.free(file_path);

    try upsertTomlTopLevelString(allocator, testing.io, file_path, "origin_url", "git@host:o/r.git");

    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, file_path, allocator, .limited(4096));
    defer allocator.free(written);

    // The new key must precede the [[window]] section header so that the
    // line-based parser treats it as a top-level field.
    try testing.expect(std.mem.indexOf(u8, written, "origin_url = \"git@host:o/r.git\"") != null);
    const idx_origin = std.mem.indexOf(u8, written, "origin_url").?;
    const idx_window = std.mem.indexOf(u8, written, "[[window]]").?;
    try testing.expect(idx_origin < idx_window);
}

test "upsertTomlTopLevelString does not rewrite same-named key inside section" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    // A `name = …` exists inside `[[window]]`; we must not touch it
    // when upserting a top-level `name` (this is defensive — current
    // callers only use distinct keys like `origin_url`/`root`).
    try writeRepoConfigToDir(
        allocator,
        testing.io,
        tmp_path,
        "repo",
        "bare_repo = \"repo\"\n\n[[window]]\nname = \"vim\"\n",
    );
    const file_path = try std.fmt.allocPrint(allocator, "{s}/repo.toml", .{tmp_path});
    defer allocator.free(file_path);

    try upsertTomlTopLevelString(allocator, testing.io, file_path, "name", "top-level-name");

    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, file_path, allocator, .limited(4096));
    defer allocator.free(written);

    try testing.expect(std.mem.indexOf(u8, written, "name = \"top-level-name\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "name = \"vim\"") != null);
}

test "upsertTomlTopLevelString returns FileNotFound when the file does not exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/missing.toml", .{tmp_path});
    defer allocator.free(file_path);

    try testing.expectError(error.FileNotFound, upsertTomlTopLevelString(allocator, testing.io, file_path, "k", "v"));
}

test "deleteRepoConfigFromDir leaves siblings untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    try writeRepoConfigToDir(allocator, testing.io, tmp_path, "keep-me", "bare_repo = \"keep\"\n");
    try writeRepoConfigToDir(allocator, testing.io, tmp_path, "doomed", "bare_repo = \"doomed\"\n");

    try deleteRepoConfigFromDir(allocator, testing.io, tmp_path, "doomed");

    const sibling_path = try std.fmt.allocPrint(allocator, "{s}/keep-me.toml", .{tmp_path});
    defer allocator.free(sibling_path);

    // Sibling still exists and is unchanged.
    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, sibling_path, allocator, .limited(4096));
    defer allocator.free(written);
    try testing.expectEqualStrings("bare_repo = \"keep\"\n", written);
}

// ---- default_branch_prefixes / AppConfig tests ----------------------------

test "joinPrefixesCsv joins multiple prefixes with commas" {
    const out = try joinPrefixesCsv(testing.allocator, &.{ "feature", "bugfix", "chore" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("feature,bugfix,chore", out);
}

test "joinPrefixesCsv handles a single prefix" {
    const out = try joinPrefixesCsv(testing.allocator, &.{"feature"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("feature", out);
}

test "joinPrefixesCsv yields empty string for empty list" {
    const out = try joinPrefixesCsv(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "joinPrefixesCsv skips empty entries" {
    const out = try joinPrefixesCsv(testing.allocator, &.{ "feature", "", "docs" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("feature,docs", out);
}

test "seedStandardPrefixes populates the standard six-item list" {
    const allocator = testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer freeArrayList(allocator, &list);

    try seedStandardPrefixes(allocator, &list);

    try testing.expectEqual(@as(usize, 6), list.items.len);
    try testing.expectEqualStrings("feature", list.items[0]);
    try testing.expectEqualStrings("bugfix", list.items[1]);
    try testing.expectEqualStrings("chore", list.items[2]);
    try testing.expectEqualStrings("refactor", list.items[3]);
    try testing.expectEqualStrings("docs", list.items[4]);
    try testing.expectEqualStrings("test", list.items[5]);
}

test "parseAppConfig reads roots and default_branch_prefixes" {
    const allocator = testing.allocator;
    var cfg = try parseAppConfig(
        allocator,
        "roots = [\"/a\", \"/b\"]\ndefault_branch_prefixes = [\"feature\", \"bugfix\"]\n",
    );
    defer freeAppConfig(allocator, &cfg);

    try testing.expectEqual(@as(usize, 2), cfg.roots.items.len);
    try testing.expectEqualStrings("/a", cfg.roots.items[0]);
    try testing.expectEqual(@as(usize, 2), cfg.default_branch_prefixes.items.len);
    try testing.expectEqualStrings("feature", cfg.default_branch_prefixes.items[0]);
    try testing.expectEqualStrings("bugfix", cfg.default_branch_prefixes.items[1]);
}

test "parseAppConfig falls back to standard list when key is absent" {
    const allocator = testing.allocator;
    var cfg = try parseAppConfig(allocator, "roots = [\"/a\"]\n");
    defer freeAppConfig(allocator, &cfg);

    // Absent default_branch_prefixes => standard six-item list.
    try testing.expectEqual(@as(usize, 6), cfg.default_branch_prefixes.items.len);
    try testing.expectEqualStrings("feature", cfg.default_branch_prefixes.items[0]);
    try testing.expectEqualStrings("test", cfg.default_branch_prefixes.items[5]);
}

test "parseAppConfig accepts a quoted comma-separated prefix string" {
    // Regression: `default_branch_prefixes = "x,y,z"` (quoted scalar)
    // must yield the three prefixes and not fall back to the standard
    // list.
    const allocator = testing.allocator;
    var cfg = try parseAppConfig(
        allocator,
        "roots = [\"/a\"]\ndefault_branch_prefixes = \"x,y,z\"\n",
    );
    defer freeAppConfig(allocator, &cfg);

    try testing.expectEqual(@as(usize, 3), cfg.default_branch_prefixes.items.len);
    try testing.expectEqualStrings("x", cfg.default_branch_prefixes.items[0]);
    try testing.expectEqualStrings("y", cfg.default_branch_prefixes.items[1]);
    try testing.expectEqualStrings("z", cfg.default_branch_prefixes.items[2]);
}

test "parseAppConfig falls back to standard list for explicit empty array" {
    const allocator = testing.allocator;
    var cfg = try parseAppConfig(
        allocator,
        "roots = [\"/a\"]\ndefault_branch_prefixes = []\n",
    );
    defer freeAppConfig(allocator, &cfg);

    try testing.expectEqual(@as(usize, 6), cfg.default_branch_prefixes.items.len);
}

test "parseAppConfig returns ConfigNotFound when no roots" {
    const allocator = testing.allocator;
    try testing.expectError(
        error.ConfigNotFound,
        parseAppConfig(allocator, "default_branch_prefixes = [\"feature\"]\n"),
    );
}

test "parseAppConfig keeps the last value for a duplicated key without leaking" {
    // A hand-edited config may repeat a key. The last occurrence wins and
    // the earlier list must not leak (testing.allocator fails the test on
    // a leak).
    const allocator = testing.allocator;
    var cfg = try parseAppConfig(
        allocator,
        "roots = [\"/first\"]\nroots = [\"/second\"]\n" ++
            "default_branch_prefixes = [\"a\"]\ndefault_branch_prefixes = [\"b\", \"c\"]\n",
    );
    defer freeAppConfig(allocator, &cfg);

    try testing.expectEqual(@as(usize, 1), cfg.roots.items.len);
    try testing.expectEqualStrings("/second", cfg.roots.items[0]);
    try testing.expectEqual(@as(usize, 2), cfg.default_branch_prefixes.items.len);
    try testing.expectEqualStrings("b", cfg.default_branch_prefixes.items[0]);
    try testing.expectEqualStrings("c", cfg.default_branch_prefixes.items[1]);
}

test "parseAppConfig does not leak when an allocation fails" {
    // Drive parsing under a failing allocator across a range of failure
    // points. Any allocation failure must propagate cleanly with no leak
    // (the errdefer frees partially-built state). FailingAllocator's leak
    // accounting asserts on scope exit.
    const contents =
        "roots = [\"/a\", \"/b\"]\ndefault_branch_prefixes = [\"feature\", \"bugfix\"]\n";

    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        if (parseAppConfig(allocator, contents)) |parsed| {
            var p = parsed;
            freeAppConfig(allocator, &p);
            // Once parsing succeeds before the injected failure point,
            // higher indices succeed too; nothing more to probe.
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "parseAppConfig does not leak when seeding the fallback fails" {
    // Same probe but for a config that omits default_branch_prefixes, so
    // the failure can land inside seedStandardPrefixes after roots and
    // possibly some prefixes are already allocated.
    const contents = "roots = [\"/a\"]\n";

    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        if (parseAppConfig(allocator, contents)) |parsed| {
            var p = parsed;
            freeAppConfig(allocator, &p);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "serializeAppConfig emits roots and default_branch_prefixes lines" {
    const allocator = testing.allocator;

    var cfg = AppConfig{ .roots = .empty, .default_branch_prefixes = .empty };
    defer freeAppConfig(allocator, &cfg);
    try cfg.roots.append(allocator, try allocator.dupe(u8, "/Users/me/Dev"));
    try cfg.default_branch_prefixes.append(allocator, try allocator.dupe(u8, "feature"));
    try cfg.default_branch_prefixes.append(allocator, try allocator.dupe(u8, "bugfix"));

    const out = try serializeAppConfig(allocator, cfg);
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "roots = [\"/Users/me/Dev\"]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "default_branch_prefixes = [\"feature\", \"bugfix\"]") != null);
}

test "serializeAppConfig then parseAppConfig round-trips a custom list" {
    const allocator = testing.allocator;

    var cfg = AppConfig{ .roots = .empty, .default_branch_prefixes = .empty };
    defer freeAppConfig(allocator, &cfg);
    try cfg.roots.append(allocator, try allocator.dupe(u8, "/root"));
    try cfg.default_branch_prefixes.append(allocator, try allocator.dupe(u8, "feat"));
    try cfg.default_branch_prefixes.append(allocator, try allocator.dupe(u8, "fix"));

    const out = try serializeAppConfig(allocator, cfg);
    defer allocator.free(out);

    var parsed = try parseAppConfig(allocator, out);
    defer freeAppConfig(allocator, &parsed);

    try testing.expectEqual(@as(usize, 1), parsed.roots.items.len);
    try testing.expectEqualStrings("/root", parsed.roots.items[0]);
    // The custom (non-empty) list must survive the round-trip rather than
    // being replaced by the standard fallback.
    try testing.expectEqual(@as(usize, 2), parsed.default_branch_prefixes.items.len);
    try testing.expectEqualStrings("feat", parsed.default_branch_prefixes.items[0]);
    try testing.expectEqualStrings("fix", parsed.default_branch_prefixes.items[1]);
}
