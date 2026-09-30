const std = @import("std");

/// Captures the outcome of a spawned child process, including its
/// stdout/stderr output and exit status.
pub const ExecResult = struct {
    stdout_data: []u8,
    stderr_data: []u8,
    exited_ok: bool,
    exit_code: u8,
};

/// Spawns a child process described by `argv`, optionally setting the
/// working directory to `cwd` (or inheriting the parent's when `null`).
/// Both stdout and stderr are captured up to 1 MiB each.
///
/// The returned `ExecResult` owns `stdout_data` and `stderr_data`;
/// free them with `freeExecResult`. `exited_ok` is `true` only when the
/// process exits with code 0; `exit_code` is 255 for non-exit
/// terminations (e.g. signals).
pub fn exec(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !ExecResult {
    // Note: `std.process.run` always spawns the child with stdin ignored
    // (`.stdin = .ignore` internally, i.e. /dev/null), so the child can
    // never consume terminal input meant for the TUI. `RunOptions` has no
    // stdin field; if that ever changes, keep stdin ignored here.
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });

    var exited_ok = false;
    var exit_code: u8 = 255;
    switch (result.term) {
        .exited => |code| {
            exit_code = code;
            exited_ok = code == 0;
        },
        else => {},
    }

    return .{
        .stdout_data = result.stdout,
        .stderr_data = result.stderr,
        .exited_ok = exited_ok,
        .exit_code = exit_code,
    };
}

/// Frees the heap-allocated stdout and stderr buffers inside an
/// `ExecResult`. The struct should not be used after this call.
pub fn freeExecResult(allocator: std.mem.Allocator, r: ExecResult) void {
    allocator.free(r.stdout_data);
    allocator.free(r.stderr_data);
}

/// Shared buffer for streaming process output to a UI thread.
/// The writer thread updates `lines`; the reader thread reads them atomically.
pub const ProgressOutput = struct {
    mutex: std.Io.Mutex = .init,
    lines: std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Creates a new empty ProgressOutput backed by `allocator`. The
    /// `io` handle is used for the internal mutex and must be safe to
    /// use from every thread that touches this object (the standard
    /// threaded Io implementation is).
    pub fn init(allocator: std.mem.Allocator, io: std.Io) ProgressOutput {
        return .{
            .lines = .empty,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Frees all stored lines and the backing list.
    pub fn deinit(self: *ProgressOutput) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }

    /// Appends a copy of `line` to the output buffer. Thread-safe.
    /// Silently drops the line on allocation failure.
    pub fn appendLine(self: *ProgressOutput, line: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const duped = self.allocator.dupe(u8, line) catch return;
        self.lines.append(self.allocator, duped) catch {
            self.allocator.free(duped);
        };
    }

    /// Get a snapshot of the last N lines. Caller must free each slice and the returned slice.
    pub fn getLastLines(self: *ProgressOutput, max: usize) []const []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const total = self.lines.items.len;
        if (total == 0) return &.{};
        const start = if (total > max) total - max else 0;
        const count = total - start;
        const result = self.allocator.alloc([]const u8, count) catch return &.{};
        for (0..count) |i| {
            result[i] = self.allocator.dupe(u8, self.lines.items[start + i]) catch "";
        }
        return result;
    }

    /// Frees a snapshot returned by `getLastLines`.
    pub fn freeLines(self: *ProgressOutput, lines: []const []const u8) void {
        if (lines.len == 0) return;
        for (lines) |line| {
            if (line.len > 0) self.allocator.free(line);
        }
        self.allocator.free(lines);
    }
};

/// Run a command and stream stderr lines to a ProgressOutput.
/// Git uses --progress to write to stderr; it also uses \r for in-place updates.
/// Stdout is ignored (not piped) to avoid a deadlock where the child blocks
/// writing to a full stdout pipe while we block reading stderr.
pub fn execWithProgress(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, progress: *ProgressOutput) !ExecResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
        .stdin = .ignore, // prevent child from consuming terminal input
        .stdout = .ignore,
        .stderr = .pipe,
    });

    // Read stderr, splitting on \r and \n for live progress lines.
    const stderr_file = child.stderr.?;
    var line_buf: [1024]u8 = undefined;
    var line_len: usize = 0;

    read_loop: while (true) {
        var read_buf: [256]u8 = undefined;
        const n = stderr_file.readStreaming(io, &.{&read_buf}) catch break :read_loop;
        if (n == 0) break;

        for (read_buf[0..n]) |byte| {
            if (byte == '\n' or byte == '\r') {
                if (line_len > 0) {
                    progress.appendLine(line_buf[0..line_len]);
                    line_len = 0;
                }
            } else {
                if (line_len < line_buf.len) {
                    line_buf[line_len] = byte;
                    line_len += 1;
                }
            }
        }
    }
    // Flush any remaining partial line
    if (line_len > 0) {
        progress.appendLine(line_buf[0..line_len]);
    }

    const term = try child.wait(io);

    var exited_ok = false;
    var exit_code: u8 = 255;
    switch (term) {
        .exited => |code| {
            exit_code = code;
            exited_ok = code == 0;
        },
        else => {},
    }

    // Build stderr_data from progress lines for compatibility
    var stderr_list: std.ArrayList(u8) = .empty;
    {
        progress.mutex.lockUncancelable(progress.io);
        defer progress.mutex.unlock(progress.io);
        for (progress.lines.items) |line| {
            stderr_list.appendSlice(allocator, line) catch {};
            stderr_list.append(allocator, '\n') catch {};
        }
    }

    return .{
        .stdout_data = try allocator.alloc(u8, 0),
        .stderr_data = stderr_list.toOwnedSlice(allocator) catch try allocator.alloc(u8, 0),
        .exited_ok = exited_ok,
        .exit_code = exit_code,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

test "ProgressOutput appends and retrieves lines" {
    const allocator = std.testing.allocator;
    var p = ProgressOutput.init(allocator, std.testing.io);
    defer p.deinit();

    p.appendLine("line one");
    p.appendLine("line two");
    p.appendLine("line three");

    try std.testing.expectEqual(3, p.lines.items.len);
    try std.testing.expectEqualStrings("line one", p.lines.items[0]);
    try std.testing.expectEqualStrings("line two", p.lines.items[1]);
    try std.testing.expectEqualStrings("line three", p.lines.items[2]);
}

test "ProgressOutput getLastLines returns all lines when fewer than max" {
    const allocator = std.testing.allocator;
    var p = ProgressOutput.init(allocator, std.testing.io);
    defer p.deinit();

    p.appendLine("alpha");
    p.appendLine("beta");

    const lines = p.getLastLines(5);
    defer p.freeLines(lines);

    try std.testing.expectEqual(2, lines.len);
    try std.testing.expectEqualStrings("alpha", lines[0]);
    try std.testing.expectEqualStrings("beta", lines[1]);
}

test "ProgressOutput getLastLines truncates to last N" {
    const allocator = std.testing.allocator;
    var p = ProgressOutput.init(allocator, std.testing.io);
    defer p.deinit();

    p.appendLine("one");
    p.appendLine("two");
    p.appendLine("three");
    p.appendLine("four");
    p.appendLine("five");

    const lines = p.getLastLines(3);
    defer p.freeLines(lines);

    try std.testing.expectEqual(3, lines.len);
    try std.testing.expectEqualStrings("three", lines[0]);
    try std.testing.expectEqualStrings("four", lines[1]);
    try std.testing.expectEqualStrings("five", lines[2]);
}

test "ProgressOutput getLastLines returns empty for no lines" {
    const allocator = std.testing.allocator;
    var p = ProgressOutput.init(allocator, std.testing.io);
    defer p.deinit();

    const lines = p.getLastLines(5);
    defer p.freeLines(lines);

    try std.testing.expectEqual(0, lines.len);
}

test "ProgressOutput getLastLines with max of 1 returns only the last line" {
    const allocator = std.testing.allocator;
    var p = ProgressOutput.init(allocator, std.testing.io);
    defer p.deinit();

    p.appendLine("first");
    p.appendLine("second");
    p.appendLine("third");

    const lines = p.getLastLines(1);
    defer p.freeLines(lines);

    try std.testing.expectEqual(1, lines.len);
    try std.testing.expectEqualStrings("third", lines[0]);
}

test "ProgressOutput lines are independent copies" {
    const allocator = std.testing.allocator;
    var p = ProgressOutput.init(allocator, std.testing.io);
    defer p.deinit();

    // Append from a stack buffer to verify the line is copied
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..5], "hello");
    p.appendLine(buf[0..5]);

    // Mutate the original buffer
    @memcpy(buf[0..5], "XXXXX");

    // The stored line should be unaffected
    try std.testing.expectEqualStrings("hello", p.lines.items[0]);
}

test "ProgressOutput freeLines handles empty slice" {
    const allocator = std.testing.allocator;
    var p = ProgressOutput.init(allocator, std.testing.io);
    defer p.deinit();

    // Should not crash or leak
    const lines = p.getLastLines(5);
    p.freeLines(lines);
}
