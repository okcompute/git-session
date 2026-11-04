const std = @import("std");
const term = @import("term.zig");
const process = @import("process.zig");
const repo = @import("repo.zig");

// Rex (https://www.superlogical.com/rex/docs.md) backend.
//
// Every call goes through the `rex` CLI. Vocabulary mapping with tmux:
// session = session, window (a tab in the app) = window, block = pane.
//
// Rex-specific behaviour worth knowing when reading this file:
//   - Every invocation passes `--autostart=false`. On macOS the Rex app
//     runs the server; a `rex` command would otherwise start a short-lived
//     personal server of its own. With autostart off, an unreachable server
//     makes rex exit with status 4, reported as "Rex server not running".
//   - Rex allows several sessions with the same label, and a label that
//     matches more than one session is an ambiguous target (exit 3). Labels
//     are therefore resolved to full session IDs via `rex ls --json`, and
//     every follow-up command targets the full ID.
//   - Rex has no option to set an environment variable for a new terminal
//     (no equivalent of tmux `-e`). GS_REPO_PATH is exported by starting
//     each window's shell through `/usr/bin/env GS_REPO_PATH=<path> $SHELL -l`
//     with `--shell none`, so the value is a discrete argv element and is
//     never interpolated into a shell string.
//   - Window commands are typed into that shell (`rex send` + `rex send-key
//     enter`), exactly like tmux send-keys: they run with the interactive
//     shell config (aliases, functions), pipes and `&&` work, and the shell
//     stays open after the command exits.

/// Name of the Rex CLI executable looked up on PATH / in $REX_BIN_DIR.
pub const binary_name = "rex";

/// Global flag passed to every rex invocation; see the file header.
const no_autostart = "--autostart=false";

/// Maximum length of a Rex session label, in characters.
pub const max_label_len = 128;

/// Exit status rex uses when the target is missing or ambiguous.
pub const exit_target_not_found: u8 = 3;
/// Exit status rex uses when the server cannot be reached.
pub const exit_server_unreachable: u8 = 4;

/// The environment-variable name exported to every session window,
/// holding the worktree path so window commands can reference it.
const gs_repo_path_var = "GS_REPO_PATH";

/// Program used to inject GS_REPO_PATH into each window's shell.
const env_program = "/usr/bin/env";

/// Shell used when `$SHELL` is not set.
const fallback_shell = "/bin/sh";

pub const server_not_running_message =
    "Error: the Rex server is not running. Open the Rex app and try again.\n";

pub const Error = error{
    /// rex exited with status 4: the server is not reachable.
    RexServerNotRunning,
    /// rex exited with any other non-zero status.
    RexCommandFailed,
    /// rex printed JSON that git-session could not interpret.
    UnexpectedRexOutput,
    /// No session carries the requested label.
    RexSessionNotFound,
};

// ===========================================================================
// Binary lookup
// ===========================================================================

/// Returns the candidate locations of the rex CLI, in lookup order: every
/// directory of `path_env` (colon-separated, empty entries skipped), then
/// `rex_bin_dir` (the directory Rex exports as REX_BIN_DIR in its own
/// terminals). The caller owns the returned slice and every element; free
/// them with `freeStrings`.
pub fn candidatePaths(allocator: std.mem.Allocator, path_env: ?[]const u8, rex_bin_dir: ?[]const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, &list);

    if (path_env) |p| {
        var it = std.mem.splitScalar(u8, p, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            try appendJoined(allocator, &list, dir);
        }
    }
    if (rex_bin_dir) |dir| {
        if (dir.len > 0) try appendJoined(allocator, &list, dir);
    }
    return list.toOwnedSlice(allocator);
}

/// Appends `<dir>/rex` (trailing slashes of `dir` dropped) to `list`.
/// The list takes ownership of the new string; nothing leaks on OOM.
fn appendJoined(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), dir: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, dir, "/");
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ if (trimmed.len > 0) trimmed else "", binary_name });
    errdefer allocator.free(full);
    try list.append(allocator, full);
}

/// Locates the rex CLI: the first executable `rex` on PATH, then
/// `$REX_BIN_DIR/rex`. Returns `error.RexNotFound` when neither exists.
/// The caller owns the returned path.
pub fn findBinary(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]u8 {
    const candidates = try candidatePaths(allocator, env.get("PATH"), env.get("REX_BIN_DIR"));
    defer freeStrings(allocator, candidates);

    for (candidates) |candidate| {
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return allocator.dupe(u8, candidate);
    }
    return error.RexNotFound;
}

// ===========================================================================
// Session labels
// ===========================================================================

/// Returns the prefix of `name` that fits in a Rex label: at most
/// `max_label_len` characters (UTF-8 code points), without trailing
/// whitespace (Rex trims labels). Borrowed from `name`.
pub fn truncateLabel(name: []const u8) []const u8 {
    var chars: usize = 0;
    var end: usize = name.len;
    for (name, 0..) |c, i| {
        // Count only lead bytes so multi-byte characters are never split.
        if ((c & 0xC0) == 0x80) continue;
        if (chars == max_label_len) {
            end = i;
            break;
        }
        chars += 1;
    }
    return std.mem.trimEnd(u8, name[0..end], " \t");
}

/// Separator between the repository and session names in a Rex label.
const label_separator = " · ";

/// Generates the Rex session label: `<repo_name> · <worktree>`, e.g.
/// `my-project · login-page`, cut to Rex's label limit.
///
/// The label is kept short because Rex's session picker clips long labels
/// at the end: the branch prefix that tmux names include is left out, and
/// `branch` is accepted only so every backend's name function has the same
/// signature. The repository name keeps labels unique across repositories
/// (worktree names are unique within one). Rex accepts any character
/// except control characters, which branch names cannot contain.
/// The caller owns the returned string.
pub fn sessionLabel(allocator: std.mem.Allocator, worktree: []const u8, branch: []const u8, repo_name: []const u8) ![]u8 {
    _ = branch;
    const full = try std.fmt.allocPrint(allocator, "{s}" ++ label_separator ++ "{s}", .{ repo_name, worktree });
    const label = truncateLabel(full);
    if (label.len == full.len) return full;
    defer allocator.free(full);
    return allocator.dupe(u8, label);
}

// ===========================================================================
// Argv builders (pure)
//
// Each returns a caller-owned slice (free with `allocator.free`) whose
// string elements are borrowed from the arguments.
// ===========================================================================

/// `rex ls --json`: lists every session with its full ID and label.
fn buildListSessionsArgs(allocator: std.mem.Allocator, bin: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ bin, no_autostart, "ls", "--json" });
}

/// `rex new`: creates the session and its first window (labelled
/// `window_name`), whose shell starts in `cwd` with GS_REPO_PATH set.
/// `repo_path_env` must be of the form "GS_REPO_PATH=<path>".
fn buildNewSessionArgs(
    allocator: std.mem.Allocator,
    bin: []const u8,
    label: []const u8,
    window_name: []const u8,
    cwd: []const u8,
    repo_path_env: []const u8,
    shell: []const u8,
) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{
        bin,        no_autostart, "new",  label,      "--window",    window_name, "--cwd", cwd,
        "--shell",  "none",       "--json", "--",     env_program,   repo_path_env, shell, "-l",
    });
}

/// `rex window new`: adds a window (tab) labelled `window_name` to the
/// session without focusing it; its shell starts in `cwd` with
/// GS_REPO_PATH set. `rex run --label` would set the block label instead
/// of the window label, hence `window new`.
fn buildNewWindowArgs(
    allocator: std.mem.Allocator,
    bin: []const u8,
    session_id: []const u8,
    window_name: []const u8,
    cwd: []const u8,
    repo_path_env: []const u8,
    shell: []const u8,
) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{
        bin,     no_autostart, "window", "new",   "-s",   session_id, window_name,  "--cwd", cwd,
        "--focus=false", "--shell", "none", "--json", "--", env_program, repo_path_env, shell, "-l",
    });
}

/// `rex send`: types `text` into a window's focused block. Does not press
/// Enter. `--` keeps text that starts with `-` from being read as a flag.
fn buildSendTextArgs(allocator: std.mem.Allocator, bin: []const u8, session_id: []const u8, window_id: []const u8, text: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ bin, no_autostart, "send", "-s", session_id, "-w", window_id, "--", text });
}

/// `rex send-key`: presses `key` (Rex key syntax, e.g. `enter`) in a
/// window's focused block.
fn buildSendKeyArgs(allocator: std.mem.Allocator, bin: []const u8, session_id: []const u8, window_id: []const u8, key: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ bin, no_autostart, "send-key", "-s", session_id, "-w", window_id, key });
}

/// `rex window focus 1`: makes the first window (by position) active.
fn buildFocusFirstWindowArgs(allocator: std.mem.Allocator, bin: []const u8, session_id: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ bin, no_autostart, "window", "focus", "1", "-s", session_id });
}

/// `rex kill`: kills every session in `session_ids`.
fn buildKillArgs(allocator: std.mem.Allocator, bin: []const u8, session_ids: []const []const u8) ![]const []const u8 {
    const args = try allocator.alloc([]const u8, 3 + session_ids.len);
    args[0] = bin;
    args[1] = no_autostart;
    args[2] = "kill";
    @memcpy(args[3..], session_ids);
    return args;
}

/// `rex block ls --json`: lists the blocks (panes) of a session.
fn buildListBlocksArgs(allocator: std.mem.Allocator, bin: []const u8, session_id: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ bin, no_autostart, "block", "ls", "-s", session_id, "--json" });
}

/// `rex send-key -b`: presses `key` in a specific block.
fn buildBlockSendKeyArgs(allocator: std.mem.Allocator, bin: []const u8, block_id: []const u8, key: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ bin, no_autostart, "send-key", "-b", block_id, key });
}

/// `rex send -b`: types `text` into a specific block (no Enter).
fn buildBlockSendTextArgs(allocator: std.mem.Allocator, bin: []const u8, block_id: []const u8, text: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ bin, no_autostart, "send", "-b", block_id, "--", text });
}

/// `rex do session.select session_id=<id>`: asks the Rex app ("Go to
/// Session") to show a session. `session_id_arg` must be of the form
/// "session_id=<full id>". The app only accepts actions from the CLI when
/// Remote Control is turned on in its settings.
fn buildSelectSessionArgs(allocator: std.mem.Allocator, bin: []const u8, session_id_arg: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ bin, no_autostart, "do", "session.select", session_id_arg });
}

/// `rex do session.next`: asks the Rex app to show the next session.
fn buildNextSessionArgs(allocator: std.mem.Allocator, bin: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{ bin, no_autostart, "do", "session.next" });
}

// ===========================================================================
// JSON output parsing (pure)
// ===========================================================================

/// A session as listed by `rex ls --json`.
pub const SessionEntry = struct {
    session_id: []u8,
    label: []u8,
};

/// Parses `rex ls --json` output. The caller owns the result; free it
/// with `freeSessions`.
pub fn parseSessions(allocator: std.mem.Allocator, json: []const u8) ![]SessionEntry {
    const Wire = struct {
        sessions: []const struct {
            session_id: []const u8,
            label: []const u8 = "",
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Wire, allocator, json, .{ .ignore_unknown_fields = true }) catch
        return error.UnexpectedRexOutput;
    defer parsed.deinit();

    const out = try allocator.alloc(SessionEntry, parsed.value.sessions.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| {
            allocator.free(s.session_id);
            allocator.free(s.label);
        }
        allocator.free(out);
    }
    for (parsed.value.sessions) |s| {
        const id = try allocator.dupe(u8, s.session_id);
        errdefer allocator.free(id);
        const label = try allocator.dupe(u8, s.label);
        out[filled] = .{ .session_id = id, .label = label };
        filled += 1;
    }
    return out;
}

/// Frees a slice returned by `parseSessions`.
pub fn freeSessions(allocator: std.mem.Allocator, sessions: []SessionEntry) void {
    for (sessions) |s| {
        allocator.free(s.session_id);
        allocator.free(s.label);
    }
    allocator.free(sessions);
}

/// Returns the full IDs of every session whose label is exactly `label`,
/// borrowed from `sessions`. The caller frees the returned slice only.
pub fn idsWithLabel(allocator: std.mem.Allocator, sessions: []const SessionEntry, label: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    for (sessions) |s| {
        if (std.mem.eql(u8, s.label, label)) try list.append(allocator, s.session_id);
    }
    return list.toOwnedSlice(allocator);
}

/// IDs of a newly created session and its first window.
pub const CreatedSession = struct {
    session_id: []u8,
    window_id: []u8,

    /// Frees both IDs.
    pub fn deinit(self: CreatedSession, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.window_id);
    }
};

/// Parses `rex new --json` output. The caller owns the result.
pub fn parseCreatedSession(allocator: std.mem.Allocator, json: []const u8) !CreatedSession {
    const Wire = struct {
        session_id: []const u8,
        initial_windows: []const struct { window_id: []const u8 } = &.{},
    };
    const parsed = std.json.parseFromSlice(Wire, allocator, json, .{ .ignore_unknown_fields = true }) catch
        return error.UnexpectedRexOutput;
    defer parsed.deinit();
    if (parsed.value.initial_windows.len == 0) return error.UnexpectedRexOutput;

    const session_id = try allocator.dupe(u8, parsed.value.session_id);
    errdefer allocator.free(session_id);
    const window_id = try allocator.dupe(u8, parsed.value.initial_windows[0].window_id);
    return .{ .session_id = session_id, .window_id = window_id };
}

/// Parses `rex window new --json` output and returns the new window's
/// full ID. The caller owns the result.
pub fn parseCreatedWindowId(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const Wire = struct { window_id: []const u8 };
    const parsed = std.json.parseFromSlice(Wire, allocator, json, .{ .ignore_unknown_fields = true }) catch
        return error.UnexpectedRexOutput;
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.value.window_id);
}

/// Parses `rex block ls --json` output and returns every block's full
/// ID. The caller owns the result; free it with `freeStrings`.
pub fn parseBlockIds(allocator: std.mem.Allocator, json: []const u8) ![][]u8 {
    const Wire = struct {
        blocks: []const struct { block_id: []const u8 } = &.{},
    };
    const parsed = std.json.parseFromSlice(Wire, allocator, json, .{ .ignore_unknown_fields = true }) catch
        return error.UnexpectedRexOutput;
    defer parsed.deinit();

    var list: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, &list);
    for (parsed.value.blocks) |b| {
        const id = try allocator.dupe(u8, b.block_id);
        errdefer allocator.free(id);
        try list.append(allocator, id);
    }
    return list.toOwnedSlice(allocator);
}

/// Frees a slice of owned strings and the slice itself.
pub fn freeStrings(allocator: std.mem.Allocator, strings: []const []u8) void {
    for (strings) |s| allocator.free(s);
    allocator.free(strings);
}

/// Frees every owned string in `list` and the list's backing array.
fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit(allocator);
}

/// Returns `true` when `current_session_id` (the REX_SESSION of the
/// terminal git-session runs in) is one of the sessions labelled `label`.
pub fn isCurrentSession(sessions: []const SessionEntry, current_session_id: []const u8, label: []const u8) bool {
    for (sessions) |s| {
        if (std.mem.eql(u8, s.session_id, current_session_id) and std.mem.eql(u8, s.label, label)) return true;
    }
    return false;
}

/// Returns how many of `block_ids` are not `own_block` (the REX_BLOCK of
/// the terminal git-session runs in, if any).
pub fn countOtherBlocks(block_ids: []const []const u8, own_block: ?[]const u8) usize {
    var n: usize = 0;
    for (block_ids) |b| {
        if (own_block) |own| {
            if (std.mem.eql(u8, b, own)) continue;
        }
        n += 1;
    }
    return n;
}

/// Returns the shell each window starts: `$SHELL`, or `/bin/sh`.
pub fn loginShell(env: *const std.process.Environ.Map) []const u8 {
    const shell = env.get("SHELL") orelse return fallback_shell;
    return if (shell.len > 0) shell else fallback_shell;
}

// ===========================================================================
// Runtime operations
// ===========================================================================

/// A resolved Rex CLI. `bin` is the path found by `findBinary`.
pub const Rex = struct {
    bin: []const u8,

    /// Runs `argv` and returns its result. Caller frees it.
    fn run(self: Rex, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !process.ExecResult {
        _ = self;
        return process.exec(allocator, io, argv, null);
    }

    /// Runs `argv`, discards its output, and ignores failures. Used for
    /// best-effort steps, matching how the tmux backend ignores the
    /// status of send-keys / select-window.
    fn runIgnoringResult(self: Rex, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
        const r = self.run(allocator, io, argv) catch return;
        process.freeExecResult(allocator, r);
    }

    /// Checks that the Rex server is reachable. Prints a clear message and
    /// returns `error.RexServerNotRunning` when it is not.
    ///
    /// Uses `rex ls` rather than `rex server status`: with no server,
    /// `server status` exits 1, while commands that connect to the server
    /// exit 4 as documented.
    pub fn ensureServerRunning(self: Rex, allocator: std.mem.Allocator, io: std.Io) !void {
        const argv = try buildListSessionsArgs(allocator, self.bin);
        defer allocator.free(argv);
        const r = try self.run(allocator, io, argv);
        defer process.freeExecResult(allocator, r);
        try checkResult(io, r, "ls");
    }

    /// Lists every session. Caller frees with `freeSessions`.
    pub fn listSessions(self: Rex, allocator: std.mem.Allocator, io: std.Io) ![]SessionEntry {
        const argv = try buildListSessionsArgs(allocator, self.bin);
        defer allocator.free(argv);
        const r = try self.run(allocator, io, argv);
        defer process.freeExecResult(allocator, r);
        if (!r.exited_ok) return if (r.exit_code == exit_server_unreachable) error.RexServerNotRunning else error.RexCommandFailed;
        return parseSessions(allocator, r.stdout_data);
    }

    /// Returns `true` when at least one session is labelled `label`.
    /// Returns `false` on any error (e.g. the server is not running),
    /// like `tmux.tmuxSessionExists`.
    pub fn sessionExists(self: Rex, allocator: std.mem.Allocator, io: std.Io, label: []const u8) bool {
        const sessions = self.listSessions(allocator, io) catch return false;
        defer freeSessions(allocator, sessions);
        for (sessions) |s| {
            if (std.mem.eql(u8, s.label, label)) return true;
        }
        return false;
    }

    /// Creates a session labelled `label` with one window per entry in
    /// `windows` (or a single "shell" window when empty), each starting in
    /// `worktree_path` with GS_REPO_PATH set, and types each window's
    /// commands into its shell. The first window ends up focused. Prints a
    /// message and returns without error when the session already exists.
    pub fn createSession(
        self: Rex,
        allocator: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        label: []const u8,
        worktree_path: []const u8,
        windows: []const repo.WindowConfig,
    ) !void {
        if (self.sessionExists(allocator, io, label)) {
            term.print(io, "Rex session '{s}' already exists.\n", .{label});
            return;
        }

        const first_win_name = if (windows.len > 0) windows[0].name else "shell";
        const effective_name = if (first_win_name.len > 0) first_win_name else "shell";

        const repo_path_env = try std.fmt.allocPrint(allocator, "{s}={s}", .{ gs_repo_path_var, worktree_path });
        defer allocator.free(repo_path_env);
        const shell = loginShell(env);

        const new_session_args = try buildNewSessionArgs(allocator, self.bin, label, effective_name, worktree_path, repo_path_env, shell);
        defer allocator.free(new_session_args);
        const r = try self.run(allocator, io, new_session_args);
        defer process.freeExecResult(allocator, r);
        checkResult(io, r, "new") catch |err| {
            term.eprint(io, "Failed to create Rex session.\n", .{});
            return err;
        };

        const created = parseCreatedSession(allocator, r.stdout_data) catch |err| {
            term.eprint(io, "Failed to read the new Rex session's IDs.\n", .{});
            return err;
        };
        defer created.deinit(allocator);

        if (windows.len > 0) {
            self.typeCommands(allocator, io, created.session_id, created.window_id, windows[0].commands.items);
        }

        if (windows.len > 1) {
            for (windows[1..]) |win| {
                const win_name = if (win.name.len > 0) win.name else "shell";
                const new_window_args = try buildNewWindowArgs(allocator, self.bin, created.session_id, win_name, worktree_path, repo_path_env, shell);
                defer allocator.free(new_window_args);
                const wr = self.run(allocator, io, new_window_args) catch continue;
                defer process.freeExecResult(allocator, wr);
                if (!wr.exited_ok) {
                    term.eprint(io, "Warning: could not create Rex window '{s}'.\n", .{win_name});
                    continue;
                }
                const window_id = parseCreatedWindowId(allocator, wr.stdout_data) catch continue;
                defer allocator.free(window_id);
                self.typeCommands(allocator, io, created.session_id, window_id, win.commands.items);
            }
        }

        const focus_args = try buildFocusFirstWindowArgs(allocator, self.bin, created.session_id);
        defer allocator.free(focus_args);
        self.runIgnoringResult(allocator, io, focus_args);
    }

    /// Types each command into the window's shell and presses Enter.
    fn typeCommands(self: Rex, allocator: std.mem.Allocator, io: std.Io, session_id: []const u8, window_id: []const u8, commands: []const []const u8) void {
        for (commands) |cmd| {
            // `rex send` with an empty TEXT would read stdin instead.
            if (cmd.len > 0) {
                const send_args = buildSendTextArgs(allocator, self.bin, session_id, window_id, cmd) catch continue;
                defer allocator.free(send_args);
                self.runIgnoringResult(allocator, io, send_args);
            }
            const key_args = buildSendKeyArgs(allocator, self.bin, session_id, window_id, "enter") catch continue;
            defer allocator.free(key_args);
            self.runIgnoringResult(allocator, io, key_args);
        }
    }

    /// Kills every session labelled `label`.
    pub fn killSession(self: Rex, allocator: std.mem.Allocator, io: std.Io, label: []const u8) !void {
        const sessions = try self.listSessions(allocator, io);
        defer freeSessions(allocator, sessions);
        const ids = try idsWithLabel(allocator, sessions, label);
        defer allocator.free(ids);
        if (ids.len == 0) return;

        const argv = try buildKillArgs(allocator, self.bin, ids);
        defer allocator.free(argv);
        const r = try self.run(allocator, io, argv);
        defer process.freeExecResult(allocator, r);
        try checkResult(io, r, "kill");
    }

    /// Asks the Rex app to show the session labelled `label` (the "Go to
    /// Session" action). There is no attach step in Rex: the app is the
    /// viewer. Prints a hint and returns an error when the app refuses
    /// (Remote Control off, app not running).
    pub fn attachOrSwitch(self: Rex, allocator: std.mem.Allocator, io: std.Io, label: []const u8) !void {
        const sessions = try self.listSessions(allocator, io);
        defer freeSessions(allocator, sessions);
        const ids = try idsWithLabel(allocator, sessions, label);
        defer allocator.free(ids);
        if (ids.len == 0) {
            term.eprint(io, "Rex session '{s}' not found.\n", .{label});
            return error.RexSessionNotFound;
        }

        term.print(io, "Showing Rex session '{s}'\n", .{label});
        const id_arg = try std.fmt.allocPrint(allocator, "session_id={s}", .{ids[0]});
        defer allocator.free(id_arg);
        const argv = try buildSelectSessionArgs(allocator, self.bin, id_arg);
        defer allocator.free(argv);
        const r = try self.run(allocator, io, argv);
        defer process.freeExecResult(allocator, r);
        if (!r.exited_ok and r.exit_code != exit_server_unreachable) {
            term.eprint(io, "Could not switch the Rex app to the session: {s}\n", .{firstLine(r.stderr_data)});
            term.eprint(io, "Turn on Remote Control in the Rex app's settings, or pick '{s}' in the Rex sidebar.\n", .{label});
            return error.RexCommandFailed;
        }
        try checkResult(io, r, "do session.select");
    }

    /// When git-session runs inside the session labelled `label` (its
    /// REX_SESSION is that session) and other sessions exist, asks the Rex
    /// app to show the next session, so removing the current session does
    /// not leave the user looking at a session being torn down.
    ///
    /// Unlike tmux, Rex does not report which session the app is showing
    /// and has no "last session" action, so this keys off REX_SESSION and
    /// uses "Next Session". Best-effort: failures (e.g. Remote Control
    /// off) are ignored.
    pub fn switchAwayIfCurrent(self: Rex, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, label: []const u8) void {
        const current = env.get("REX_SESSION") orelse return;
        const sessions = self.listSessions(allocator, io) catch return;
        defer freeSessions(allocator, sessions);
        if (!isCurrentSession(sessions, current, label)) return;
        if (sessions.len <= 1) return;

        term.print(io, "Switching to next Rex session.\n", .{});
        const argv = buildNextSessionArgs(allocator, self.bin) catch return;
        defer allocator.free(argv);
        self.runIgnoringResult(allocator, io, argv);
    }

    /// Lists the full block IDs of every session labelled `label`.
    /// Caller frees with `freeStrings`.
    fn blocksOf(self: Rex, allocator: std.mem.Allocator, io: std.Io, label: []const u8) ![][]u8 {
        const sessions = try self.listSessions(allocator, io);
        defer freeSessions(allocator, sessions);
        const ids = try idsWithLabel(allocator, sessions, label);
        defer allocator.free(ids);

        var all: std.ArrayList([]u8) = .empty;
        errdefer freeStringList(allocator, &all);
        for (ids) |id| {
            const argv = try buildListBlocksArgs(allocator, self.bin, id);
            defer allocator.free(argv);
            const r = try self.run(allocator, io, argv);
            defer process.freeExecResult(allocator, r);
            if (!r.exited_ok) continue;
            const blocks = try parseBlockIds(allocator, r.stdout_data);
            defer allocator.free(blocks);
            var moved: usize = 0;
            errdefer for (blocks[moved..]) |b| allocator.free(b);
            for (blocks) |b| {
                try all.append(allocator, b);
                moved += 1;
            }
        }
        return all.toOwnedSlice(allocator);
    }

    /// Sends Ctrl-C, then `exit` + Enter, to every block of the session,
    /// encouraging shells and editors to release the worktree directory.
    /// Skips the block git-session itself runs in (REX_BLOCK) so a CLI
    /// `remove` is not interrupted by its own Ctrl-C. Best-effort.
    pub fn stopPanes(self: Rex, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, label: []const u8) void {
        const blocks = self.blocksOf(allocator, io, label) catch return;
        defer freeStrings(allocator, blocks);
        const own_block = env.get("REX_BLOCK");

        for (blocks) |block| {
            if (own_block) |own| {
                if (std.mem.eql(u8, block, own)) continue;
            }
            const ctrl_c = buildBlockSendKeyArgs(allocator, self.bin, block, "ctrl+c") catch continue;
            defer allocator.free(ctrl_c);
            self.runIgnoringResult(allocator, io, ctrl_c);

            const exit_text = buildBlockSendTextArgs(allocator, self.bin, block, "exit") catch continue;
            defer allocator.free(exit_text);
            self.runIgnoringResult(allocator, io, exit_text);

            const enter = buildBlockSendKeyArgs(allocator, self.bin, block, "enter") catch continue;
            defer allocator.free(enter);
            self.runIgnoringResult(allocator, io, enter);
        }
    }

    /// Waits up to ~500 ms for the blocks signalled by `stopPanes` to
    /// close. A Rex session outlives its last block (it stays with zero
    /// windows), so this polls the block count rather than waiting for the
    /// session to disappear as the tmux backend does.
    pub fn waitForPanesToExit(self: Rex, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, label: []const u8) void {
        const own_block = env.get("REX_BLOCK");
        var attempts: u8 = 0;
        while (attempts < 10) : (attempts += 1) {
            const blocks = self.blocksOf(allocator, io, label) catch return;
            const remaining = countOtherBlocks(blocks, own_block);
            freeStrings(allocator, blocks);
            if (remaining == 0) return;
            io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
    }
};

/// Converts a failed rex result into an error, printing rex's own message.
/// Exit status 4 (server unreachable) gets a dedicated message.
fn checkResult(io: std.Io, r: process.ExecResult, what: []const u8) Error!void {
    if (r.exited_ok) return;
    if (r.exit_code == exit_server_unreachable) {
        term.eprint(io, server_not_running_message, .{});
        return error.RexServerNotRunning;
    }
    term.eprint(io, "rex {s} failed (exit {d}): {s}\n", .{ what, r.exit_code, firstLine(r.stderr_data) });
    return error.RexCommandFailed;
}

/// Returns the first non-empty line of `text`, trimmed.
fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Asserts that an argv builder produced exactly `expected`.
fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqualDeep(expected, actual);
}

test "buildListSessionsArgs" {
    const args = try buildListSessionsArgs(testing.allocator, "rex");
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "ls", "--json" }, args);
}

test "buildNewSessionArgs labels the session and first window and starts the shell with GS_REPO_PATH" {
    const args = try buildNewSessionArgs(testing.allocator, "rex", "app · fix-it", "editor", "/w/fix-it", "GS_REPO_PATH=/w/fix-it", "/bin/zsh");
    defer testing.allocator.free(args);
    try expectArgv(&.{
        "rex",          "--autostart=false", "new",    "app · fix-it",           "--window", "editor", "--cwd", "/w/fix-it",
        "--shell",      "none",              "--json", "--",                      "/usr/bin/env", "GS_REPO_PATH=/w/fix-it", "/bin/zsh", "-l",
    }, args);
}

test "buildNewSessionArgs passes a worktree path with special characters verbatim" {
    const path = "/tmp/weird path;$(echo hi)";
    const env_arg = "GS_REPO_PATH=" ++ path;
    const args = try buildNewSessionArgs(testing.allocator, "rex", "s", "w", path, env_arg, "/bin/sh");
    defer testing.allocator.free(args);
    // The path must be single, discrete argv elements, never part of a shell string.
    try testing.expectEqualStrings(path, args[7]);
    try testing.expectEqualStrings(env_arg, args[13]);
}

test "buildNewWindowArgs adds an unfocused, labelled window to the session" {
    const args = try buildNewWindowArgs(testing.allocator, "rex", "session:abc", "logs", "/w/s", "GS_REPO_PATH=/w/s", "/bin/zsh");
    defer testing.allocator.free(args);
    try expectArgv(&.{
        "rex",           "--autostart=false", "window", "new",    "-s", "session:abc",  "logs",              "--cwd",    "/w/s",
        "--focus=false", "--shell",           "none",   "--json", "--", "/usr/bin/env", "GS_REPO_PATH=/w/s", "/bin/zsh", "-l",
    }, args);
}

test "buildSendTextArgs types text after -- so leading dashes are not flags" {
    const args = try buildSendTextArgs(testing.allocator, "rex", "session:abc", "window:def", "-n vim .");
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "send", "-s", "session:abc", "-w", "window:def", "--", "-n vim ." }, args);
}

test "buildSendKeyArgs presses a key in a window" {
    const args = try buildSendKeyArgs(testing.allocator, "rex", "session:abc", "window:def", "enter");
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "send-key", "-s", "session:abc", "-w", "window:def", "enter" }, args);
}

test "buildFocusFirstWindowArgs focuses window position 1" {
    const args = try buildFocusFirstWindowArgs(testing.allocator, "rex", "session:abc");
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "window", "focus", "1", "-s", "session:abc" }, args);
}

test "buildKillArgs kills every given session" {
    const ids = [_][]const u8{ "session:a", "session:b" };
    const args = try buildKillArgs(testing.allocator, "rex", &ids);
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "kill", "session:a", "session:b" }, args);
}

test "buildListBlocksArgs" {
    const args = try buildListBlocksArgs(testing.allocator, "rex", "session:abc");
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "block", "ls", "-s", "session:abc", "--json" }, args);
}

test "buildBlockSendKeyArgs" {
    const args = try buildBlockSendKeyArgs(testing.allocator, "rex", "block:1", "ctrl+c");
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "send-key", "-b", "block:1", "ctrl+c" }, args);
}

test "buildBlockSendTextArgs" {
    const args = try buildBlockSendTextArgs(testing.allocator, "rex", "block:1", "exit");
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "send", "-b", "block:1", "--", "exit" }, args);
}

test "buildSelectSessionArgs performs the Go to Session action" {
    const args = try buildSelectSessionArgs(testing.allocator, "rex", "session_id=session:abc");
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "do", "session.select", "session_id=session:abc" }, args);
}

test "buildNextSessionArgs" {
    const args = try buildNextSessionArgs(testing.allocator, "rex");
    defer testing.allocator.free(args);
    try expectArgv(&.{ "rex", "--autostart=false", "do", "session.next" }, args);
}

test "parseSessions reads IDs and labels from rex ls --json" {
    const json =
        \\{"sessions":[
        \\  {"session_id":"session:01-a","label":"(app) - one"},
        \\  {"session_id":"session:01-b","label":"other","extra":true}
        \\]}
    ;
    const sessions = try parseSessions(testing.allocator, json);
    defer freeSessions(testing.allocator, sessions);
    try testing.expectEqual(@as(usize, 2), sessions.len);
    try testing.expectEqualStrings("session:01-a", sessions[0].session_id);
    try testing.expectEqualStrings("(app) - one", sessions[0].label);
    try testing.expectEqualStrings("other", sessions[1].label);
}

test "parseSessions accepts an empty server" {
    const sessions = try parseSessions(testing.allocator, "{\"sessions\":[]}");
    defer freeSessions(testing.allocator, sessions);
    try testing.expectEqual(@as(usize, 0), sessions.len);
}

test "parseSessions rejects malformed output" {
    try testing.expectError(error.UnexpectedRexOutput, parseSessions(testing.allocator, "LABEL ID\n"));
}

test "parseSessions does not leak when an allocation fails" {
    const json = "{\"sessions\":[{\"session_id\":\"s1\",\"label\":\"a\"},{\"session_id\":\"s2\",\"label\":\"b\"}]}";
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        if (parseSessions(allocator, json)) |sessions| {
            freeSessions(allocator, sessions);
            break;
        } else |err| switch (err) {
            error.OutOfMemory, error.UnexpectedRexOutput => {},
        }
    }
}

test "idsWithLabel returns every exact match, including duplicates" {
    // Rex allows duplicate labels; all of them must be found so `kill`
    // removes every copy and `exists` never creates another.
    var a_id = "session:a".*;
    var a_label = "(app) - x".*;
    var b_id = "session:b".*;
    var b_label = "(app) - x2".*;
    var c_id = "session:c".*;
    var c_label = "(app) - x".*;
    const sessions = [_]SessionEntry{
        .{ .session_id = &a_id, .label = &a_label },
        .{ .session_id = &b_id, .label = &b_label },
        .{ .session_id = &c_id, .label = &c_label },
    };
    const ids = try idsWithLabel(testing.allocator, &sessions, "(app) - x");
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("session:a", ids[0]);
    try testing.expectEqualStrings("session:c", ids[1]);
}

test "isCurrentSession matches REX_SESSION against the labelled session" {
    var a_id = "session:a".*;
    var a_label = "(app) - x".*;
    var b_id = "session:b".*;
    var b_label = "other".*;
    const sessions = [_]SessionEntry{
        .{ .session_id = &a_id, .label = &a_label },
        .{ .session_id = &b_id, .label = &b_label },
    };
    try testing.expect(isCurrentSession(&sessions, "session:a", "(app) - x"));
    try testing.expect(!isCurrentSession(&sessions, "session:b", "(app) - x"));
    try testing.expect(!isCurrentSession(&sessions, "session:z", "(app) - x"));
}

test "parseCreatedSession reads the session and first window IDs" {
    const json =
        \\{"session_id":"session:01","initial_windows":[{"window_id":"window:01","block_ids":["block:01"],"revision":1}]}
    ;
    const created = try parseCreatedSession(testing.allocator, json);
    defer created.deinit(testing.allocator);
    try testing.expectEqualStrings("session:01", created.session_id);
    try testing.expectEqualStrings("window:01", created.window_id);
}

test "parseCreatedSession rejects output without a window" {
    try testing.expectError(error.UnexpectedRexOutput, parseCreatedSession(testing.allocator, "{\"session_id\":\"session:01\"}"));
}

test "parseCreatedWindowId" {
    const id = try parseCreatedWindowId(testing.allocator, "{\"window_id\":\"window:02\",\"block_ids\":[\"block:02\"],\"revision\":2}");
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("window:02", id);
}

test "parseBlockIds" {
    const json =
        \\{"blocks":[{"block_id":"block:1","label":"shell","window_id":"window:1"},{"block_id":"block:2"}]}
    ;
    const ids = try parseBlockIds(testing.allocator, json);
    defer freeStrings(testing.allocator, ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("block:1", ids[0]);
    try testing.expectEqualStrings("block:2", ids[1]);
}

test "countOtherBlocks skips git-session's own block" {
    const blocks = [_][]const u8{ "block:1", "block:2", "block:3" };
    try testing.expectEqual(@as(usize, 3), countOtherBlocks(&blocks, null));
    try testing.expectEqual(@as(usize, 2), countOtherBlocks(&blocks, "block:2"));
    try testing.expectEqual(@as(usize, 0), countOtherBlocks(&.{}, "block:2"));
}

test "truncateLabel keeps short labels unchanged" {
    try testing.expectEqualStrings("(app/feature/) - x", truncateLabel("(app/feature/) - x"));
}

test "truncateLabel cuts at 128 characters" {
    const long = "a" ** 130;
    try testing.expectEqual(@as(usize, 128), truncateLabel(long).len);
}

test "truncateLabel counts characters, not bytes, and never splits one" {
    // 127 ASCII + three 2-byte characters: the cut keeps exactly one é.
    const long = "a" ** 127 ++ "ééé";
    const cut = truncateLabel(long);
    try testing.expectEqualStrings("a" ** 127 ++ "é", cut);
}

test "truncateLabel drops whitespace left at the end of the cut" {
    const long = "a" ** 127 ++ " bcd";
    try testing.expectEqualStrings("a" ** 127, truncateLabel(long));
}

test "sessionLabel puts the repository first, then the session name" {
    const label = try sessionLabel(testing.allocator, "login-page", "feature/login-page", "my-project");
    defer testing.allocator.free(label);
    try testing.expectEqualStrings("my-project · login-page", label);
}

test "sessionLabel ignores the branch prefix and keeps dots" {
    const label = try sessionLabel(testing.allocator, "fix-it", "bug.fix/fix-it", "my.app");
    defer testing.allocator.free(label);
    try testing.expectEqualStrings("my.app · fix-it", label);
}

test "sessionLabel keeps same-named sessions of different repositories apart" {
    const a = try sessionLabel(testing.allocator, "playground", "chore/playground", "upm");
    defer testing.allocator.free(a);
    const b = try sessionLabel(testing.allocator, "playground", "chore/playground", "upm-registry");
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "sessionLabel truncates very long names to 128 characters" {
    const worktree = "w" ** 200;
    const label = try sessionLabel(testing.allocator, worktree, "feature/" ++ worktree, "app");
    defer testing.allocator.free(label);
    // 128 characters; "·" is two bytes, so the byte length is one more.
    try testing.expectEqual(@as(usize, max_label_len), try std.unicode.utf8CountCodepoints(label));
    try testing.expect(std.mem.startsWith(u8, label, "app · www"));
}

test "candidatePaths lists PATH entries then REX_BIN_DIR" {
    const paths = try candidatePaths(testing.allocator, "/usr/bin::/opt/x/", "/Applications/Rex/bin");
    defer freeStrings(testing.allocator, paths);
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expectEqualStrings("/usr/bin/rex", paths[0]);
    try testing.expectEqualStrings("/opt/x/rex", paths[1]);
    try testing.expectEqualStrings("/Applications/Rex/bin/rex", paths[2]);
}

test "candidatePaths handles missing PATH and REX_BIN_DIR" {
    const paths = try candidatePaths(testing.allocator, null, null);
    defer freeStrings(testing.allocator, paths);
    try testing.expectEqual(@as(usize, 0), paths.len);
}

test "loginShell uses $SHELL and falls back to /bin/sh" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings("/bin/sh", loginShell(&env));
    try env.put("SHELL", "/opt/homebrew/bin/fish");
    try testing.expectEqualStrings("/opt/homebrew/bin/fish", loginShell(&env));
    try env.put("SHELL", "");
    try testing.expectEqualStrings("/bin/sh", loginShell(&env));
}

test "firstLine returns the first non-empty trimmed line" {
    try testing.expectEqualStrings("Error: boom", firstLine("\n  Error: boom  \nmore\n"));
    try testing.expectEqualStrings("", firstLine(""));
}
