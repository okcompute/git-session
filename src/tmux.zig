const std = @import("std");
const term = @import("term.zig");
const process = @import("process.zig");
const repo = @import("repo.zig");

/// Returns a heap-allocated copy of `name` with dots replaced by
/// underscores, since tmux does not allow dots in session names.
/// The caller owns the returned slice.
pub fn sanitizeTmuxName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = if (c == '.') '_' else c;
    }
    return result;
}

/// Generates a tmux session name from the repository, branch, and
/// worktree names.
///
/// Format: `(<repo_name>/<sanitised_prefix>/) - <worktree>`
/// e.g.    `(my-project/feature/) - convert-lib-to-ts`
///
/// The prefix portion of `branch` (everything before the last `/`) has
/// dots replaced with underscores since tmux disallows dots in session
/// names. Note: `repo_name` and `worktree` are not sanitised.
///
/// When `branch` has no prefix (no `/`), the repo name alone is used:
///         `(my-project) - convert-lib-to-ts`
///
/// The caller owns the returned heap-allocated string.
pub fn tmuxSessionName(allocator: std.mem.Allocator, worktree: []const u8, branch: []const u8, repo_name: []const u8) ![]u8 {
    // Extract the prefix portion of the branch (everything before the last '/')
    var prefix: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, branch, '/')) |slash_pos| {
        prefix = branch[0 .. slash_pos + 1]; // include the trailing '/'
    }

    const sanitized = try sanitizeTmuxName(allocator, prefix);
    defer allocator.free(sanitized);

    if (sanitized.len > 0) {
        return std.fmt.allocPrint(allocator, "({s}/{s}) - {s}", .{ repo_name, sanitized, worktree });
    } else {
        return std.fmt.allocPrint(allocator, "({s}) - {s}", .{ repo_name, worktree });
    }
}

/// Returns `true` when a tmux session named `session_name` already
/// exists (`tmux has-session`). Returns `false` on any error (e.g.
/// tmux not installed or no server running).
pub fn tmuxSessionExists(allocator: std.mem.Allocator, io: std.Io, session_name: []const u8) bool {
    const result = process.exec(allocator, io, &.{ "tmux", "has-session", "-t", session_name }, null) catch return false;
    process.freeExecResult(allocator, result);
    return result.exited_ok;
}

/// The environment-variable name exported to every session window,
/// holding the worktree path so window commands can reference it.
const gs_repo_path_var = "GS_REPO_PATH";

/// Builds the argv for `tmux new-session` that creates a detached session
/// whose first window is `window_name`, with its working directory set to
/// `worktree_path` and the `GS_REPO_PATH` environment variable set to
/// `repo_path_env` (which must be of the form "GS_REPO_PATH=<path>").
///
/// The returned slice is owned by the caller and must be freed with
/// `allocator.free`; the string elements are borrowed from the arguments
/// and are not copied.
fn buildNewSessionArgs(
    allocator: std.mem.Allocator,
    session_name: []const u8,
    window_name: []const u8,
    worktree_path: []const u8,
    repo_path_env: []const u8,
) ![]const []const u8 {
    return try allocator.dupe([]const u8, &.{ "tmux", "new-session", "-s", session_name, "-n", window_name, "-d", "-c", worktree_path, "-e", repo_path_env });
}

/// Builds the argv for `tmux new-window` that adds a window named
/// `window_name` to `session_name`, with its working directory set to
/// `worktree_path` and the `GS_REPO_PATH` environment variable set to
/// `repo_path_env` (which must be of the form "GS_REPO_PATH=<path>").
///
/// The returned slice is owned by the caller and must be freed with
/// `allocator.free`; the string elements are borrowed from the arguments
/// and are not copied.
fn buildNewWindowArgs(
    allocator: std.mem.Allocator,
    session_name: []const u8,
    window_name: []const u8,
    worktree_path: []const u8,
    repo_path_env: []const u8,
) ![]const []const u8 {
    return try allocator.dupe([]const u8, &.{ "tmux", "new-window", "-n", window_name, "-t", session_name, "-c", worktree_path, "-e", repo_path_env });
}

/// Creates a new detached tmux session named `session_name` with its
/// working directory set to `worktree_path`. One window is created per
/// entry in `windows` (falling back to a single "shell" window when the
/// slice is empty), and the configured `command` is sent to each window
/// via `send-keys`. If a session with the same name already exists, the
/// function prints a message and returns without error. Returns
/// `error.TmuxSessionCreationFailed` when the `tmux new-session` command
/// fails.
///
/// The worktree path is exported to every window as the `GS_REPO_PATH`
/// environment variable, so configured commands can reference the
/// session's repository folder (e.g. `$GS_REPO_PATH`). This relies on
/// tmux's `-e` flag for `new-session`/`new-window`, which requires
/// tmux >= 3.0; on older tmux the session creation command will fail.
pub fn tmuxCreateSession(allocator: std.mem.Allocator, io: std.Io, session_name: []const u8, worktree_path: []const u8, windows: []const repo.WindowConfig) !void {
    if (tmuxSessionExists(allocator, io, session_name)) {
        term.print(io, "TMUX session '{s}' already exists.\n", .{session_name});
        return;
    }

    // Determine the first window name
    const first_win_name = if (windows.len > 0) windows[0].name else "shell";
    const effective_name = if (first_win_name.len > 0) first_win_name else "shell";

    // Expose the worktree path to window commands via the GS_REPO_PATH
    // environment variable. Passed with tmux's `-e` flag on new-session /
    // new-window so every window's initial shell (and any `command` sent via
    // send-keys) inherits it. The value is never interpolated into a shell
    // string, avoiding injection.
    const repo_path_env = try std.fmt.allocPrint(allocator, "{s}={s}", .{ gs_repo_path_var, worktree_path });
    defer allocator.free(repo_path_env);

    // Create the session with the first window
    const new_session_args = try buildNewSessionArgs(allocator, session_name, effective_name, worktree_path, repo_path_env);
    defer allocator.free(new_session_args);
    var r = try process.exec(allocator, io, new_session_args, null);
    process.freeExecResult(allocator, r);
    if (!r.exited_ok) {
        term.eprint(io, "Failed to create TMUX session.\n", .{});
        return error.TmuxSessionCreationFailed;
    }

    // Also set it at the session level so panes/windows created later
    // (e.g. by the user) inherit it too.
    r = try process.exec(allocator, io, &.{ "tmux", "set-environment", "-t", session_name, gs_repo_path_var, worktree_path }, null);
    process.freeExecResult(allocator, r);

    // Run commands in first window if configured
    if (windows.len > 0) {
        for (windows[0].commands.items) |cmd| {
            r = try process.exec(allocator, io, &.{ "tmux", "send-keys", "-t", session_name, cmd, "Enter" }, null);
            process.freeExecResult(allocator, r);
        }
    }

    // Create additional windows
    if (windows.len > 1) {
        for (windows[1..]) |win| {
            const win_name = if (win.name.len > 0) win.name else "shell";
            const new_window_args = try buildNewWindowArgs(allocator, session_name, win_name, worktree_path, repo_path_env);
            defer allocator.free(new_window_args);
            r = try process.exec(allocator, io, new_window_args, null);
            process.freeExecResult(allocator, r);

            for (win.commands.items) |cmd| {
                r = try process.exec(allocator, io, &.{ "tmux", "send-keys", "-t", session_name, cmd, "Enter" }, null);
                process.freeExecResult(allocator, r);
            }
        }
    }

    // Focus the first window
    const win1_target = try std.fmt.allocPrint(allocator, "{s}:1", .{session_name});
    defer allocator.free(win1_target);
    r = try process.exec(allocator, io, &.{ "tmux", "select-window", "-t", win1_target }, null);
    process.freeExecResult(allocator, r);
}

/// Kills the tmux session with the given name.
pub fn tmuxKillSession(allocator: std.mem.Allocator, io: std.Io, session_name: []const u8) !void {
    const r = try process.exec(allocator, io, &.{ "tmux", "kill-session", "-t", session_name }, null);
    process.freeExecResult(allocator, r);
}

/// Attaches to the tmux session named `session_name`. Detects whether
/// the process is already running inside tmux (via the `TMUX` env var)
/// and uses `switch-client` instead of `attach` to avoid nesting.
pub fn tmuxAttachOrSwitch(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, session_name: []const u8) !void {
    if (isInsideTmux(env)) {
        term.print(io, "Switching to TMUX session '{s}'\n", .{session_name});
        const r = try process.exec(allocator, io, &.{ "tmux", "switch-client", "-t", session_name }, null);
        process.freeExecResult(allocator, r);
    } else {
        term.print(io, "Attaching to TMUX session '{s}'\n", .{session_name});
        const r = try process.exec(allocator, io, &.{ "tmux", "attach", "-t", session_name }, null);
        process.freeExecResult(allocator, r);
    }
}

/// Returns the name of the current tmux session, or `null` if the
/// process is not running inside tmux or the name cannot be determined.
/// The returned slice is heap-allocated; the caller must free it with
/// `allocator.free`.
pub fn tmuxGetCurrentSession(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    if (!isInsideTmux(env)) return null;
    const r = process.exec(allocator, io, &.{ "tmux", "display-message", "-p", "#S" }, null) catch return null;
    defer allocator.free(r.stderr_data);
    if (!r.exited_ok) {
        allocator.free(r.stdout_data);
        return null;
    }
    // Trim trailing whitespace and dupe so the returned slice length matches
    // the allocation, allowing the caller to free it safely.
    const name = std.mem.trimEnd(u8, r.stdout_data, "\n\r ");
    defer allocator.free(r.stdout_data);
    if (name.len == 0) return null;
    return allocator.dupe(u8, name) catch null;
}

/// Returns the number of active tmux sessions by parsing the output of
/// `tmux list-sessions`. Returns `0` when tmux is not running or on any
/// error.
pub fn tmuxCountSessions(allocator: std.mem.Allocator, io: std.Io) usize {
    const r = process.exec(allocator, io, &.{ "tmux", "list-sessions", "-F", "#{session_name}" }, null) catch return 0;
    defer process.freeExecResult(allocator, r);
    if (!r.exited_ok or r.stdout_data.len == 0) return 0;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, r.stdout_data, '\n');
    while (it.next()) |line| {
        if (line.len > 0) count += 1;
    }
    return count;
}

/// Returns `true` when a tmux client is currently attached to the given
/// session. Uses `tmux list-clients -t <session_name>` which only
/// returns clients viewing that session. This is more reliable than
/// `tmux display-message -p #S` which may return the session owning the
/// pane rather than the session the client is actively viewing (e.g.
/// after the user has switched to a different session).
pub fn tmuxClientIsAttachedToSession(allocator: std.mem.Allocator, io: std.Io, session_name: []const u8) bool {
    const r = process.exec(allocator, io, &.{ "tmux", "list-clients", "-t", session_name, "-F", "#{client_tty}" }, null) catch return false;
    defer process.freeExecResult(allocator, r);
    if (!r.exited_ok) return false;
    // If any client TTY is returned, a client is viewing this session.
    const trimmed = std.mem.trimEnd(u8, r.stdout_data, "\n\r ");
    return trimmed.len > 0;
}

/// Returns `true` when the process is running inside a tmux session
/// (i.e. the `TMUX` environment variable is set).
pub fn isInsideTmux(env: *const std.process.Environ.Map) bool {
    return env.get("TMUX") != null;
}

/// Returns the tmux client tty (e.g. `/dev/ttys001`) for the current
/// process, or `null` when not inside tmux. The returned slice is
/// heap-allocated; the caller must free it.
pub fn tmuxGetClientName(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    if (!isInsideTmux(env)) return null;
    const r = process.exec(allocator, io, &.{ "tmux", "display-message", "-p", "#{client_tty}" }, null) catch return null;
    defer allocator.free(r.stderr_data);
    if (!r.exited_ok) {
        allocator.free(r.stdout_data);
        return null;
    }
    const name = std.mem.trimEnd(u8, r.stdout_data, "\n\r ");
    defer allocator.free(r.stdout_data);
    if (name.len == 0) return null;
    return allocator.dupe(u8, name) catch null;
}

/// Returns the session name that `client_name` is currently attached to,
/// or `null` on error. Uses `tmux list-clients -t <client> -F` which
/// reliably reports the session even after `switch-client` (unlike
/// `display-message -c` which returns the session of the calling pane).
/// The returned slice is heap-allocated.
pub fn tmuxGetClientSession(allocator: std.mem.Allocator, io: std.Io, client_name: []const u8) ?[]const u8 {
    const r = process.exec(allocator, io, &.{ "tmux", "list-clients", "-t", client_name, "-F", "#{session_name}" }, null) catch return null;
    defer allocator.free(r.stderr_data);
    if (!r.exited_ok) {
        allocator.free(r.stdout_data);
        return null;
    }
    const name = std.mem.trimEnd(u8, r.stdout_data, "\n\r ");
    defer allocator.free(r.stdout_data);
    if (name.len == 0) return null;
    return allocator.dupe(u8, name) catch null;
}

/// Shows an interactive tmux pop-up asking whether to switch to a
/// session. The pop-up runs a small shell script: on "y" it executes
/// `tmux switch-client`, on any other key it closes. The `-E` flag
/// auto-closes the pop-up when the script exits.
///
/// The session name is passed via the `GS_SESSION` environment variable
/// (using `-e`) to avoid shell injection — it is never interpolated
/// into the shell command string.
///
/// `client_name` is the target client tty (e.g. `/dev/ttys001`).
/// If `null`, the pop-up targets the current client.
pub fn tmuxDisplayPopup(allocator: std.mem.Allocator, io: std.Io, session_name: []const u8, client_name: ?[]const u8) void {
    // Pass session name as an environment variable to avoid shell injection.
    const env_arg = std.fmt.allocPrint(allocator, "GS_SESSION={s}", .{session_name}) catch return;
    defer allocator.free(env_arg);

    // The shell script reads from $GS_SESSION — never interpreted by the shell.
    const shell_cmd = "printf '\\n  Session created: %s\\n\\n  Switch to this session? (y/n) ' \"$GS_SESSION\"; read ans; [ \"$ans\" = y ] && tmux switch-client -t \"$GS_SESSION\"";

    if (client_name) |client| {
        const r = process.exec(allocator, io, &.{ "tmux", "display-popup", "-E", "-w", "60", "-h", "8", "-T", " git-session ", "-e", env_arg, "-c", client, shell_cmd }, null) catch return;
        process.freeExecResult(allocator, r);
    } else {
        const r = process.exec(allocator, io, &.{ "tmux", "display-popup", "-E", "-w", "60", "-h", "8", "-T", " git-session ", "-e", env_arg, shell_cmd }, null) catch return;
        process.freeExecResult(allocator, r);
    }
}

/// Shows an ephemeral notification in the tmux status line that
/// auto-dismisses after `delay_ms` milliseconds. The `-N` flag
/// prevents key presses from dismissing it early.
///
/// `client_name` is the target client tty. If `null`, targets the
/// current client.
pub fn tmuxNotify(allocator: std.mem.Allocator, io: std.Io, message: []const u8, delay_ms: u32, client_name: ?[]const u8) void {
    const delay_str = std.fmt.allocPrint(allocator, "{d}", .{delay_ms}) catch return;
    defer allocator.free(delay_str);

    if (client_name) |client| {
        const r = process.exec(allocator, io, &.{ "tmux", "display-message", "-N", "-d", delay_str, "-c", client, message }, null) catch return;
        process.freeExecResult(allocator, r);
    } else {
        const r = process.exec(allocator, io, &.{ "tmux", "display-message", "-N", "-d", delay_str, message }, null) catch return;
        process.freeExecResult(allocator, r);
    }
}

/// When other sessions exist it switches to the last-active (or next)
/// session; when `session_name` is the only session it detaches the
/// client instead.
///
/// Does nothing when not inside tmux or when no client is actively
/// viewing `session_name` (e.g. the user already switched to a
/// different session).
pub fn tmuxSwitchAwayIfCurrent(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, session_name: []const u8) void {
    if (env.get("TMUX") == null) return;

    if (!tmuxClientIsAttachedToSession(allocator, io, session_name)) return;

    // A client is viewing the session that is about to be killed.
    if (tmuxCountSessions(allocator, io) <= 1) {
        // It's the only session -- detach the client so we don't get dropped.
        term.print(io, "Detaching from TMUX (last session).\n", .{});
        const r = process.exec(allocator, io, &.{ "tmux", "detach-client", "-s", session_name }, null) catch return;
        process.freeExecResult(allocator, r);
    } else {
        // Switch to the last active session; fall back to next if no "last" exists.
        term.print(io, "Switching to last TMUX session.\n", .{});
        const r = process.exec(allocator, io, &.{ "tmux", "switch-client", "-l" }, null) catch return;
        defer process.freeExecResult(allocator, r);
        if (!r.exited_ok) {
            const r2 = process.exec(allocator, io, &.{ "tmux", "switch-client", "-n" }, null) catch return;
            process.freeExecResult(allocator, r2);
        }
    }
}

/// Sends `C-c` followed by `exit\n` to every pane in the given tmux
/// session. This encourages shells and editors to terminate and release
/// their working directory, making it safe to remove the worktree
/// directory immediately afterwards. Failures are silently ignored --
/// this is a best-effort cleanup step.
pub fn tmuxSendExitToAllPanes(allocator: std.mem.Allocator, io: std.Io, session_name: []const u8) void {
    // List all pane IDs in the session (e.g. "%0\n%1\n%3\n").
    const r = process.exec(allocator, io, &.{ "tmux", "list-panes", "-s", "-t", session_name, "-F", "#{pane_id}" }, null) catch return;
    defer process.freeExecResult(allocator, r);
    if (!r.exited_ok) return;

    var it = std.mem.splitScalar(u8, r.stdout_data, '\n');
    while (it.next()) |pane_id| {
        if (pane_id.len == 0) continue;

        // Send C-c to interrupt any running command.
        const r1 = process.exec(allocator, io, &.{ "tmux", "send-keys", "-t", pane_id, "C-c", "" }, null) catch continue;
        process.freeExecResult(allocator, r1);

        // Send 'exit' to terminate the shell.
        const r2 = process.exec(allocator, io, &.{ "tmux", "send-keys", "-t", pane_id, "exit", "Enter" }, null) catch continue;
        process.freeExecResult(allocator, r2);
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "sanitizeTmuxName replaces dots with underscores" {
    const allocator = testing.allocator;
    const result = try sanitizeTmuxName(allocator, "my.session.name");
    defer allocator.free(result);
    try testing.expectEqualStrings("my_session_name", result);
}

test "sanitizeTmuxName leaves strings without dots unchanged" {
    const allocator = testing.allocator;
    const result = try sanitizeTmuxName(allocator, "my-session-name");
    defer allocator.free(result);
    try testing.expectEqualStrings("my-session-name", result);
}

test "sanitizeTmuxName handles empty string" {
    const allocator = testing.allocator;
    const result = try sanitizeTmuxName(allocator, "");
    defer allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "tmuxSessionName with prefixed branch" {
    const allocator = testing.allocator;
    const result = try tmuxSessionName(allocator, "convert-lib", "feature/convert-lib", "my-project");
    defer allocator.free(result);
    try testing.expectEqualStrings("(my-project/feature/) - convert-lib", result);
}

test "tmuxSessionName with unprefixed branch" {
    const allocator = testing.allocator;
    const result = try tmuxSessionName(allocator, "main-worktree", "main", "my-project");
    defer allocator.free(result);
    try testing.expectEqualStrings("(my-project) - main-worktree", result);
}

test "tmuxSessionName with nested prefix" {
    const allocator = testing.allocator;
    const result = try tmuxSessionName(allocator, "my-feature", "feature/team/my-feature", "repo");
    defer allocator.free(result);
    try testing.expectEqualStrings("(repo/feature/team/) - my-feature", result);
}

test "tmuxSessionName sanitizes dots in prefix" {
    const allocator = testing.allocator;
    const result = try tmuxSessionName(allocator, "fix-it", "bug.fix/fix-it", "app");
    defer allocator.free(result);
    try testing.expectEqualStrings("(app/bug_fix/) - fix-it", result);
}

/// Asserts that `args` contains `-e` immediately followed by
/// `GS_REPO_PATH=<worktree_path>` — i.e. the environment variable is
/// passed to tmux as a single, correctly-formed argument.
fn expectRepoPathEnvArg(args: []const []const u8, worktree_path: []const u8) !void {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-e")) {
            const value = args[i + 1];
            try testing.expect(std.mem.startsWith(u8, value, "GS_REPO_PATH="));
            try testing.expectEqualStrings(worktree_path, value["GS_REPO_PATH=".len..]);
            return;
        }
    }
    return error.RepoPathEnvArgNotFound;
}

test "buildNewSessionArgs sets GS_REPO_PATH to the worktree path" {
    const allocator = testing.allocator;
    const worktree_path = "/home/user/repo/my-session";
    const repo_path_env = try std.fmt.allocPrint(allocator, "GS_REPO_PATH={s}", .{worktree_path});
    defer allocator.free(repo_path_env);

    const args = try buildNewSessionArgs(allocator, "sess", "editor", worktree_path, repo_path_env);
    defer allocator.free(args);

    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "tmux", "new-session", "-s", "sess", "-n", "editor", "-d", "-c", worktree_path, "-e", "GS_REPO_PATH=/home/user/repo/my-session" }),
        args,
    );
    try expectRepoPathEnvArg(args, worktree_path);
}

test "buildNewWindowArgs sets GS_REPO_PATH to the worktree path" {
    const allocator = testing.allocator;
    const worktree_path = "/home/user/repo/my-session";
    const repo_path_env = try std.fmt.allocPrint(allocator, "GS_REPO_PATH={s}", .{worktree_path});
    defer allocator.free(repo_path_env);

    const args = try buildNewWindowArgs(allocator, "sess", "logs", worktree_path, repo_path_env);
    defer allocator.free(args);

    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "tmux", "new-window", "-n", "logs", "-t", "sess", "-c", worktree_path, "-e", "GS_REPO_PATH=/home/user/repo/my-session" }),
        args,
    );
    try expectRepoPathEnvArg(args, worktree_path);
}

test "buildNewSessionArgs passes worktree path with special characters verbatim" {
    const allocator = testing.allocator;
    // A path containing spaces and shell metacharacters must be passed as a
    // single discrete argv element, never interpolated into a shell string.
    const worktree_path = "/tmp/weird path;$(echo hi)";
    const repo_path_env = try std.fmt.allocPrint(allocator, "GS_REPO_PATH={s}", .{worktree_path});
    defer allocator.free(repo_path_env);

    const args = try buildNewSessionArgs(allocator, "s", "w", worktree_path, repo_path_env);
    defer allocator.free(args);

    try expectRepoPathEnvArg(args, worktree_path);
}
