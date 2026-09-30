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
};
