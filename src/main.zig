const std = @import("std");
const build_options = @import("build_options");
const term = @import("term.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const tui = @import("tui.zig");

pub const version = build_options.version;

/// Entry point for the git-session CLI application.
///
/// Receives the process context (`std.process.Init`) from the runtime,
/// which carries the general-purpose allocator, the `std.Io`
/// implementation, and the parsed environment map used throughout the
/// application.
///
/// Parses command-line arguments and dispatches to the appropriate handler:
///   - Subcommands `create`, `remove`, `fix` run non-interactively when all
///     required flags are supplied; otherwise they open the TUI at the step
///     where input is still needed.
///   - `config` sub-commands manage root folders and never open the TUI.
///   - No subcommand (or just `--repository`) launches the interactive TUI.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var app_arena = std.heap.ArenaAllocator.init(allocator);
    defer app_arena.deinit();
    const app_alloc = app_arena.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // ── Flags that do not require config ────────────────────────────────────

    if (args.len >= 2) {
        const cmd = args[1];

        if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
            cli.printVersion(io);
            return;
        }

        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            cli.printUsage(io);
            return;
        }

        // `config` loads its own app config internally.
        if (std.mem.eql(u8, cmd, "config")) {
            try cli.handleConfigCommand(app_alloc, io, env, args);
            return;
        }
    }

    // ── Load (or initialise) global config ──────────────────────────────────

    const app_config: config.AppConfig = config.loadAppConfig(app_alloc, io, env) catch blk: {
        break :blk try config.runInitFlow(app_alloc, io, env);
    };

    // ── add-repo (clone a new repository) ───────────────────────────────────

    if (args.len >= 2 and std.mem.eql(u8, args[1], "add-repo")) {
        var url: ?[]const u8 = null;
        var root_arg: ?[]const u8 = null;
        var name_arg: ?[]const u8 = null;
        var branch_arg: ?[]const u8 = null;
        var prefix_arg: ?[]const u8 = null;
        var assume_yes = false;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--root")) {
                i += 1;
                if (i >= args.len) {
                    term.eprint(io, "Error: --root requires a value\n\n", .{});
                    cli.printUsage(io);
                    std.process.exit(1);
                }
                root_arg = args[i];
            } else if (std.mem.eql(u8, arg, "--name")) {
                i += 1;
                if (i >= args.len) {
                    term.eprint(io, "Error: --name requires a value\n\n", .{});
                    cli.printUsage(io);
                    std.process.exit(1);
                }
                name_arg = args[i];
            } else if (std.mem.eql(u8, arg, "--branch")) {
                i += 1;
                if (i >= args.len) {
                    term.eprint(io, "Error: --branch requires a value\n\n", .{});
                    cli.printUsage(io);
                    std.process.exit(1);
                }
                branch_arg = args[i];
            } else if (std.mem.eql(u8, arg, "--prefix")) {
                i += 1;
                if (i >= args.len) {
                    term.eprint(io, "Error: --prefix requires a value\n\n", .{});
                    cli.printUsage(io);
                    std.process.exit(1);
                }
                prefix_arg = args[i];
            } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
                assume_yes = true;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                term.eprint(io, "Unknown flag: {s}\n\n", .{arg});
                cli.printUsage(io);
                std.process.exit(1);
            } else {
                if (url != null) {
                    term.eprint(io, "Error: 'add-repo' takes a single URL.\n\n", .{});
                    cli.printUsage(io);
                    std.process.exit(1);
                }
                url = arg;
            }
        }

        const u = url orelse {
            term.eprint(io, "Error: 'add-repo' requires a clone URL.\n\n", .{});
            cli.printUsage(io);
            std.process.exit(1);
        };

        try cli.handleAddRepoCommand(app_alloc, io, env, app_config, u, root_arg, name_arg, branch_arg, prefix_arg, assume_yes);
        return;
    }

    // ── remove-repo (whole-repository removal) ──────────────────────────────

    if (args.len >= 2 and std.mem.eql(u8, args[1], "remove-repo")) {
        var assume_yes = false;
        var repo_name: ?[]const u8 = null;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
                assume_yes = true;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                term.eprint(io, "Unknown flag: {s}\n\n", .{arg});
                cli.printUsage(io);
                std.process.exit(1);
            } else {
                if (repo_name != null) {
                    term.eprint(io, "Error: 'remove-repo' takes a single repository name.\n\n", .{});
                    cli.printUsage(io);
                    std.process.exit(1);
                }
                repo_name = arg;
            }
        }

        const name = repo_name orelse {
            term.eprint(io, "Error: 'remove-repo' requires a repository name.\n\n", .{});
            cli.printUsage(io);
            std.process.exit(1);
        };

        try cli.handleRemoveRepoCommand(app_alloc, io, env, app_config, name, assume_yes);
        return;
    }

    // ── Session subcommands ──────────────────────────────────────────────────

    if (args.len >= 2) {
        const cmd = args[1];

        if (std.mem.eql(u8, cmd, "create") or
            std.mem.eql(u8, cmd, "remove") or
            std.mem.eql(u8, cmd, "fix"))
        {
            var parsed = cli.CliArgs{ .operation = operationFromString(cmd) };

            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--repository")) {
                    i += 1;
                    if (i >= args.len) {
                        term.eprint(io, "Error: --repository requires a value\n\n", .{});
                        cli.printUsage(io);
                        std.process.exit(1);
                    }
                    parsed.repository = args[i];
                } else if (std.mem.eql(u8, arg, "--session")) {
                    i += 1;
                    if (i >= args.len) {
                        term.eprint(io, "Error: --session requires a value\n\n", .{});
                        cli.printUsage(io);
                        std.process.exit(1);
                    }
                    parsed.session = args[i];
                } else if (std.mem.eql(u8, arg, "--branch")) {
                    i += 1;
                    if (i >= args.len) {
                        term.eprint(io, "Error: --branch requires a value\n\n", .{});
                        cli.printUsage(io);
                        std.process.exit(1);
                    }
                    parsed.branch = args[i];
                } else if (std.mem.eql(u8, arg, "--prefix")) {
                    i += 1;
                    if (i >= args.len) {
                        term.eprint(io, "Error: --prefix requires a value\n\n", .{});
                        cli.printUsage(io);
                        std.process.exit(1);
                    }
                    parsed.prefix = args[i];
                } else {
                    term.eprint(io, "Unknown flag: {s}\n\n", .{arg});
                    cli.printUsage(io);
                    std.process.exit(1);
                }
            }

            // Dispatch to the appropriate handler. The handler returns `null`
            // when the operation finished non-interactively, or a populated
            // `CliArgs` when the TUI should take over.
            const maybe_tui_args: ?cli.CliArgs = switch (parsed.operation.?) {
                .create => try cli.handleCreateCommand(app_alloc, io, env, app_config, parsed),
                .remove => try cli.handleRemoveCommand(app_alloc, io, env, app_config, parsed),
                .fix => try cli.handleFixCommand(app_alloc, io, env, app_config, parsed),
            };

            if (maybe_tui_args) |tui_args| {
                try tui.runTui(allocator, io, env, app_config, tui_args);
            }
            return;
        }
    }

    // ── Interactive TUI (with optional --repository pre-selection) ──────────

    var tui_args = cli.CliArgs{};
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--repository")) {
                i += 1;
                if (i >= args.len) {
                    term.eprint(io, "Error: --repository requires a value\n\n", .{});
                    cli.printUsage(io);
                    std.process.exit(1);
                }
                tui_args.repository = args[i];
            } else {
                reportUnknownArg(io, arg);
                std.process.exit(1);
            }
        }
    }

    try tui.runTui(allocator, io, env, app_config, tui_args);
}

/// Maps a command string to a `CliOperation`. Only called for strings that
/// are already known to be one of the three session subcommands.
fn operationFromString(cmd: []const u8) cli.CliOperation {
    if (std.mem.eql(u8, cmd, "create")) return .create;
    if (std.mem.eql(u8, cmd, "remove")) return .remove;
    if (std.mem.eql(u8, cmd, "fix")) return .fix;
    unreachable;
}

/// Known subcommand names. Kept in sync with the dispatch in `main`
/// and the help text in `cli.printUsage`. Used by `reportUnknownArg`
/// to suggest the right form when a user types `--remove-repo` instead
/// of `remove-repo`.
const known_subcommands = [_][]const u8{
    "create",
    "remove",
    "fix",
    "add-repo",
    "remove-repo",
    "config",
    "help",
};

/// Classification of an unrecognised top-level argument. Pure function
/// output: tells the caller how to phrase the error and whether to
/// include a "did you mean ...?" hint. Driven by the `subcommands`
/// table so the test can pin down the lookup behaviour without
/// reaching into the global one.
const ArgClass = struct {
    /// True when `arg` starts with `-` (so the message should call it
    /// a flag rather than a command).
    looks_like_flag: bool,
    /// Non-null when stripping the leading dashes from `arg` matches
    /// an entry in `subcommands` AND `arg` was flag-shaped. Holds the
    /// stripped name to substitute into the suggestion message.
    suggested_subcommand: ?[]const u8,
};

/// Pure helper: classifies an unknown CLI arg without doing any I/O.
/// Splitting this out lets the suggestion logic be tested without a
/// stdout/stderr capture harness.
fn classifyUnknownArg(arg: []const u8, subcommands: []const []const u8) ArgClass {
    const looks_like_flag = std.mem.startsWith(u8, arg, "-");
    const stripped = if (std.mem.startsWith(u8, arg, "--"))
        arg[2..]
    else if (std.mem.startsWith(u8, arg, "-"))
        arg[1..]
    else
        arg;

    if (!looks_like_flag) {
        return .{ .looks_like_flag = false, .suggested_subcommand = null };
    }

    for (subcommands) |sub| {
        if (std.mem.eql(u8, sub, stripped)) {
            return .{ .looks_like_flag = true, .suggested_subcommand = stripped };
        }
    }
    return .{ .looks_like_flag = true, .suggested_subcommand = null };
}

/// Prints an error message for an unrecognised argument and the full
/// usage text. When `arg` looks like a flag (`--foo` or `-f`) but maps
/// to a known subcommand once the leading dashes are stripped, also
/// hints that subcommands are positional. This makes typos like
/// `--remove-repo` self-explanatory rather than just printing a bare
/// "Unknown command".
fn reportUnknownArg(io: std.Io, arg: []const u8) void {
    const class = classifyUnknownArg(arg, &known_subcommands);

    if (class.looks_like_flag) {
        term.eprint(io, "Unknown flag: {s}\n", .{arg});
        if (class.suggested_subcommand) |sub| {
            term.eprint(io, "(Did you mean the `{s}` subcommand? Subcommands are positional, not flags.)\n", .{sub});
        }
        term.eprint(io, "\n", .{});
    } else {
        term.eprint(io, "Unknown command: {s}\n\n", .{arg});
    }
    cli.printUsage(io);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "classifyUnknownArg: bare command-shaped arg is not a flag" {
    const subs = [_][]const u8{ "create", "remove" };
    const c = classifyUnknownArg("bogus", &subs);
    try testing.expect(!c.looks_like_flag);
    try testing.expect(c.suggested_subcommand == null);
}

test "classifyUnknownArg: --foo is a flag with no suggestion when it doesn't match a subcommand" {
    const subs = [_][]const u8{ "create", "remove" };
    const c = classifyUnknownArg("--bogus", &subs);
    try testing.expect(c.looks_like_flag);
    try testing.expect(c.suggested_subcommand == null);
}

test "classifyUnknownArg: --remove-repo is a flag and suggests `remove-repo`" {
    const subs = [_][]const u8{ "create", "remove", "remove-repo", "add-repo" };
    const c = classifyUnknownArg("--remove-repo", &subs);
    try testing.expect(c.looks_like_flag);
    try testing.expect(c.suggested_subcommand != null);
    try testing.expectEqualStrings("remove-repo", c.suggested_subcommand.?);
}

test "classifyUnknownArg: short flag form -h is recognised as a flag" {
    const subs = [_][]const u8{ "help", "create" };
    const c = classifyUnknownArg("-h", &subs);
    try testing.expect(c.looks_like_flag);
    // `help` is in the table; stripping a single dash from `-h` yields
    // `h`, which is NOT in the table -- no suggestion expected.
    try testing.expect(c.suggested_subcommand == null);
}

test "classifyUnknownArg: -help (single dash, multi-letter) suggests `help` when present" {
    const subs = [_][]const u8{"help"};
    const c = classifyUnknownArg("-help", &subs);
    try testing.expect(c.looks_like_flag);
    try testing.expect(c.suggested_subcommand != null);
    try testing.expectEqualStrings("help", c.suggested_subcommand.?);
}

test "classifyUnknownArg: bare `-` is treated as a flag with no suggestion" {
    const subs = [_][]const u8{"help"};
    const c = classifyUnknownArg("-", &subs);
    try testing.expect(c.looks_like_flag);
    try testing.expect(c.suggested_subcommand == null);
}

test "classifyUnknownArg: empty arg is not a flag and has no suggestion" {
    const subs = [_][]const u8{"help"};
    const c = classifyUnknownArg("", &subs);
    try testing.expect(!c.looks_like_flag);
    try testing.expect(c.suggested_subcommand == null);
}

test "classifyUnknownArg: empty subcommand list never suggests anything" {
    const subs = [_][]const u8{};
    const c = classifyUnknownArg("--remove-repo", &subs);
    try testing.expect(c.looks_like_flag);
    try testing.expect(c.suggested_subcommand == null);
}
