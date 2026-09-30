const std = @import("std");

// Session-name validation for characters that are safe to use as both a
// git branch component and a filesystem directory name.
//
// The session name typed by the user becomes:
//   1. A directory under the repo root (`{root}/{name}/`)
//   2. Part of a git branch ref (`refs/heads/[prefix/]{name}`)
//   3. Part of a tmux session name
//
// Rather than maintaining a blocklist of problematic characters we use a
// strict **allowlist**: only ASCII letters, digits, hyphen, and
// underscore are accepted.  Everything else — including dots, spaces,
// commas, brackets, unicode, and control characters — is rejected at
// the keystroke level so the user can never type them.
//
// A second level of validation (`validateBranchName`) catches
// contextual rules that apply to the name as a whole (e.g. a leading
// dash would be misinterpreted as a CLI flag by git).

/// Maximum allowed length for a session name.  This limit accounts for
/// two constraints: the fixed-size `branch_name_buf` (512 bytes) in
/// `executeCreateSession` where the prefix, slash, and name must all
/// fit, and the 255-byte filesystem component limit on Windows.  200
/// is a conservative cap that satisfies both while leaving room for
/// the prefix.
pub const max_name_length: usize = 200;

/// Hint shown to the user when a rejected character is typed.  Defined
/// here so that all validation-related text lives in one place.
pub const rejected_char_hint = "Only letters, digits, '-' and '_' are allowed";

/// Returns `true` when the byte `c` is allowed in a session / branch
/// name.  Only ASCII alphanumerics, hyphen (`-`), and underscore (`_`)
/// pass.
pub fn isAllowedBranchChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => true,
        else => false,
    };
}

/// Reasons a complete session name can be rejected even when every
/// individual character passes `isAllowedBranchChar`.
pub const ValidationError = enum {
    empty,
    starts_with_dash,
    too_long,
};

/// Human-readable description for each validation error.
pub fn validationMessage(err: ValidationError) []const u8 {
    return switch (err) {
        .empty => "Name cannot be empty",
        .starts_with_dash => "Name cannot start with '-'",
        .too_long => "Name is too long (max 200 characters)",
    };
}

/// Validates a complete session name.  Returns `null` when the name is
/// acceptable, or a `ValidationError` describing the first rule
/// violation found.
pub fn validateBranchName(name: []const u8) ?ValidationError {
    if (name.len == 0) return .empty;

    // A leading dash would be misinterpreted as a git flag.
    if (name[0] == '-') return .starts_with_dash;

    // Guard against filesystem component limits and the fixed-size
    // branch_name_buf in executeCreateSession.
    if (name.len > max_name_length) return .too_long;

    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// ── isAllowedBranchChar ──────────────────────────────────────────────────

test "allows lowercase letters" {
    try testing.expect(isAllowedBranchChar('a'));
    try testing.expect(isAllowedBranchChar('z'));
    try testing.expect(isAllowedBranchChar('m'));
}

test "allows uppercase letters" {
    try testing.expect(isAllowedBranchChar('A'));
    try testing.expect(isAllowedBranchChar('Z'));
}

test "allows digits" {
    try testing.expect(isAllowedBranchChar('0'));
    try testing.expect(isAllowedBranchChar('9'));
    try testing.expect(isAllowedBranchChar('5'));
}

test "allows hyphen and underscore" {
    try testing.expect(isAllowedBranchChar('-'));
    try testing.expect(isAllowedBranchChar('_'));
}

test "rejects dot" {
    try testing.expect(!isAllowedBranchChar('.'));
}

test "rejects space" {
    try testing.expect(!isAllowedBranchChar(' '));
}

test "rejects common special characters" {
    const bad = "~^:\\?*[]@{}(),;'\"!#$%&+=|<>/`";
    for (bad) |c| {
        try testing.expect(!isAllowedBranchChar(c));
    }
}

test "rejects control characters and DEL" {
    try testing.expect(!isAllowedBranchChar(0x00));
    try testing.expect(!isAllowedBranchChar(0x01));
    try testing.expect(!isAllowedBranchChar(0x1F));
    try testing.expect(!isAllowedBranchChar(0x7F));
}

test "rejects high-ASCII bytes (non-ASCII / latin)" {
    try testing.expect(!isAllowedBranchChar(0x80));
    try testing.expect(!isAllowedBranchChar(0xC3)); // first byte of UTF-8 é
    try testing.expect(!isAllowedBranchChar(0xFF));
}

// ── validateBranchName ───────────────────────────────────────────────────

test "validateBranchName accepts valid names" {
    try testing.expect(validateBranchName("my-feature") == null);
    try testing.expect(validateBranchName("fix-123") == null);
    try testing.expect(validateBranchName("add_login") == null);
    try testing.expect(validateBranchName("ABC") == null);
    try testing.expect(validateBranchName("a") == null);
    try testing.expect(validateBranchName("_") == null);
    try testing.expect(validateBranchName("some-long-branch-name-42") == null);
}

test "validateBranchName rejects empty" {
    try testing.expect(validateBranchName("") == .empty);
}

test "validateBranchName rejects leading dash" {
    try testing.expect(validateBranchName("-flag") == .starts_with_dash);
    try testing.expect(validateBranchName("-") == .starts_with_dash);
}

test "validateBranchName rejects names exceeding max length" {
    const long_name = "a" ** (max_name_length + 1);
    try testing.expect(validateBranchName(long_name) == .too_long);
}

test "validateBranchName accepts names at max length" {
    const exact_name = "a" ** max_name_length;
    try testing.expect(validateBranchName(exact_name) == null);
}
