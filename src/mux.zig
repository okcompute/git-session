const std = @import("std");
const term = @import("term.zig");
const repo = @import("repo.zig");
const tmux = @import("tmux.zig");
const rex = @import("rex.zig");

/// The terminal multiplexers git-session can drive.
pub const Kind = enum {
    tmux,
    rex,

    /// Parses a `multiplexer` config value (case-insensitive).
    pub fn parse(value: []const u8) ?Kind {
        if (std.ascii.eqlIgnoreCase(value, "tmux")) return .tmux;
        if (std.ascii.eqlIgnoreCase(value, "rex")) return .rex;
        return null;
    }
};

/// Picks the backend. An explicit `configured` value (the `multiplexer`
/// key of config.toml) always wins. Without one, Rex is auto-detected
/// when git-session runs in a Rex terminal (`REX_SESSION` set) that is
/// not also inside tmux (`TMUX` unset); otherwise tmux, the default.
pub fn chooseKind(configured: ?[]const u8, rex_session_env: ?[]const u8, tmux_env: ?[]const u8) error{UnknownMultiplexer}!Kind {
    if (configured) |value| return Kind.parse(value) orelse error.UnknownMultiplexer;
    const in_rex = if (rex_session_env) |v| v.len > 0 else false;
    if (in_rex and tmux_env == null) return .rex;
    return .tmux;
}

/// A selected multiplexer backend. The `tmux` arm forwards to the
/// functions in `tmux.zig` unchanged; the `rex` arm to `rex.zig`.
///
/// Methods that only make sense for tmux's client model (client name,
/// pop-ups, status-line notifications) return `null` / do nothing for
/// Rex: Rex does not report which session the app is showing, so the TUI
/// never takes its "user switched away" path with that backend.
pub const Mux = union(Kind) {
    tmux,
    rex: rex.Rex,

    /// Selects the backend from `configured` and the environment, and
    /// resolves the `rex` CLI when Rex is chosen. Call `deinit` with the
    /// same allocator.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, configured: ?[]const u8) !Mux {
        return switch (try chooseKind(configured, env.get("REX_SESSION"), env.get("TMUX"))) {
            .tmux => .tmux,
            .rex => .{ .rex = .{ .bin = try rex.findBinary(allocator, io, env) } },
        };
    }

    /// Like `init`, but prints a clear message and exits the process
    /// (status 1) when the backend cannot be set up.
    pub fn initOrExit(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, configured: ?[]const u8) Mux {
        return init(allocator, io, env, configured) catch |err| {
            switch (err) {
                error.UnknownMultiplexer => term.eprint(
                    io,
                    "Error: unknown multiplexer \"{s}\" in ~/.config/git-session/config.toml. Use \"tmux\" or \"rex\".\n",
                    .{configured orelse ""},
                ),
                error.RexNotFound => term.eprint(
                    io,
                    "Error: the `rex` command was not found on PATH or in $REX_BIN_DIR.\n" ++
                        "Rex (macOS app, public beta) only puts `rex` on PATH in its own terminals.\n" ++
                        "Run git-session from a Rex terminal, or link the CLI shipped in the Rex app into a directory on your PATH.\n",
                    .{},
                ),
                else => term.eprint(io, "Error: could not set up the terminal multiplexer: {any}\n", .{err}),
            }
            std.process.exit(1);
        };
    }

    /// Frees the resolved `rex` path (nothing to free for tmux).
    pub fn deinit(self: Mux, allocator: std.mem.Allocator) void {
        switch (self) {
            .tmux => {},
            .rex => |r| allocator.free(r.bin),
        }
    }

    /// Exits with status 4 and a clear message when the backend's server
    /// cannot be reached. A no-op for tmux, whose commands already
    /// tolerate a missing server.
    pub fn ensureReadyOrExit(self: Mux, allocator: std.mem.Allocator, io: std.Io) void {
        switch (self) {
            .tmux => {},
            .rex => |r| r.ensureServerRunning(allocator, io) catch |err| switch (err) {
                error.RexServerNotRunning => std.process.exit(rex.exit_server_unreachable),
                else => std.process.exit(1),
            },
        }
    }

    /// Human-readable backend name used in messages ("tmux" / "Rex").
    pub fn displayName(self: Mux) []const u8 {
        return switch (self) {
            .tmux => "tmux",
            .rex => "Rex",
        };
    }

    /// Generates the session name for a worktree. The caller owns it.
    pub fn sessionName(self: Mux, allocator: std.mem.Allocator, worktree: []const u8, branch: []const u8, repo_name: []const u8) ![]u8 {
        return switch (self) {
            .tmux => tmux.tmuxSessionName(allocator, worktree, branch, repo_name),
            .rex => rex.sessionLabel(allocator, worktree, branch, repo_name),
        };
    }

    /// Returns `true` when a session named `name` exists; `false` on any
    /// error (e.g. no server running).
    pub fn sessionExists(self: Mux, allocator: std.mem.Allocator, io: std.Io, name: []const u8) bool {
        return switch (self) {
            .tmux => tmux.tmuxSessionExists(allocator, io, name),
            .rex => |r| r.sessionExists(allocator, io, name),
        };
    }

    /// Creates the session with one window per `windows` entry. Does
    /// nothing (besides printing a message) when it already exists.
    pub fn createSession(
        self: Mux,
        allocator: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        name: []const u8,
        worktree_path: []const u8,
        windows: []const repo.WindowConfig,
    ) !void {
        return switch (self) {
            .tmux => tmux.tmuxCreateSession(allocator, io, name, worktree_path, windows),
            .rex => |r| r.createSession(allocator, io, env, name, worktree_path, windows),
        };
    }

    /// Kills the session named `name` (with Rex: every session with that label).
    pub fn killSession(self: Mux, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
        return switch (self) {
            .tmux => tmux.tmuxKillSession(allocator, io, name),
            .rex => |r| r.killSession(allocator, io, name),
        };
    }

    /// tmux: attaches, or switches the client when already inside tmux.
    /// Rex: asks the Rex app to show the session.
    pub fn attachOrSwitch(self: Mux, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) !void {
        return switch (self) {
            .tmux => tmux.tmuxAttachOrSwitch(allocator, io, env, name),
            .rex => |r| r.attachOrSwitch(allocator, io, name),
        };
    }

    /// Moves the user off `name` before it is torn down, when they are
    /// in it. Best-effort.
    pub fn switchAwayIfCurrent(self: Mux, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) void {
        switch (self) {
            .tmux => tmux.tmuxSwitchAwayIfCurrent(allocator, io, env, name),
            .rex => |r| r.switchAwayIfCurrent(allocator, io, env, name),
        }
    }

    /// Sends Ctrl-C then `exit` to every pane/block of the session so
    /// programs release the worktree directory. Best-effort.
    pub fn stopPanes(self: Mux, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) void {
        switch (self) {
            .tmux => tmux.tmuxSendExitToAllPanes(allocator, io, name),
            .rex => |r| r.stopPanes(allocator, io, env, name),
        }
    }

    /// Waits briefly (~500 ms at most) for the panes signalled by
    /// `stopPanes` to exit.
    pub fn waitForPanesToExit(self: Mux, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) void {
        switch (self) {
            .tmux => {
                var attempts: u8 = 0;
                while (attempts < 10) : (attempts += 1) {
                    if (!tmux.tmuxSessionExists(allocator, io, name)) break;
                    io.sleep(.fromMilliseconds(50), .awake) catch {};
                }
            },
            .rex => |r| r.waitForPanesToExit(allocator, io, env, name),
        }
    }

    /// Whether git-session runs inside this multiplexer.
    pub fn isInside(self: Mux, env: *const std.process.Environ.Map) bool {
        return switch (self) {
            .tmux => tmux.isInsideTmux(env),
            .rex => env.get("REX_SESSION") != null,
        };
    }

    /// tmux client tty of this process; always `null` for Rex.
    pub fn clientName(self: Mux, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
        return switch (self) {
            .tmux => tmux.tmuxGetClientName(allocator, io, env),
            .rex => null,
        };
    }

    /// Session the given tmux client is viewing; always `null` for Rex.
    pub fn clientSession(self: Mux, allocator: std.mem.Allocator, io: std.Io, client_name: []const u8) ?[]const u8 {
        return switch (self) {
            .tmux => tmux.tmuxGetClientSession(allocator, io, client_name),
            .rex => null,
        };
    }

    /// Current tmux session of this process; always `null` for Rex.
    pub fn currentSession(self: Mux, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
        return switch (self) {
            .tmux => tmux.tmuxGetCurrentSession(allocator, io, env),
            .rex => null,
        };
    }

    /// tmux pop-up offering to switch to `name`; a no-op for Rex.
    pub fn displayPopup(self: Mux, allocator: std.mem.Allocator, io: std.Io, name: []const u8, client_name: ?[]const u8) void {
        switch (self) {
            .tmux => tmux.tmuxDisplayPopup(allocator, io, name, client_name),
            .rex => {},
        }
    }

    /// tmux status-line notification; a no-op for Rex.
    pub fn notify(self: Mux, allocator: std.mem.Allocator, io: std.Io, message: []const u8, delay_ms: u32, client_name: ?[]const u8) void {
        switch (self) {
            .tmux => tmux.tmuxNotify(allocator, io, message, delay_ms, client_name),
            .rex => {},
        }
    }
};

// ===========================================================================
// Cross-backend cleanup and lookup
//
// A worktree created while one backend was selected keeps its terminal
// session there even after the user switches backends. Removal therefore
// cleans up both backends, and the TUI session lists show where each
// worktree currently has a live session.
// ===========================================================================

/// Identifies a git-session session by what its terminal-session name is
/// derived from, so the name can be computed for any backend.
pub const SessionRef = struct {
    worktree: []const u8,
    branch: []const u8,
    repo_name: []const u8,
};

/// The active backend plus the other one when it is usable: tmux is always
/// tried (its commands fail quietly when tmux is missing), Rex only when
/// the `rex` CLI is found. Call `deinit` with the allocator given to `init`.
pub const Backends = struct {
    active: Mux,
    /// Owned by this struct (it may hold a resolved `rex` path).
    other: ?Mux = null,

    /// Resolves the non-active backend. Never fails: an unusable backend
    /// is simply left out.
    pub fn init(active: Mux, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Backends {
        const other: ?Mux = switch (active) {
            .rex => .tmux,
            .tmux => if (rex.findBinary(allocator, io, env)) |bin| Mux{ .rex = .{ .bin = bin } } else |_| null,
        };
        return .{ .active = active, .other = other };
    }

    /// Frees the resolved other backend; the active one is not owned.
    pub fn deinit(self: Backends, allocator: std.mem.Allocator) void {
        if (self.other) |o| o.deinit(allocator);
    }

    /// Returns the backends in order: active first.
    fn all(self: Backends) [2]?Mux {
        return .{ self.active, self.other };
    }

    /// Moves the user off the session in every backend they are in.
    pub fn switchAway(self: Backends, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, ref: SessionRef) void {
        for (self.all()) |maybe| {
            const m = maybe orelse continue;
            const name = m.sessionName(allocator, ref.worktree, ref.branch, ref.repo_name) catch continue;
            defer allocator.free(name);
            m.switchAwayIfCurrent(allocator, io, env, name);
        }
    }

    /// Asks programs in every backend's session to exit and waits briefly
    /// for them to release the worktree directory.
    pub fn stopAndWait(self: Backends, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, ref: SessionRef) void {
        for (self.all()) |maybe| {
            const m = maybe orelse continue;
            const name = m.sessionName(allocator, ref.worktree, ref.branch, ref.repo_name) catch continue;
            defer allocator.free(name);
            if (m.sessionExists(allocator, io, name)) {
                m.stopPanes(allocator, io, env, name);
                m.waitForPanesToExit(allocator, io, env, name);
            }
        }
    }

    /// Kills the session in every backend that has it. The backend this
    /// process runs inside goes last: killing that session may end
    /// git-session itself.
    pub fn killSessions(self: Backends, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, ref: SessionRef) void {
        for ([_]bool{ false, true }) |inside_pass| {
            for (self.all()) |maybe| {
                const m = maybe orelse continue;
                if (m.isInside(env) != inside_pass) continue;
                const name = m.sessionName(allocator, ref.worktree, ref.branch, ref.repo_name) catch continue;
                defer allocator.free(name);
                if (m.sessionExists(allocator, io, name)) {
                    m.killSession(allocator, io, name) catch {};
                }
            }
        }
    }
};

/// Where a worktree currently has a live terminal session.
pub const Presence = struct {
    tmux: bool = false,
    rex: bool = false,

    /// Suffix shown after the worktree name in TUI lists, e.g. " [tmux]".
    /// Empty when no session exists in any backend.
    pub fn tag(self: Presence) []const u8 {
        if (self.tmux and self.rex) return "  [tmux, Rex]";
        if (self.tmux) return "  [tmux]";
        if (self.rex) return "  [Rex]";
        return "";
    }
};

/// Snapshot of the live session names in every available backend, taken
/// with one listing per backend. Call `deinit` to free it.
pub const SessionIndex = struct {
    tmux_names: [][]u8 = &.{},
    rex_labels: [][]u8 = &.{},

    /// Lists sessions in each of `backends`. A backend that cannot be
    /// queried (not installed, server down) contributes no names.
    pub fn load(backends: Backends, allocator: std.mem.Allocator, io: std.Io) SessionIndex {
        var index: SessionIndex = .{};
        for (backends.all()) |maybe| {
            const m = maybe orelse continue;
            switch (m) {
                .tmux => index.tmux_names = tmux.tmuxListSessionNames(allocator, io),
                .rex => |r| index.rex_labels = rexLabels(r, allocator, io) catch &.{},
            }
        }
        return index;
    }

    /// Returns the labels of every Rex session. Caller owns the result.
    fn rexLabels(r: rex.Rex, allocator: std.mem.Allocator, io: std.Io) ![][]u8 {
        const sessions = try r.listSessions(allocator, io);
        defer rex.freeSessions(allocator, sessions);
        var labels: std.ArrayList([]u8) = .empty;
        errdefer {
            for (labels.items) |l| allocator.free(l);
            labels.deinit(allocator);
        }
        for (sessions) |s| {
            const label = try allocator.dupe(u8, s.label);
            errdefer allocator.free(label);
            try labels.append(allocator, label);
        }
        return labels.toOwnedSlice(allocator);
    }

    /// Frees every listed name.
    pub fn deinit(self: SessionIndex, allocator: std.mem.Allocator) void {
        rex.freeStrings(allocator, self.tmux_names);
        rex.freeStrings(allocator, self.rex_labels);
    }

    /// Reports in which backends the session for `ref` is live. Returns an
    /// empty presence when its names cannot be computed.
    pub fn presence(self: SessionIndex, allocator: std.mem.Allocator, ref: SessionRef) Presence {
        var p: Presence = .{};
        if (tmux.tmuxSessionName(allocator, ref.worktree, ref.branch, ref.repo_name)) |name| {
            defer allocator.free(name);
            for (self.tmux_names) |listed| {
                if (tmux.sessionNameMatches(listed, name)) p.tmux = true;
            }
        } else |_| {}
        if (rex.sessionLabel(allocator, ref.worktree, ref.branch, ref.repo_name)) |label| {
            defer allocator.free(label);
            for (self.rex_labels) |listed| {
                if (std.mem.eql(u8, listed, label)) p.rex = true;
            }
        } else |_| {}
        return p;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Kind.parse accepts tmux and rex case-insensitively" {
    try testing.expectEqual(Kind.tmux, Kind.parse("tmux").?);
    try testing.expectEqual(Kind.rex, Kind.parse("rex").?);
    try testing.expectEqual(Kind.rex, Kind.parse("Rex").?);
    try testing.expect(Kind.parse("screen") == null);
    try testing.expect(Kind.parse("") == null);
}

test "chooseKind defaults to tmux" {
    try testing.expectEqual(Kind.tmux, try chooseKind(null, null, null));
}

test "chooseKind auto-detects Rex inside a Rex terminal" {
    try testing.expectEqual(Kind.rex, try chooseKind(null, "session:abc", null));
}

test "chooseKind keeps tmux when running tmux inside a Rex terminal" {
    try testing.expectEqual(Kind.tmux, try chooseKind(null, "session:abc", "/tmp/tmux-501/default,1,0"));
}

test "chooseKind ignores an empty REX_SESSION" {
    try testing.expectEqual(Kind.tmux, try chooseKind(null, "", null));
}

test "chooseKind: explicit config beats detection" {
    try testing.expectEqual(Kind.tmux, try chooseKind("tmux", "session:abc", null));
    try testing.expectEqual(Kind.rex, try chooseKind("rex", null, "/tmp/tmux-501/default,1,0"));
}

test "chooseKind rejects an unknown configured value" {
    try testing.expectError(error.UnknownMultiplexer, chooseKind("zellij", null, null));
}

test "Mux.init selects tmux without touching the filesystem" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const m = try Mux.init(testing.allocator, testing.io, &env, null);
    defer m.deinit(testing.allocator);
    try testing.expect(m == .tmux);
    try testing.expectEqualStrings("tmux", m.displayName());
}

test "Mux.init reports RexNotFound when rex is not on PATH or in REX_BIN_DIR" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/nonexistent-git-session-test-dir");
    try testing.expectError(error.RexNotFound, Mux.init(testing.allocator, testing.io, &env, "rex"));
}

test "Mux.sessionName keeps the tmux name and uses the short Rex label" {
    const t = try (Mux{ .tmux = {} }).sessionName(testing.allocator, "fix-it", "bug.fix/fix-it", "app");
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("(app/bug_fix/) - fix-it", t);
    const r = try (Mux{ .rex = .{ .bin = "rex" } }).sessionName(testing.allocator, "fix-it", "bug.fix/fix-it", "app");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("app · fix-it", r);
}

test "Presence.tag names every backend holding a session" {
    try testing.expectEqualStrings("", (Presence{}).tag());
    try testing.expectEqualStrings("  [tmux]", (Presence{ .tmux = true }).tag());
    try testing.expectEqualStrings("  [Rex]", (Presence{ .rex = true }).tag());
    try testing.expectEqualStrings("  [tmux, Rex]", (Presence{ .tmux = true, .rex = true }).tag());
}

/// Builds an owned `[][]u8` copy of `items` for SessionIndex tests.
fn ownedNames(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, items.len);
    for (items, 0..) |s, i| out[i] = try allocator.dupe(u8, s);
    return out;
}

test "SessionIndex.presence finds a worktree's session in each backend" {
    const allocator = testing.allocator;
    const index = SessionIndex{
        .tmux_names = try ownedNames(allocator, &.{ "(app/feature/) - login", "other" }),
        .rex_labels = try ownedNames(allocator, &.{ "app · search", "app · login" }),
    };
    defer index.deinit(allocator);

    const login = index.presence(allocator, .{ .worktree = "login", .branch = "feature/login", .repo_name = "app" });
    try testing.expect(login.tmux and login.rex);

    const search = index.presence(allocator, .{ .worktree = "search", .branch = "feature/search", .repo_name = "app" });
    try testing.expect(!search.tmux and search.rex);

    const gone = index.presence(allocator, .{ .worktree = "gone", .branch = "feature/gone", .repo_name = "app" });
    try testing.expect(!gone.tmux and !gone.rex);
}

test "SessionIndex.presence matches tmux names that tmux rewrote" {
    // tmux stores "my.app" as "my_app"; the tag must still appear.
    const allocator = testing.allocator;
    const index = SessionIndex{ .tmux_names = try ownedNames(allocator, &.{"(my_app) - x"}) };
    defer index.deinit(allocator);
    const p = index.presence(allocator, .{ .worktree = "x", .branch = "x", .repo_name = "my.app" });
    try testing.expect(p.tmux and !p.rex);
}

test "SessionIndex.presence matches truncated Rex labels" {
    const allocator = testing.allocator;
    const worktree = "w" ** 200;
    const label = try rex.sessionLabel(allocator, worktree, worktree, "app");
    defer allocator.free(label);
    const index = SessionIndex{ .rex_labels = try ownedNames(allocator, &.{label}) };
    defer index.deinit(allocator);
    try testing.expect(index.presence(allocator, .{ .worktree = worktree, .branch = worktree, .repo_name = "app" }).rex);
}

test "SessionIndex: an empty index frees cleanly" {
    const index = SessionIndex{};
    index.deinit(testing.allocator);
}

test "Backends.init pairs Rex with tmux" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const b = Backends.init(.{ .rex = .{ .bin = "rex" } }, testing.allocator, testing.io, &env);
    defer b.deinit(testing.allocator);
    try testing.expect(b.other.? == .tmux);
}

test "Backends.init leaves Rex out when the rex CLI is missing" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/nonexistent-git-session-test-dir");
    const b = Backends.init(.tmux, testing.allocator, testing.io, &env);
    defer b.deinit(testing.allocator);
    try testing.expect(b.other == null);
}

test "Mux.isInside checks the backend's own environment variable" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const t: Mux = .tmux;
    const r: Mux = .{ .rex = .{ .bin = "rex" } };
    try testing.expect(!t.isInside(&env));
    try testing.expect(!r.isInside(&env));
    try env.put("REX_SESSION", "session:abc");
    try testing.expect(r.isInside(&env));
    try testing.expect(!t.isInside(&env));
}
