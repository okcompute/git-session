const std = @import("std");
const repo_mod = @import("repo.zig");

// ---------------------------------------------------------------------------
// Usage tracking (~/.cache/git-session/usage.toml)
//
// Persists a simple count of how many times each repository has been
// selected so that the repository list can be sorted most-used-first.
//
// The file is placed in the XDG cache directory ($XDG_CACHE_HOME/git-session,
// defaulting to ~/.cache/git-session) so that dotfile managers tracking
// ~/.config do not pick it up.
//
// Format:
//   repo-name = 5
//   other-repo = 12
// ---------------------------------------------------------------------------

/// A single entry mapping a repository name to its cumulative usage count.
pub const UsageEntry = struct {
    name: []const u8,
    count: u64,
};

/// In-memory representation of the usage data loaded from disk.
pub const UsageData = struct {
    entries: std.ArrayList(UsageEntry),
};

const usage_filename = "usage.toml";

/// Builds the XDG cache directory path for git-session from the provided
/// environment values. `xdg_cache_home` is the value of `$XDG_CACHE_HOME`
/// (null when unset); `home` is the value of `$HOME`. Caller owns the result.
fn buildUsageCacheDir(allocator: std.mem.Allocator, xdg_cache_home: ?[]const u8, home: []const u8) ![]u8 {
    if (xdg_cache_home) |xdg_cache| {
        return std.fmt.allocPrint(allocator, "{s}/git-session", .{xdg_cache});
    }
    return std.fmt.allocPrint(allocator, "{s}/.cache/git-session", .{home});
}

/// Returns the XDG cache directory for git-session
/// (`$XDG_CACHE_HOME/git-session`, defaulting to `~/.cache/git-session`).
/// Caller owns the returned slice.
fn getUsageCacheDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const home = env.get("HOME") orelse return error.NoHome;
    return buildUsageCacheDir(allocator, env.get("XDG_CACHE_HOME"), home);
}

/// Returns the absolute path to the usage data file
/// (`~/.cache/git-session/usage.toml`). Caller owns the returned slice.
fn getUsagePath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const dir = try getUsageCacheDir(allocator, env);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, usage_filename });
}

/// Loads the usage data file from disk. Returns an empty `UsageData`
/// when the file does not exist or cannot be read. All `name` strings
/// inside the returned struct are heap-allocated; release them with
/// `freeUsageData`.
pub fn loadUsageData(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) UsageData {
    var data = UsageData{ .entries = .empty };

    const path = getUsagePath(allocator, env) catch return data;
    defer allocator.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024)) catch return data;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
            const key = std.mem.trim(u8, line[0..eq_pos], " \t");
            const value_raw = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

            if (key.len == 0) continue;
            const count = std.fmt.parseInt(u64, value_raw, 10) catch continue;

            data.entries.append(allocator, .{
                .name = allocator.dupe(u8, key) catch continue,
                .count = count,
            }) catch continue;
        }
    }

    return data;
}

/// Persists the usage data to disk, creating the cache directory if
/// necessary.
pub fn saveUsageData(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, data: UsageData) !void {
    const dir = try getUsageCacheDir(allocator, env);
    defer allocator.free(dir);

    try std.Io.Dir.cwd().createDirPath(io, dir);

    const path = try getUsagePath(allocator, env);
    defer allocator.free(path);

    var buf: [8192]u8 = undefined;
    var offset: usize = 0;

    const header = "# Git Session Manager - repository usage counts\n";
    @memcpy(buf[offset .. offset + header.len], header);
    offset += header.len;

    for (data.entries.items) |entry| {
        const line = std.fmt.bufPrint(buf[offset..], "{s} = {d}\n", .{ entry.name, entry.count }) catch break;
        offset += line.len;
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf[0..offset] });
}

/// Frees all heap-allocated strings inside `data` and deinitialises
/// its internal `ArrayList`.
pub fn freeUsageData(allocator: std.mem.Allocator, data: *UsageData) void {
    for (data.entries.items) |e| allocator.free(e.name);
    data.entries.deinit(allocator);
}

/// Increments the usage count for `repo_name` (adding a new entry if
/// it does not yet exist) and persists the updated data to disk.
pub fn recordUsage(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, repo_name: []const u8) void {
    var data = loadUsageData(allocator, io, env);
    defer freeUsageData(allocator, &data);

    for (data.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.name, repo_name)) {
            entry.count += 1;
            saveUsageData(allocator, io, env, data) catch {};
            return;
        }
    }

    // New entry
    data.entries.append(allocator, .{
        .name = allocator.dupe(u8, repo_name) catch return,
        .count = 1,
    }) catch return;
    saveUsageData(allocator, io, env, data) catch {};
}

/// Returns the usage count for `repo_name`, or 0 if not found.
fn getCount(data: *const UsageData, name: []const u8) u64 {
    for (data.entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.count;
    }
    return 0;
}

/// Sorts `entries` in-place so that repositories with higher usage
/// counts appear first. Repositories with equal counts retain their
/// relative order (stable sort).
pub fn sortByUsage(data: *const UsageData, entries: []repo_mod.RepoEntry) void {
    const Context = struct {
        usage: *const UsageData,

        pub fn lessThan(ctx: @This(), a: repo_mod.RepoEntry, b: repo_mod.RepoEntry) bool {
            const ca = getCount(ctx.usage, a.name);
            const cb = getCount(ctx.usage, b.name);
            return ca > cb; // descending order
        }
    };
    std.sort.insertion(repo_mod.RepoEntry, entries, Context{ .usage = data }, Context.lessThan);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "loadUsageData does not crash when called" {
    // loadUsageData should always return a valid UsageData struct,
    // regardless of whether the usage file exists on disk or not.
    const allocator = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, allocator);
    defer env.deinit();

    var data = loadUsageData(allocator, testing.io, &env);
    defer freeUsageData(allocator, &data);

    // Verify the returned data is structurally valid (entries may be
    // empty or populated depending on the host environment).
    for (data.entries.items) |entry| {
        try testing.expect(entry.name.len > 0);
    }
}

test "sortByUsage orders repos by descending count" {
    const allocator = testing.allocator;

    var data = UsageData{ .entries = .empty };
    defer freeUsageData(allocator, &data);

    try data.entries.append(allocator, .{ .name = try allocator.dupe(u8, "alpha"), .count = 2 });
    try data.entries.append(allocator, .{ .name = try allocator.dupe(u8, "beta"), .count = 10 });
    try data.entries.append(allocator, .{ .name = try allocator.dupe(u8, "gamma"), .count = 5 });

    // Build repo entries in arbitrary order
    var entries_list: std.ArrayList(repo_mod.RepoEntry) = .empty;
    defer {
        for (entries_list.items) |e| allocator.free(e.name);
        entries_list.deinit(allocator);
    }

    try entries_list.append(allocator, .{ .name = try allocator.dupe(u8, "alpha"), .root = "r" });
    try entries_list.append(allocator, .{ .name = try allocator.dupe(u8, "beta"), .root = "r" });
    try entries_list.append(allocator, .{ .name = try allocator.dupe(u8, "gamma"), .root = "r" });

    sortByUsage(&data, entries_list.items);

    try testing.expectEqualStrings("beta", entries_list.items[0].name);
    try testing.expectEqualStrings("gamma", entries_list.items[1].name);
    try testing.expectEqualStrings("alpha", entries_list.items[2].name);
}

test "sortByUsage keeps unused repos at the end" {
    const allocator = testing.allocator;

    var data = UsageData{ .entries = .empty };
    defer freeUsageData(allocator, &data);

    try data.entries.append(allocator, .{ .name = try allocator.dupe(u8, "used"), .count = 3 });

    var entries_list: std.ArrayList(repo_mod.RepoEntry) = .empty;
    defer {
        for (entries_list.items) |e| allocator.free(e.name);
        entries_list.deinit(allocator);
    }

    try entries_list.append(allocator, .{ .name = try allocator.dupe(u8, "unused"), .root = "r" });
    try entries_list.append(allocator, .{ .name = try allocator.dupe(u8, "used"), .root = "r" });

    sortByUsage(&data, entries_list.items);

    try testing.expectEqualStrings("used", entries_list.items[0].name);
    try testing.expectEqualStrings("unused", entries_list.items[1].name);
}

test "sortByUsage is stable for equal counts" {
    const allocator = testing.allocator;

    var data = UsageData{ .entries = .empty };
    defer freeUsageData(allocator, &data);

    // No usage data at all — all repos have count 0
    var entries_list: std.ArrayList(repo_mod.RepoEntry) = .empty;
    defer {
        for (entries_list.items) |e| allocator.free(e.name);
        entries_list.deinit(allocator);
    }

    try entries_list.append(allocator, .{ .name = try allocator.dupe(u8, "aaa"), .root = "r" });
    try entries_list.append(allocator, .{ .name = try allocator.dupe(u8, "bbb"), .root = "r" });
    try entries_list.append(allocator, .{ .name = try allocator.dupe(u8, "ccc"), .root = "r" });

    sortByUsage(&data, entries_list.items);

    // Order should be unchanged (insertion sort is stable)
    try testing.expectEqualStrings("aaa", entries_list.items[0].name);
    try testing.expectEqualStrings("bbb", entries_list.items[1].name);
    try testing.expectEqualStrings("ccc", entries_list.items[2].name);
}

test "buildUsageCacheDir uses XDG_CACHE_HOME when set" {
    const allocator = testing.allocator;
    const dir = try buildUsageCacheDir(allocator, "/custom/cache", "/home/user");
    defer allocator.free(dir);
    try testing.expectEqualStrings("/custom/cache/git-session", dir);
}

test "buildUsageCacheDir falls back to HOME/.cache when XDG_CACHE_HOME is unset" {
    const allocator = testing.allocator;
    const dir = try buildUsageCacheDir(allocator, null, "/home/user");
    defer allocator.free(dir);
    try testing.expectEqualStrings("/home/user/.cache/git-session", dir);
}

test "getCount returns 0 for unknown repos" {
    const allocator = testing.allocator;

    var data = UsageData{ .entries = .empty };
    defer freeUsageData(allocator, &data);

    try data.entries.append(allocator, .{ .name = try allocator.dupe(u8, "known"), .count = 7 });

    try testing.expectEqual(@as(u64, 7), getCount(&data, "known"));
    try testing.expectEqual(@as(u64, 0), getCount(&data, "unknown"));
}
