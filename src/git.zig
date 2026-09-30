const std = @import("std");
const term = @import("term.zig");
const process = @import("process.zig");
const repo = @import("repo.zig");

/// Builds the fetch refspec `+refs/heads/<branch>:refs/remotes/origin/<branch>`
/// used to update the remote-tracking ref for `branch`. The refspec is
/// forced (`+`) so the remote-tracking ref always mirrors origin, even
/// after upstream history rewrites. The source side must be fully
/// qualified (`refs/heads/...`): when pruning is active (a user's
/// `fetch.prune=true` config, or `--prune` on the command line) an
/// unqualified source causes git to first delete the remote-tracking
/// ref and then fail to re-create it ("cannot lock ref"). The returned
/// slice is heap-allocated and must be freed by the caller.
fn fetchRefspec(allocator: std.mem.Allocator, branch: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "+refs/heads/{s}:refs/remotes/origin/{s}", .{ branch, branch });
}

/// Fetches a single `branch` from `origin` into the remote-tracking ref
/// `refs/remotes/origin/<branch>` in the bare repository at
/// `bare_repo_path`. It never touches the local `refs/heads/<branch>`
/// (which may be checked out in a worktree); see `fetchRefspec` for the
/// refspec details. A non-zero git exit code produces a warning on
/// stderr but is not treated as an error. Allocation or process-spawn
/// failures are propagated.
pub fn gitFetchBranch(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8, branch: []const u8) !void {
    const fetch_arg = try fetchRefspec(allocator, branch);
    defer allocator.free(fetch_arg);

    const result = try process.exec(allocator, io, &.{ "git", "fetch", "origin", fetch_arg }, bare_repo_path);
    process.freeExecResult(allocator, result);
    if (!result.exited_ok) term.eprint(io, "Warning: git fetch failed for branch '{s}'; the new worktree may be based on a stale ref\n", .{branch});
}

/// Same as `gitFetchBranch` but streams stderr to a `ProgressOutput` so
/// the TUI can display live fetch progress. Passes `--progress` to
/// force git to emit transfer progress even when stderr is piped.
pub fn gitFetchBranchWithProgress(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8, branch: []const u8, progress: *process.ProgressOutput) !void {
    const fetch_arg = try fetchRefspec(allocator, branch);
    defer allocator.free(fetch_arg);

    const result = try process.execWithProgress(allocator, io, &.{ "git", "fetch", "--progress", "origin", fetch_arg }, bare_repo_path, progress);
    process.freeExecResult(allocator, result);
    if (!result.exited_ok) {
        progress.appendLine("Warning: git fetch failed; the new worktree may be based on a stale ref");
    }
}

/// Returns `true` when a local branch named `branch_name` exists in the
/// bare repository at `bare_repo_path` (checked via
/// `git rev-parse --verify refs/heads/<branch_name>`). Returns `false`
/// on any allocation or process error.
pub fn gitBranchExists(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8, branch_name: []const u8) bool {
    const ref = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name}) catch return false;
    defer allocator.free(ref);
    const result = process.exec(allocator, io, &.{ "git", "rev-parse", "--verify", ref }, bare_repo_path) catch return false;
    defer process.freeExecResult(allocator, result);
    return result.exited_ok;
}

/// Returns the ref new worktrees should be based on for `base_branch`:
/// the remote-tracking ref `refs/remotes/origin/<base_branch>` when it
/// exists, otherwise the fully qualified local branch
/// `refs/heads/<base_branch>` as a fallback (e.g. a repository without
/// a reachable `origin`). The remote-tracking ref is preferred even
/// when the preceding fetch failed: it may then be a stale snapshot
/// from an earlier fetch, but in this tool's model the local branch is
/// frozen at clone time so the remote-tracking ref is still the better
/// base (the fetch warning tells the user the ref may be stale). Both
/// candidates are fully qualified so a tag named like the branch can
/// never shadow the intended ref. The returned slice is heap-allocated
/// and must be freed by the caller.
fn resolveWorktreeBaseRef(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8, base_branch: []const u8) ![]u8 {
    // Scoped so the errdefer cannot double-free once the fallback path
    // below has already released `remote_ref`.
    use_local_branch: {
        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{base_branch});
        errdefer allocator.free(remote_ref);

        const remote_ref_ok = blk: {
            const result = process.exec(allocator, io, &.{ "git", "rev-parse", "--verify", remote_ref }, bare_repo_path) catch break :blk false;
            defer process.freeExecResult(allocator, result);
            break :blk result.exited_ok;
        };

        if (remote_ref_ok) return remote_ref;
        allocator.free(remote_ref);
        break :use_local_branch;
    }

    return std.fmt.allocPrint(allocator, "refs/heads/{s}", .{base_branch});
}

/// Creates a new git worktree next to the bare repository under
/// `repo_root`. A fresh local branch `branch_name` is created from
/// origin's `base_branch`: the remote-tracking ref
/// `refs/remotes/origin/<base_branch>` is fetched first and used as the
/// base, so the worktree always starts from the latest origin state
/// regardless of where the local `base_branch` points. When the
/// remote-tracking ref does not exist (e.g. no reachable origin), the
/// local `base_branch` is used as a fallback. `bare_repo_name` is the
/// directory name of the bare repo (without the `.git` suffix) and
/// `worktree_name` becomes the new worktree directory name. Returns
/// `error.GitWorktreeCreationFailed` when the git command exits with a
/// non-zero status.
pub fn gitCreateWorktree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    bare_repo_name: []const u8,
    worktree_name: []const u8,
    branch_name: []const u8,
    base_branch: []const u8,
) !void {
    const bare_repo = try std.fmt.allocPrint(allocator, "{s}/{s}.git", .{ repo_root, bare_repo_name });
    defer allocator.free(bare_repo);

    const worktree_rel = try std.fmt.allocPrint(allocator, "../{s}", .{worktree_name});
    defer allocator.free(worktree_rel);

    try gitFetchBranch(allocator, io, bare_repo, base_branch);

    const base_ref = try resolveWorktreeBaseRef(allocator, io, bare_repo, base_branch);
    defer allocator.free(base_ref);

    const result = try process.exec(allocator, io, &.{
        "git", "worktree", "add", worktree_rel, "-b", branch_name, "--no-track", base_ref,
    }, bare_repo);
    defer process.freeExecResult(allocator, result);

    if (!result.exited_ok) {
        term.eprint(io, "Error creating worktree: {s}\n", .{result.stderr_data});
        return error.GitWorktreeCreationFailed;
    }

    term.print(io, "Created worktree '{s}' from '{s}'\n", .{ worktree_name, base_ref });
}

/// Same as `gitCreateWorktree` but streams progress output to a
/// `ProgressOutput` for live TUI feedback during the fetch and
/// worktree creation steps.
pub fn gitCreateWorktreeWithProgress(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    bare_repo_name: []const u8,
    worktree_name: []const u8,
    branch_name: []const u8,
    base_branch: []const u8,
    progress: *process.ProgressOutput,
) !void {
    const bare_repo = try std.fmt.allocPrint(allocator, "{s}/{s}.git", .{ repo_root, bare_repo_name });
    defer allocator.free(bare_repo);

    const worktree_rel = try std.fmt.allocPrint(allocator, "../{s}", .{worktree_name});
    defer allocator.free(worktree_rel);

    const fetch_msg = std.fmt.allocPrint(allocator, "Fetching branch '{s}' from origin...", .{base_branch}) catch null;
    if (fetch_msg) |m| {
        progress.appendLine(m);
        allocator.free(m);
    }
    try gitFetchBranchWithProgress(allocator, io, bare_repo, base_branch, progress);

    const base_ref = try resolveWorktreeBaseRef(allocator, io, bare_repo, base_branch);
    defer allocator.free(base_ref);

    const wt_msg = std.fmt.allocPrint(allocator, "Creating worktree '{s}' from '{s}'...", .{ worktree_name, base_ref }) catch null;
    if (wt_msg) |m| {
        progress.appendLine(m);
        allocator.free(m);
    }

    const result = try process.exec(allocator, io, &.{
        "git", "worktree", "add", worktree_rel, "-b", branch_name, "--no-track", base_ref,
    }, bare_repo);
    defer process.freeExecResult(allocator, result);

    if (!result.exited_ok) {
        progress.appendLine("Error creating worktree");
        return error.GitWorktreeCreationFailed;
    }

    progress.appendLine("Worktree created successfully");
}

/// Force-removes the git worktree for `worktree_name`.
/// Runs `git worktree remove ../<name> --force` from the bare repo
/// directory (`bare_repo_path`), mirroring the way worktrees are
/// created. When git does not recognise the directory as a worktree
/// (e.g. metadata was pruned), falls back to deleting the directory
/// tree directly. Returns `null` on success. On failure returns an
/// error message owned by the caller. Allocation or process-spawn
/// failures are propagated.
pub fn gitRemoveWorktree(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8, worktree_name: []const u8) !?[]u8 {
    const worktree_rel = try std.fmt.allocPrint(allocator, "../{s}", .{worktree_name});
    defer allocator.free(worktree_rel);
    const result = try process.exec(allocator, io, &.{ "git", "worktree", "remove", worktree_rel, "--force" }, bare_repo_path);
    defer process.freeExecResult(allocator, result);
    if (result.exited_ok) return null;

    // git worktree remove failed -- fall back to direct deletion.
    var repo_dir = std.Io.Dir.cwd().openDir(io, bare_repo_path, .{}) catch |err| {
        return try std.fmt.allocPrint(allocator, "Failed to open repo dir: {s}", .{@errorName(err)});
    };
    defer repo_dir.close(io);

    // Navigate to the session root -- assumes bare_repo_path is a
    // direct child, matching the layout from gitCreateWorktree.
    var parent_dir = repo_dir.openDir(io, "..", .{}) catch |err| {
        return try std.fmt.allocPrint(allocator, "Failed to open parent dir: {s}", .{@errorName(err)});
    };
    defer parent_dir.close(io);

    return removeWorktreeDirectoryFallback(allocator, io, parent_dir, worktree_name, bare_repo_path);
}

/// Deletes the worktree directory `worktree_name` under `parent_dir`,
/// but only if a session metadata file exists in the bare repo,
/// confirming it is a git-session worktree. Returns `null` on success.
/// On failure returns an error message owned by the caller.
fn removeWorktreeDirectoryFallback(allocator: std.mem.Allocator, io: std.Io, parent_dir: std.Io.Dir, worktree_name: []const u8, bare_repo_path: []const u8) !?[]u8 {
    const is_session_wt = repo.sessionFileExists(allocator, io, bare_repo_path, worktree_name) catch {
        return try allocator.dupe(u8, "Failed to check session file (allocation error)");
    };
    if (!is_session_wt) {
        return try allocator.dupe(u8, "Not a git-session worktree (no session file)");
    }

    term.eprint(io, "Warning: git worktree remove failed, removing directory directly\n", .{});
    parent_dir.deleteTree(io, worktree_name) catch |err| {
        return try std.fmt.allocPrint(allocator, "Failed to delete worktree directory: {s}", .{@errorName(err)});
    };

    // Clean up the session metadata file.
    repo.deleteSessionFile(allocator, io, bare_repo_path, worktree_name);

    return null;
}

/// Force-deletes a local branch (`git branch -D`) in the bare repository.
/// Returns an error if the git command exits with a non-zero status.
/// Allocation or process-spawn failures are also propagated.
pub fn gitDeleteBranch(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8, branch_name: []const u8) !void {
    const result = try process.exec(allocator, io, &.{ "git", "branch", "-D", branch_name }, bare_repo_path);
    process.freeExecResult(allocator, result);
    if (!result.exited_ok) return error.BranchDeleteFailed;
}

/// Returns the current branch name of the worktree at `worktree_path`
/// by running `git rev-parse --abbrev-ref HEAD`. The returned slice is
/// heap-allocated and must be freed by the caller. Returns `null` when
/// the branch cannot be determined (e.g. detached HEAD, missing
/// directory, or process failure).
pub fn gitWorktreeBranch(allocator: std.mem.Allocator, io: std.Io, worktree_path: []const u8) ?[]const u8 {
    const result = process.exec(allocator, io, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, worktree_path) catch return null;
    defer process.freeExecResult(allocator, result);
    if (!result.exited_ok) return null;

    // Trim trailing newline from stdout.
    var name = result.stdout_data;
    while (name.len > 0 and (name[name.len - 1] == '\n' or name[name.len - 1] == '\r')) {
        name = name[0 .. name.len - 1];
    }
    if (name.len == 0) return null;
    return allocator.dupe(u8, name) catch null;
}

/// Extracts a human-friendly repository name from a clone `url` by
/// taking the last path component and stripping a trailing `.git`
/// suffix. Works with both HTTPS (`https://…/repo.git`) and SSH
/// (`git@host:org/repo.git`) URLs. The returned slice is a sub-slice
/// of `url` — it does not allocate.
pub fn deriveRepoName(url: []const u8) []const u8 {
    var start: usize = 0;
    for (url, 0..) |c, i| {
        if (c == '/' or c == ':') start = i + 1;
    }
    var name = url[start..];
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    return name;
}

/// Returns the URL of the `origin` remote in the bare repository at
/// `bare_repo_path` by running `git remote get-url origin`. Returns
/// `null` when the directory is not a git repository, the remote is
/// missing, or the process otherwise fails. The returned slice is
/// heap-allocated and must be freed by the caller.
///
/// Used by the bare-repo recovery flow to backfill `origin_url` into the
/// centralized repo config the first time a repo is opened after the
/// upgrade that introduced this field.
pub fn gitGetOriginUrl(allocator: std.mem.Allocator, io: std.Io, bare_repo_path: []const u8) ?[]u8 {
    const result = process.exec(allocator, io, &.{ "git", "remote", "get-url", "origin" }, bare_repo_path) catch return null;
    defer process.freeExecResult(allocator, result);
    if (!result.exited_ok) return null;

    var url = result.stdout_data;
    while (url.len > 0 and (url[url.len - 1] == '\n' or url[url.len - 1] == '\r')) {
        url = url[0 .. url.len - 1];
    }
    if (url.len == 0) return null;
    return allocator.dupe(u8, url) catch null;
}

/// Same as `gitCloneForSession` but streams stderr (clone progress) to
/// a `ProgressOutput` so the TUI can display live output. Passes
/// `--progress` to force git to emit transfer progress even when stderr
/// is piped. Returns `error.GitCloneFailed` on a non-zero exit code.
pub fn gitCloneForSessionWithProgress(allocator: std.mem.Allocator, io: std.Io, url: []const u8, repo_dir: []const u8, bare_name: []const u8, progress: *process.ProgressOutput) !void {
    const clone_target = try std.fmt.allocPrint(allocator, "{s}.git", .{bare_name});
    defer allocator.free(clone_target);

    const clone_result = try process.execWithProgress(allocator, io, &.{ "git", "clone", "--progress", url, clone_target }, repo_dir, progress);
    defer process.freeExecResult(allocator, clone_result);

    if (!clone_result.exited_ok) {
        return error.GitCloneFailed;
    }

    const bare_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_dir, clone_target });
    defer allocator.free(bare_path);

    const cfg_result = try process.exec(allocator, io, &.{ "git", "config", "core.bare", "true" }, bare_path);
    process.freeExecResult(allocator, cfg_result);
}

/// Clones a remote repository at `url` into `repo_dir` as
/// `<bare_name>.git` and configures it as a bare repository
/// (`core.bare = true`) so that worktrees can be added alongside it.
/// Returns `error.GitCloneFailed` when `git clone` exits with a
/// non-zero status.
pub fn gitCloneForSession(allocator: std.mem.Allocator, io: std.Io, url: []const u8, repo_dir: []const u8, bare_name: []const u8) !void {
    const clone_target = try std.fmt.allocPrint(allocator, "{s}.git", .{bare_name});
    defer allocator.free(clone_target);

    term.print(io, "Cloning '{s}' ...\n", .{url});
    const clone_result = try process.exec(allocator, io, &.{ "git", "clone", url, clone_target }, repo_dir);
    defer process.freeExecResult(allocator, clone_result);

    if (!clone_result.exited_ok) {
        term.eprint(io, "Error cloning repository: {s}\n", .{clone_result.stderr_data});
        return error.GitCloneFailed;
    }

    const bare_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_dir, clone_target });
    defer allocator.free(bare_path);

    const cfg_result = try process.exec(allocator, io, &.{ "git", "config", "core.bare", "true" }, bare_path);
    process.freeExecResult(allocator, cfg_result);

    if (!cfg_result.exited_ok) term.eprint(io, "Warning: could not set core.bare=true\n", .{});

    term.print(io, "Repository cloned and configured.\n", .{});
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "deriveRepoName strips .git suffix from HTTPS URL" {
    try testing.expectEqualStrings("my-repo", deriveRepoName("https://github.com/user/my-repo.git"));
}

test "deriveRepoName handles HTTPS URL without .git suffix" {
    try testing.expectEqualStrings("my-repo", deriveRepoName("https://github.com/user/my-repo"));
}

test "deriveRepoName handles SSH URL" {
    try testing.expectEqualStrings("my-repo", deriveRepoName("git@github.com:user/my-repo.git"));
}

test "deriveRepoName handles SSH URL without .git suffix" {
    try testing.expectEqualStrings("my-repo", deriveRepoName("git@github.com:user/my-repo"));
}

test "deriveRepoName handles bare repo name" {
    try testing.expectEqualStrings("my-repo", deriveRepoName("my-repo"));
}

test "deriveRepoName handles bare repo name with .git" {
    try testing.expectEqualStrings("my-repo", deriveRepoName("my-repo.git"));
}

test "deriveRepoName handles deeply nested path" {
    try testing.expectEqualStrings("project", deriveRepoName("/home/user/repos/org/project.git"));
}

test "deriveRepoName handles URL with multiple path segments" {
    try testing.expectEqualStrings("repo", deriveRepoName("https://gitlab.com/group/subgroup/repo.git"));
}

// ---- gitGetOriginUrl tests ------------------------------------------------

test "gitGetOriginUrl returns the configured origin remote" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const repo_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(repo_dir);

    // Initialise an empty repository (non-bare is fine for `remote get-url`).
    const init_res = try process.exec(allocator, testing.io, &.{ "git", "init", "--quiet" }, repo_dir);
    process.freeExecResult(allocator, init_res);
    if (!init_res.exited_ok) return error.SkipZigTest; // git not available

    const url = "https://example.com/me/my-repo.git";
    const add_res = try process.exec(allocator, testing.io, &.{ "git", "remote", "add", "origin", url }, repo_dir);
    process.freeExecResult(allocator, add_res);
    try testing.expect(add_res.exited_ok);

    const got = gitGetOriginUrl(allocator, testing.io, repo_dir) orelse return error.TestUnexpectedResult;
    defer allocator.free(got);
    try testing.expectEqualStrings(url, got);
}

test "gitGetOriginUrl returns null when there is no origin remote" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const repo_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(repo_dir);

    const init_res = try process.exec(allocator, testing.io, &.{ "git", "init", "--quiet" }, repo_dir);
    process.freeExecResult(allocator, init_res);
    if (!init_res.exited_ok) return error.SkipZigTest;

    try testing.expect(gitGetOriginUrl(allocator, testing.io, repo_dir) == null);
}

// NOTE: We deliberately do *not* test the "directory is not a git repo at
// all" case here. Such a test would rely on `git` not walking upwards out
// of the tmp dir to find an enclosing repository, but `std.testing.tmpDir`
// places files under `.zig-cache/tmp/`, which is itself inside this
// project's git working tree. Setting `GIT_CEILING_DIRECTORIES` would be
// the correct fix, but `process.exec` does not accept extra env vars and
// adding that for a single test is not worth the API surface. The two
// tests above (with and without an `origin` remote inside an explicit
// `git init` directory) already exercise both code paths in
// `gitGetOriginUrl`.

test "removeWorktreeDirectoryFallback returns error when directory does not exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a bare repo dir for the session-file check
    try tmp.dir.createDir(testing.io, "bare.git", .default_dir);
    const bare_path = try tmp.dir.realPathFileAlloc(testing.io, "bare.git", testing.allocator);
    defer testing.allocator.free(bare_path);

    const result = try removeWorktreeDirectoryFallback(testing.allocator, testing.io, tmp.dir, "nonexistent", bare_path);
    defer if (result) |msg| testing.allocator.free(msg);
    try testing.expect(result != null);
}

test "removeWorktreeDirectoryFallback returns error when no session file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "my-worktree", .default_dir);
    try tmp.dir.createDir(testing.io, "bare.git", .default_dir);
    const bare_path = try tmp.dir.realPathFileAlloc(testing.io, "bare.git", testing.allocator);
    defer testing.allocator.free(bare_path);

    const result = try removeWorktreeDirectoryFallback(testing.allocator, testing.io, tmp.dir, "my-worktree", bare_path);
    defer if (result) |msg| testing.allocator.free(msg);
    try testing.expect(result != null);
    try testing.expectEqualStrings("Not a git-session worktree (no session file)", result.?);
}

// ---- gitCreateWorktree tests ------------------------------------------------

/// Initialises a git repository in `cwd` with `main` as the initial
/// branch, returning `error.SkipZigTest` when the command fails
/// (assumed to mean git is unavailable in the test environment). Used
/// as the first git invocation of a test; later git commands must go
/// through `execOk` so their failures fail the test instead of
/// silently skipping it.
fn gitInitOrSkip(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !void {
    const r = try process.exec(allocator, io, &.{ "git", "init", "--quiet", "-b", "main" }, cwd);
    process.freeExecResult(allocator, r);
    if (!r.exited_ok) return error.SkipZigTest;
}

/// Runs a git command in `cwd` and fails the test when it exits with a
/// non-zero status.
fn execOk(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) !void {
    const r = try process.exec(allocator, io, argv, cwd);
    process.freeExecResult(allocator, r);
    try testing.expect(r.exited_ok);
}

/// Returns the commit hash `ref` resolves to in the repository at
/// `repo_dir`. The returned slice is owned by the caller.
fn revParse(allocator: std.mem.Allocator, io: std.Io, repo_dir: []const u8, ref: []const u8) ![]u8 {
    const result = try process.exec(allocator, io, &.{ "git", "rev-parse", "--verify", ref }, repo_dir);
    defer process.freeExecResult(allocator, result);
    if (!result.exited_ok) return error.TestUnexpectedResult;
    const trimmed = std.mem.trimEnd(u8, result.stdout_data, "\r\n");
    return allocator.dupe(u8, trimmed);
}

test "gitCreateWorktree bases the worktree on origin after an upstream force-push" {
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    // Upstream: a working repo with one commit, cloned --bare so it can
    // be fetched from and pushed to.
    const work_dir = try std.fmt.allocPrint(allocator, "{s}/upstream-work", .{tmp_path});
    defer allocator.free(work_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, work_dir);
    try gitInitOrSkip(allocator, testing.io, work_dir);
    try execOk(allocator, testing.io, &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init", "--quiet" }, work_dir);
    try execOk(allocator, testing.io, &.{ "git", "clone", "--bare", "--quiet", "upstream-work", "upstream.git" }, tmp_path);

    const upstream_dir = try std.fmt.allocPrint(allocator, "{s}/upstream.git", .{tmp_path});
    defer allocator.free(upstream_dir);
    const url = try std.fmt.allocPrint(allocator, "file://{s}", .{upstream_dir});
    defer allocator.free(url);

    // Session layout: <tmp>/my-repo/my-repo.git (bare) + worktrees beside it.
    const repo_root = try std.fmt.allocPrint(allocator, "{s}/my-repo", .{tmp_path});
    defer allocator.free(repo_root);
    try std.Io.Dir.cwd().createDirPath(testing.io, repo_root);
    try gitCloneForSession(allocator, testing.io, url, repo_root, "my-repo");

    // Rewrite upstream history and force-push, so the session clone's
    // local `main` has *diverged* from origin. This is the regression
    // scenario: a non-forced fetch refuses the update and the worktree
    // would silently be based on the stale local branch. It also pins
    // the `+` in the fetch refspec — a non-forced refspec fails here.
    try execOk(allocator, testing.io, &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--amend", "--allow-empty", "-m", "rewritten", "--quiet" }, work_dir);
    try execOk(allocator, testing.io, &.{ "git", "push", "--force", "--quiet", upstream_dir, "main:main" }, work_dir);

    try gitCreateWorktree(allocator, testing.io, repo_root, "my-repo", "wt-feature", "feature/x", "main");

    // The worktree must point at the rewritten upstream tip, not the
    // stale local `main` recorded at clone time.
    const upstream_tip = try revParse(allocator, testing.io, upstream_dir, "main");
    defer allocator.free(upstream_tip);

    const worktree_dir = try std.fmt.allocPrint(allocator, "{s}/wt-feature", .{repo_root});
    defer allocator.free(worktree_dir);
    const worktree_head = try revParse(allocator, testing.io, worktree_dir, "HEAD");
    defer allocator.free(worktree_head);

    try testing.expectEqualStrings(upstream_tip, worktree_head);

    // Bonus check: the local `main` was left untouched (still the
    // pre-rewrite commit), proving the base came from the
    // remote-tracking ref rather than a fetch into the local branch.
    const bare_repo = try std.fmt.allocPrint(allocator, "{s}/my-repo.git", .{repo_root});
    defer allocator.free(bare_repo);
    const stale_local_main = try revParse(allocator, testing.io, bare_repo, "refs/heads/main");
    defer allocator.free(stale_local_main);
    try testing.expect(!std.mem.eql(u8, stale_local_main, worktree_head));
}

test "gitCreateWorktree falls back to the local branch when origin ref is missing" {
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    // A repository with a local `main` but no `origin` remote at all:
    // the fetch fails (warning only) and no refs/remotes/origin/main
    // exists, so the worktree must be created from the local branch.
    const repo_root = try std.fmt.allocPrint(allocator, "{s}/my-repo", .{tmp_path});
    defer allocator.free(repo_root);
    const bare_repo = try std.fmt.allocPrint(allocator, "{s}/my-repo.git", .{repo_root});
    defer allocator.free(bare_repo);
    try std.Io.Dir.cwd().createDirPath(testing.io, bare_repo);
    try gitInitOrSkip(allocator, testing.io, bare_repo);
    try execOk(allocator, testing.io, &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init", "--quiet" }, bare_repo);

    try gitCreateWorktree(allocator, testing.io, repo_root, "my-repo", "wt-feature", "feature/x", "main");

    const local_main = try revParse(allocator, testing.io, bare_repo, "refs/heads/main");
    defer allocator.free(local_main);

    const worktree_dir = try std.fmt.allocPrint(allocator, "{s}/wt-feature", .{repo_root});
    defer allocator.free(worktree_dir);
    const worktree_head = try revParse(allocator, testing.io, worktree_dir, "HEAD");
    defer allocator.free(worktree_head);

    try testing.expectEqualStrings(local_main, worktree_head);
}

test "removeWorktreeDirectoryFallback deletes directory with session file in bare repo" {
    // Suppress the warning printed to stderr during the fallback path.
    term.setQuiet(true);
    defer term.setQuiet(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "my-worktree", .default_dir);
    try tmp.dir.createDir(testing.io, "bare.git", .default_dir);
    const bare_path = try tmp.dir.realPathFileAlloc(testing.io, "bare.git", testing.allocator);
    defer testing.allocator.free(bare_path);

    // Create session file in the bare repo
    try repo.saveSessionFile(testing.allocator, testing.io, "main", "feature/test", bare_path, "my-worktree");

    const result = try removeWorktreeDirectoryFallback(testing.allocator, testing.io, tmp.dir, "my-worktree", bare_path);
    defer if (result) |msg| testing.allocator.free(msg);
    try testing.expect(result == null);
    // Verify the directory was actually deleted.
    tmp.dir.access(testing.io, "my-worktree", .{}) catch {
        return; // expected -- directory is gone
    };
    return error.TestUnexpectedResult; // directory still exists
}
