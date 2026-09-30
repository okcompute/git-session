const std = @import("std");

/// Standard output handle.
pub const stdout_file = std.Io.File.stdout();
/// Standard error handle.
pub const stderr_file = std.Io.File.stderr();
/// Standard input handle.
pub const stdin_file = std.Io.File.stdin();

/// When true, print() and eprint() are suppressed.
/// Set this while the TUI is active to prevent raw output from
/// corrupting the alternate screen.
var quiet: bool = false;

/// Enable or disable quiet mode. When quiet, print() and eprint()
/// silently discard their output. Used by the TUI to prevent raw
/// writes from library code (git.zig, tmux.zig) bleeding into the
/// alternate screen buffer.
pub fn setQuiet(q: bool) void {
    quiet = q;
}

/// Formats and writes a message to stdout. Silently drops output on
/// formatting or write errors so that it can be used in fire-and-forget
/// contexts.
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [8192]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stdout_file.writeStreamingAll(io, text) catch {};
}

/// Formats and writes a message to stderr. Behaves like `print` but
/// targets the standard error stream.
pub fn eprint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [8192]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stderr_file.writeStreamingAll(io, text) catch {};
}

/// Reads a single line from stdin into `buffer`, stopping at a newline
/// character or EOF. Returns a slice of `buffer` containing the line
/// content (excluding the newline). The returned slice borrows from
/// `buffer` — no allocation is performed. If `buffer` fills up before
/// a newline is encountered, the available content is returned as-is.
pub fn readLine(io: std.Io, buffer: []u8) ![]u8 {
    var i: usize = 0;
    while (i < buffer.len) {
        var byte_buf: [1]u8 = undefined;
        const n = stdin_file.readStreaming(io, &.{&byte_buf}) catch |err| switch (err) {
            error.EndOfStream => return buffer[0..i],
            else => |e| return e,
        };
        if (n == 0) return buffer[0..i];
        if (byte_buf[0] == '\n') return buffer[0..i];
        buffer[i] = byte_buf[0];
        i += 1;
    }
    return buffer[0..i];
}

/// Reads a line from stdin and parses it as a `usize` menu index.
/// Returns `error.NoInput` on empty input and `error.InvalidChoice`
/// when the line cannot be parsed as a number.
pub fn readChoice(io: std.Io) !usize {
    var buf: [16]u8 = undefined;
    const line = readLine(io, &buf) catch return error.NoInput;
    if (line.len == 0) return error.NoInput;
    return std.fmt.parseInt(usize, line, 10) catch return error.InvalidChoice;
}

/// Displays a numbered list of `items` followed by `prompt`, reads the
/// user's choice, and returns the zero-based index. Returns `null` when
/// the input is missing or out of range.
pub fn pickFromList(io: std.Io, items: []const []const u8, comptime prompt: []const u8) ?usize {
    for (items, 1..) |name, i| {
        print(io, "  {d}. {s}\n", .{ i, name });
    }
    print(io, prompt, .{});
    const choice = readChoice(io) catch return null;
    if (choice < 1 or choice > items.len) return null;
    return choice - 1;
}

/// Like `pickFromList`, but pressing Enter on an empty line accepts
/// `default_idx` (zero-based) instead of returning `null`. The default
/// item is annotated with ` (default)` in the rendered list.
///
/// Returns `null` when the user explicitly enters an out-of-range value
/// or a non-numeric string. `default_idx` must be a valid index into
/// `items`; a debug build will panic when it is not.
pub fn pickFromListWithDefault(
    io: std.Io,
    items: []const []const u8,
    comptime prompt: []const u8,
    default_idx: usize,
) ?usize {
    std.debug.assert(items.len > 0);
    std.debug.assert(default_idx < items.len);

    for (items, 1..) |name, i| {
        if (i - 1 == default_idx) {
            print(io, "  {d}. {s} (default)\n", .{ i, name });
        } else {
            print(io, "  {d}. {s}\n", .{ i, name });
        }
    }
    print(io, prompt, .{});

    var buf: [16]u8 = undefined;
    const line = readLine(io, &buf) catch return null;
    if (line.len == 0) return default_idx;

    const choice = std.fmt.parseInt(usize, line, 10) catch return null;
    if (choice < 1 or choice > items.len) return null;
    return choice - 1;
}

/// Expands a leading `~` in `raw` to the value of the `HOME` environment
/// variable looked up in `env`. If `HOME` is not set, `~` is replaced
/// with an empty string. When `raw` does not start with `~`, a plain
/// heap-duplicate is returned. The caller owns the returned slice.
pub fn expandTilde(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, raw: []const u8) ![]u8 {
    if (raw.len > 0 and raw[0] == '~') {
        const home = env.get("HOME") orelse "";
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, raw[1..] });
    }
    return allocator.dupe(u8, raw);
}

/// Builds a single-line list label of the form `{indent}{name}`,
/// truncating with a trailing ellipsis (`…`) when the combined display
/// width would exceed `width`. The caller owns the returned slice.
///
/// This exists to keep TUI list rows exactly one line tall. List draw
/// loops advance by one row per item, so a label that soft-wrapped onto
/// a second line would be overdrawn by the following item and render as
/// a blank/missing row. Truncating here guarantees every label fits on
/// one line.
///
/// Truncation respects UTF-8 codepoint boundaries so a multi-byte
/// character is never split. The `name` portion is measured in
/// codepoints (one column each), which is exact for the ASCII-only
/// session names this is used with. The `indent` is assumed to be ASCII
/// and is measured by byte length; all current callers pass ASCII
/// indents (`"  > "`, `"    "`, or `""`). The ellipsis occupies one
/// column of the budget. When `width` leaves no room for any name
/// characters (i.e. it cannot hold the indent plus the ellipsis), the
/// indent alone is returned.
pub fn truncateLabel(
    allocator: std.mem.Allocator,
    indent: []const u8,
    name: []const u8,
    width: u16,
) ![]u8 {
    const w: usize = width;
    // Fast path: it already fits on one line.
    if (indent.len + name.len <= w) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ indent, name });
    }

    const ellipsis = "…"; // 3 UTF-8 bytes, 1 display column
    // Not enough room for the indent plus at least one name column and
    // the ellipsis: show the indent alone.
    if (w <= indent.len + 1) {
        return std.fmt.allocPrint(allocator, "{s}", .{indent});
    }
    const name_budget = w - indent.len - 1; // -1 column reserved for "…"

    // Take whole UTF-8 codepoints until we reach the column budget.
    var taken: usize = 0; // bytes consumed from `name`
    var cols: usize = 0; // display columns consumed (1 per codepoint)
    var view = std.unicode.Utf8View.initUnchecked(name);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (cols + 1 > name_budget) break;
        taken += cp.len;
        cols += 1;
    }

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ indent, name[0..taken], ellipsis });
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Test helper: counts display columns (codepoints) in a UTF-8 string.
fn countColumns(s: []const u8) usize {
    var cols: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |_| cols += 1;
    return cols;
}

test "expandTilde expands ~ to HOME" {
    const allocator = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, allocator);
    defer env.deinit();

    // HOME should be set in any normal environment; the test still
    // works if it isn't (expands to empty string).
    const home = env.get("HOME") orelse "";
    const result = try expandTilde(allocator, &env, "~/projects");
    defer allocator.free(result);

    const expected = try std.fmt.allocPrint(allocator, "{s}/projects", .{home});
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, result);
}

test "expandTilde returns path unchanged when no tilde" {
    const allocator = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, allocator);
    defer env.deinit();

    const result = try expandTilde(allocator, &env, "/absolute/path");
    defer allocator.free(result);
    try testing.expectEqualStrings("/absolute/path", result);
}

test "expandTilde handles bare tilde" {
    const allocator = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, allocator);
    defer env.deinit();

    const home = env.get("HOME") orelse "";
    const result = try expandTilde(allocator, &env, "~");
    defer allocator.free(result);
    try testing.expectEqualStrings(home, result);
}

test "expandTilde handles empty string" {
    const allocator = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, allocator);
    defer env.deinit();

    const result = try expandTilde(allocator, &env, "");
    defer allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "expandTilde handles relative path" {
    const allocator = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, allocator);
    defer env.deinit();

    const result = try expandTilde(allocator, &env, "relative/path");
    defer allocator.free(result);
    try testing.expectEqualStrings("relative/path", result);
}

test "truncateLabel leaves a label that fits unchanged" {
    const allocator = testing.allocator;
    const result = try truncateLabel(allocator, "  > ", "session", 64);
    defer allocator.free(result);
    try testing.expectEqualStrings("  > session", result);
}

test "truncateLabel keeps a label that fits exactly" {
    const allocator = testing.allocator;
    // indent (4) + name (6) == width (10): fits with no room to spare.
    const result = try truncateLabel(allocator, "  > ", "abcdef", 10);
    defer allocator.free(result);
    try testing.expectEqualStrings("  > abcdef", result);
}

test "truncateLabel truncates a too-long label with an ellipsis" {
    const allocator = testing.allocator;
    // This is the regression: a long session name must stay on one line.
    // width 10, indent 4 -> name budget 5 columns + ellipsis.
    const result = try truncateLabel(allocator, "  > ", "abcdefghij", 10);
    defer allocator.free(result);
    try testing.expectEqualStrings("  > abcde…", result);
    // The visible width never exceeds `width`: 4 indent + 5 name + 1
    // ellipsis column == 10.
    try testing.expectEqual(@as(usize, 10), countColumns(result));
}

test "truncateLabel returns indent only when width leaves no room for name" {
    const allocator = testing.allocator;
    // width 5, indent 4: only room for the indent plus one column, which
    // the ellipsis would consume, leaving nothing for the name.
    const result = try truncateLabel(allocator, "  > ", "anything", 5);
    defer allocator.free(result);
    try testing.expectEqualStrings("  > ", result);
}

test "truncateLabel never splits a multi-byte UTF-8 codepoint" {
    const allocator = testing.allocator;
    // "héllo" is 6 bytes (é is 2 bytes) but 5 columns. With an empty
    // indent and width 4, the name budget is 3 columns: "hél".
    const result = try truncateLabel(allocator, "", "héllo", 4);
    defer allocator.free(result);
    try testing.expectEqualStrings("hél…", result);
    // Result must be valid UTF-8 (no byte was split mid-codepoint).
    try testing.expect(std.unicode.utf8ValidateSlice(result));
}
