const std = @import("std");
const mux = @import("mux.zig");

/// CLI operation requested by the user as a subcommand.
pub const CliOperation = enum {
    /// Create a new session (worktree + branch + tmux session).
    create,
    /// Remove an existing session.
    remove,
    /// Fix a session by recreating its tmux session.
    fix,
};

/// Parsed command-line arguments that drive the initial application state.
///
/// When `operation` is set alongside `repository`, the application jumps
/// directly to the relevant screen. When all fields needed for an operation
/// are provided the application runs fully non-interactively; when some are
/// missing the TUI opens at the step where the remaining information is
/// collected.
pub const CliArgs = struct {
    /// Name of the repository to pre-select (matches directory name under a root).
    repository: ?[]const u8 = null,
    /// Subcommand operation to perform.
    operation: ?CliOperation = null,
    /// Session name (worktree name) for create / remove / fix.
    session: ?[]const u8 = null,
    /// Base branch to create the worktree from (create only).
    branch: ?[]const u8 = null,
    /// Branch prefix (create only).
    prefix: ?[]const u8 = null,
    /// Close the existing session and recreate it (fix only).
    replace: bool = false,
};

/// Errors reported while extracting the global `--multiplexer` flag.
pub const ExtractMultiplexerError = error{
    /// `--multiplexer` appeared at the end of `args` with no following value.
    MissingMultiplexerValue,
    /// The value following `--multiplexer` was not recognised by `mux.Kind.parse`.
    InvalidMultiplexerValue,
    /// Allocating the filtered argument slice failed.
    OutOfMemory,
};

/// Result of stripping `--multiplexer <value>` from a raw argument slice.
///
/// `remaining` is heap-allocated and owned by the caller (free with
/// `allocator.free`). Both its string elements and `multiplexer` are
/// borrowed from the input `args` slice.
pub const MultiplexerExtraction = struct {
    /// Arguments with every `--multiplexer <value>` pair removed, keeping `args[0]`.
    remaining: [][]const u8,
    /// Value supplied to `--multiplexer`, or `null` if the flag was absent.
    multiplexer: ?[]const u8,
};

/// Scans `args[1..]` for `--multiplexer <value>`, validates the value with
/// `mux.Kind.parse`, and returns a copy of `args` with the flag and its value
/// removed. `args[0]` (the program name) is always preserved untouched.
/// `--multiplexer` is treated as a reserved global flag anywhere in `args[1..]`.
///
/// If `--multiplexer` appears more than once, every occurrence is validated
/// and stripped, and the last value wins.
///
/// Caller owns `result.remaining` and must free it with `allocator.free`.
pub fn extractMultiplexerFlag(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) ExtractMultiplexerError!MultiplexerExtraction {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    if (args.len == 0) {
        return .{ .remaining = try list.toOwnedSlice(allocator), .multiplexer = null };
    }

    try list.append(allocator, args[0]);

    var multiplexer: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--multiplexer")) {
            if (i + 1 >= args.len) return error.MissingMultiplexerValue;
            const value = args[i + 1];
            if (mux.Kind.parse(value) == null) return error.InvalidMultiplexerValue;
            multiplexer = value;
            i += 1;
        } else {
            try list.append(allocator, args[i]);
        }
    }

    return .{
        .remaining = try list.toOwnedSlice(allocator),
        .multiplexer = multiplexer,
    };
}

/// Outcome of parsing the flag arguments for a session subcommand
/// (`create`, `remove`, or `fix`).
pub const SessionArgsResult = union(enum) {
    /// Successfully parsed arguments.
    ok: CliArgs,
    /// A value-taking flag (e.g. `"--repository"`) had no following argument.
    missing_value: []const u8,
    /// An unrecognised argument was encountered.
    unknown_flag: []const u8,
    /// `--replace` was supplied to a subcommand other than `fix`.
    replace_not_fix,
    /// `--replace` was supplied to `fix` without `--session`.
    replace_requires_session,
};

/// Pure parser for the flags following `create`, `remove`, or `fix`.
///
/// `flag_args` is the slice of arguments after the subcommand name
/// (`args[2..]`). All string slices in the returned `CliArgs` are borrowed
/// from `flag_args`.
pub fn parseSessionArgs(operation: CliOperation, flag_args: []const []const u8) SessionArgsResult {
    var parsed = CliArgs{ .operation = operation };

    var i: usize = 0;
    while (i < flag_args.len) : (i += 1) {
        const arg = flag_args[i];
        if (std.mem.eql(u8, arg, "--repository")) {
            i += 1;
            if (i >= flag_args.len) return .{ .missing_value = "--repository" };
            parsed.repository = flag_args[i];
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= flag_args.len) return .{ .missing_value = "--session" };
            parsed.session = flag_args[i];
        } else if (std.mem.eql(u8, arg, "--branch")) {
            i += 1;
            if (i >= flag_args.len) return .{ .missing_value = "--branch" };
            parsed.branch = flag_args[i];
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            i += 1;
            if (i >= flag_args.len) return .{ .missing_value = "--prefix" };
            parsed.prefix = flag_args[i];
        } else if (std.mem.eql(u8, arg, "--replace")) {
            if (operation != .fix) return .replace_not_fix;
            parsed.replace = true;
        } else {
            return .{ .unknown_flag = arg };
        }
    }

    if (parsed.replace and parsed.session == null) {
        return .replace_requires_session;
    }

    return .{ .ok = parsed };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "extractMultiplexerFlag: returns unchanged args when flag is absent" {
    const input = [_][]const u8{ "git-session", "fix", "--repository", "app", "--session", "wt" };
    const result = try extractMultiplexerFlag(testing.allocator, &input);
    defer testing.allocator.free(result.remaining);

    try testing.expect(result.multiplexer == null);
    try testing.expectEqualDeep(@as([]const []const u8, &input), result.remaining);
}

test "extractMultiplexerFlag: strips flag before subcommand" {
    const input = [_][]const u8{ "git-session", "--multiplexer", "rex", "fix", "--repository", "app" };
    const result = try extractMultiplexerFlag(testing.allocator, &input);
    defer testing.allocator.free(result.remaining);

    try testing.expectEqualStrings("rex", result.multiplexer.?);
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "git-session", "fix", "--repository", "app" }),
        result.remaining,
    );
}

test "extractMultiplexerFlag: strips flag in the middle of args" {
    const input = [_][]const u8{ "git-session", "fix", "--multiplexer", "tmux", "--repository", "app" };
    const result = try extractMultiplexerFlag(testing.allocator, &input);
    defer testing.allocator.free(result.remaining);

    try testing.expectEqualStrings("tmux", result.multiplexer.?);
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "git-session", "fix", "--repository", "app" }),
        result.remaining,
    );
}

test "extractMultiplexerFlag: strips flag at the end of args" {
    const input = [_][]const u8{ "git-session", "fix", "--repository", "app", "--multiplexer", "Rex" };
    const result = try extractMultiplexerFlag(testing.allocator, &input);
    defer testing.allocator.free(result.remaining);

    try testing.expectEqualStrings("Rex", result.multiplexer.?);
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "git-session", "fix", "--repository", "app" }),
        result.remaining,
    );
}

test "extractMultiplexerFlag: handles flag as the only argument" {
    const input = [_][]const u8{ "git-session", "--multiplexer", "rex" };
    const result = try extractMultiplexerFlag(testing.allocator, &input);
    defer testing.allocator.free(result.remaining);

    try testing.expectEqualStrings("rex", result.multiplexer.?);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"git-session"}), result.remaining);
}

test "extractMultiplexerFlag: last occurrence wins when repeated" {
    const input = [_][]const u8{ "git-session", "--multiplexer", "tmux", "fix", "--multiplexer", "rex" };
    const result = try extractMultiplexerFlag(testing.allocator, &input);
    defer testing.allocator.free(result.remaining);

    try testing.expectEqualStrings("rex", result.multiplexer.?);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "git-session", "fix" }), result.remaining);

    const invalid_first = [_][]const u8{ "git-session", "--multiplexer", "bogus", "--multiplexer", "rex" };
    try testing.expectError(error.InvalidMultiplexerValue, extractMultiplexerFlag(testing.allocator, &invalid_first));

    const trailing_missing = [_][]const u8{ "git-session", "--multiplexer", "rex", "--multiplexer" };
    try testing.expectError(error.MissingMultiplexerValue, extractMultiplexerFlag(testing.allocator, &trailing_missing));
}

test "extractMultiplexerFlag: reports missing value" {
    const input = [_][]const u8{ "git-session", "fix", "--multiplexer" };
    try testing.expectError(error.MissingMultiplexerValue, extractMultiplexerFlag(testing.allocator, &input));
}

test "extractMultiplexerFlag: reports invalid value" {
    const bogus = [_][]const u8{ "git-session", "--multiplexer", "bogus" };
    try testing.expectError(error.InvalidMultiplexerValue, extractMultiplexerFlag(testing.allocator, &bogus));

    const empty = [_][]const u8{ "git-session", "--multiplexer", "" };
    try testing.expectError(error.InvalidMultiplexerValue, extractMultiplexerFlag(testing.allocator, &empty));

    const flag_as_val = [_][]const u8{ "git-session", "--multiplexer", "--repository", "app" };
    try testing.expectError(error.InvalidMultiplexerValue, extractMultiplexerFlag(testing.allocator, &flag_as_val));
}

test "extractMultiplexerFlag: empty args and argv[0] are preserved" {
    const empty = [_][]const u8{};
    const empty_res = try extractMultiplexerFlag(testing.allocator, &empty);
    defer testing.allocator.free(empty_res.remaining);
    try testing.expect(empty_res.multiplexer == null);
    try testing.expectEqual(@as(usize, 0), empty_res.remaining.len);

    // argv[0] is never treated as a flag.
    const weird_argv0 = [_][]const u8{"--multiplexer"};
    const weird_res = try extractMultiplexerFlag(testing.allocator, &weird_argv0);
    defer testing.allocator.free(weird_res.remaining);
    try testing.expect(weird_res.multiplexer == null);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"--multiplexer"}), weird_res.remaining);
}

test "extractMultiplexerFlag: does not leak on allocation failure" {
    const input = [_][]const u8{ "git-session", "fix", "--repository", "app", "--multiplexer", "rex", "--session", "wt" };
    var succeeded = false;
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        if (extractMultiplexerFlag(allocator, &input)) |res| {
            allocator.free(res.remaining);
            succeeded = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try testing.expect(succeeded);
}

test "parseSessionArgs: fix accepts --replace with --session" {
    const args = [_][]const u8{ "--repository", "app", "--session", "wt", "--replace" };
    const result = parseSessionArgs(.fix, &args);
    switch (result) {
        .ok => |parsed| {
            try testing.expectEqual(CliOperation.fix, parsed.operation.?);
            try testing.expectEqualStrings("app", parsed.repository.?);
            try testing.expectEqualStrings("wt", parsed.session.?);
            try testing.expect(parsed.replace);
        },
        else => return error.UnexpectedResult,
    }
}

test "parseSessionArgs: fix accepts --replace before --session" {
    const args = [_][]const u8{ "--replace", "--session", "wt", "--repository", "app" };
    const result = parseSessionArgs(.fix, &args);
    switch (result) {
        .ok => |parsed| {
            try testing.expect(parsed.replace);
            try testing.expectEqualStrings("wt", parsed.session.?);
            try testing.expectEqualStrings("app", parsed.repository.?);
        },
        else => return error.UnexpectedResult,
    }
}

test "parseSessionArgs: fix defaults replace to false" {
    const args = [_][]const u8{ "--repository", "app", "--session", "wt" };
    const result = parseSessionArgs(.fix, &args);
    switch (result) {
        .ok => |parsed| {
            try testing.expect(!parsed.replace);
        },
        else => return error.UnexpectedResult,
    }
}

test "parseSessionArgs: rejects --replace with create and remove" {
    const args = [_][]const u8{ "--repository", "app", "--session", "wt", "--replace" };
    try testing.expectEqual(SessionArgsResult.replace_not_fix, parseSessionArgs(.create, &args));
    try testing.expectEqual(SessionArgsResult.replace_not_fix, parseSessionArgs(.remove, &args));
}

test "parseSessionArgs: rejects --replace without --session" {
    const with_repo = [_][]const u8{ "--repository", "app", "--replace" };
    try testing.expectEqual(SessionArgsResult.replace_requires_session, parseSessionArgs(.fix, &with_repo));

    const bare = [_][]const u8{"--replace"};
    try testing.expectEqual(SessionArgsResult.replace_requires_session, parseSessionArgs(.fix, &bare));
}

test "parseSessionArgs: parses all create flags" {
    const args = [_][]const u8{ "--repository", "app", "--session", "wt", "--branch", "main", "--prefix", "feature" };
    const result = parseSessionArgs(.create, &args);
    switch (result) {
        .ok => |parsed| {
            try testing.expectEqual(CliOperation.create, parsed.operation.?);
            try testing.expectEqualStrings("app", parsed.repository.?);
            try testing.expectEqualStrings("wt", parsed.session.?);
            try testing.expectEqualStrings("main", parsed.branch.?);
            try testing.expectEqualStrings("feature", parsed.prefix.?);
            try testing.expect(!parsed.replace);
        },
        else => return error.UnexpectedResult,
    }
}

test "parseSessionArgs: reports missing value and unknown flag" {
    const missing_repo = [_][]const u8{"--repository"};
    switch (parseSessionArgs(.fix, &missing_repo)) {
        .missing_value => |f| try testing.expectEqualStrings("--repository", f),
        else => return error.UnexpectedResult,
    }

    const missing_session = [_][]const u8{ "--repository", "app", "--session" };
    switch (parseSessionArgs(.fix, &missing_session)) {
        .missing_value => |f| try testing.expectEqualStrings("--session", f),
        else => return error.UnexpectedResult,
    }

    const unknown = [_][]const u8{ "--repository", "app", "--bogus" };
    switch (parseSessionArgs(.fix, &unknown)) {
        .unknown_flag => |f| try testing.expectEqualStrings("--bogus", f),
        else => return error.UnexpectedResult,
    }
}
