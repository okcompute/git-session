const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const config = @import("config.zig");
const term = @import("term.zig");
const repo = @import("repo.zig");
const git = @import("git.zig");
const tmux = @import("tmux.zig");
const process = @import("process.zig");
const usage = @import("usage.zig");
const branch_validate = @import("git_branch_validate.zig");
const cli_args_mod = @import("cli_args.zig");

pub const CliArgs = cli_args_mod.CliArgs;

// ── Color palette (OpenCode-inspired dark theme) ─────────────────────────

/// Shorthand alias for the vaxis colour type.
const Color = vaxis.Cell.Color;

/// Tokyo Night-inspired colour constants used throughout the TUI.
const colors = struct {
    const bg = Color{ .rgb = .{ 0x1a, 0x1b, 0x26 } }; // dark background
    const fg = Color{ .rgb = .{ 0xc0, 0xca, 0xf5 } }; // light text
    const dim = Color{ .rgb = .{ 0x56, 0x5f, 0x89 } }; // muted text
    const accent = Color{ .rgb = .{ 0x7a, 0xa2, 0xf7 } }; // blue accent
    const green = Color{ .rgb = .{ 0x9e, 0xce, 0x6a } }; // success green
    const red = Color{ .rgb = .{ 0xf7, 0x76, 0x8e } }; // danger red
    const yellow = Color{ .rgb = .{ 0xe0, 0xaf, 0x68 } }; // warning yellow
    const border = Color{ .rgb = .{ 0x3b, 0x40, 0x61 } }; // subtle border
    const selection = Color{ .rgb = .{ 0x28, 0x2d, 0x44 } }; // selected item bg
};

/// Pre-built cell styles composed from the colour palette.
const style = struct {
    const title = vaxis.Cell.Style{ .fg = colors.accent, .bold = true };
    const normal = vaxis.Cell.Style{ .fg = colors.fg };
    const dimmed = vaxis.Cell.Style{ .fg = colors.dim };
    const selected = vaxis.Cell.Style{ .fg = colors.accent, .bold = true };
    const danger = vaxis.Cell.Style{ .fg = colors.red, .bold = true };
    const success = vaxis.Cell.Style{ .fg = colors.green };
    const border_style = vaxis.Cell.Style{ .fg = colors.border };
    const input_label = vaxis.Cell.Style{ .fg = colors.yellow, .bold = true };
};

// ── Application state ────────────────────────────────────────────────────

/// Identifies which screen the TUI is currently displaying.
pub const Screen = enum {
    /// Repository list with add / quit options.
    main_menu,
    /// Actions for a selected repository (create / remove / fix / back).
    repo_menu,
    /// Multi-step session creation wizard.
    create_session,
    /// Worktree list for session removal.
    remove_session,
    /// Worktree list for session fix / reattach.
    fix_session,
    /// Multi-step "add a new repository" wizard.
    add_repo,
    /// Confirmation prompt for removing a whole repository.
    remove_repo_confirm,
    /// Generic yes/no confirmation prompt.
    confirmation,
    /// Static message dismissed by any key press.
    message,
    /// Post-operation "Attach to tmux session?" prompt.
    attach_confirm,
    /// Spinner screen shown while a background operation runs.
    working,
};

/// Identifies the currently active text input field (used to route
/// keyboard events to the correct `vxfw.TextField`).
pub const InputField = enum {
    session_name,
    base_branch,
    branch_prefix,
    clone_url,
    repo_name,
    default_branch,
    branch_prefixes,
    root_folder,
    confirm,
};

/// Central application state for the TUI. Implements the `vxfw.Widget`
/// interface so it can be handed directly to `vxfw.App.run`. Owns all
/// screen state, text fields, background worker handles, and the spinner.
pub const TuiApp = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    app_config: config.AppConfig,
    screen: Screen = .main_menu,

    // Repo list state
    repo_entries: std.ArrayList(repo.RepoEntry) = .empty,
    selected_repo_idx: u32 = 0,

    // Currently open repo
    selected_repo: ?repo.SelectedRepo = null,

    // Worktree list for remove/fix
    worktrees: std.ArrayList([]u8) = .empty,
    selected_worktree_idx: u32 = 0,

    // Sub-menu cursor
    submenu_cursor: u32 = 0,

    // Input fields
    active_input: InputField = .session_name,
    input_session_name: vxfw.TextField = undefined,
    input_general: vxfw.TextField = undefined,

    // Create session flow state
    create_base_branch: []const u8 = "",
    create_prefix: []const u8 = "",
    create_step: u8 = 0, // 0=name, 1=base_branch, 2=prefix, 3=confirm
    input_hint: ?[]const u8 = null, // transient validation hint shown below the input field

    // Add repository flow state
    // Steps: 0=pick root, 0.5(=6)=new root input, 1=url, 2=name, 3=branch, 4=prefixes, 5=confirm
    add_repo_step: u8 = 0,
    add_repo_root: []const u8 = "", // selected root (points into app_config.roots or owned)
    add_repo_root_owned: ?[]u8 = null, // non-null if user typed a new root
    add_repo_url: vxfw.TextField = undefined,
    add_repo_name: vxfw.TextField = undefined,
    add_repo_branch: vxfw.TextField = undefined,
    add_repo_prefixes: vxfw.TextField = undefined,
    add_repo_new_root: vxfw.TextField = undefined,
    add_repo_derived_name: []const u8 = "", // derived from URL, arena-allocated

    // Status message
    status_message: []const u8 = "",
    status_is_error: bool = false,
    quit_on_dismiss: bool = false, // when true, dismissing the message quits the app

    // Pending tmux session name for "attach?" prompt
    pending_tmux_name: ?[]u8 = null,

    // Spinner for async operations (initialised in `init` because it
    // needs the runtime `std.Io` handle for its tick scheduling)
    spinner: vxfw.Spinner,
    working_message: []const u8 = "",
    worker_thread: ?std.Thread = null,
    worker_done: std.atomic.Value(bool) = .{ .raw = false },
    worker_error: ?[]const u8 = null, // error message from worker, or null on success
    worker_next_screen: Screen = .message, // screen to go to after work completes
    worker_progress: ?*process.ProgressOutput = null, // live output from worker

    // Snapshotted text field values for the background worker thread.
    // Populated on the main thread before spawning the worker so that
    // the worker never touches the TextField gap buffers.
    worker_url: ?[]const u8 = null,
    worker_repo_name: ?[]const u8 = null,
    worker_branch: ?[]const u8 = null,
    worker_prefixes: ?[]const u8 = null,
    worker_root: ?[]const u8 = null,

    // Snapshotted values for the create-session background worker.
    worker_session_name: ?[]const u8 = null,
    worker_base_branch: ?[]const u8 = null,
    worker_prefix: ?[]const u8 = null,
    worker_bare_repo_name: ?[]const u8 = null,
    worker_repo_root: ?[]const u8 = null,
    worker_sr_name: ?[]const u8 = null,
    worker_windows: []const repo.WindowConfig = &.{},

    // Snapshotted values for the remove-session background worker.
    worker_rm_session_name: ?[]const u8 = null,
    worker_rm_branch_name: ?[]const u8 = null,
    worker_rm_bare_repo_path: ?[]const u8 = null,
    worker_rm_tmux_name: ?[]const u8 = null,

    // Remove-repository flow state. The target is captured on the main
    // thread when the user presses `D` so the confirmation screen knows
    // exactly which repo will be removed even if the list later shifts.
    remove_repo_name: ?[]u8 = null,
    remove_repo_root: ?[]u8 = null,
    remove_repo_session_count: usize = 0,

    // Snapshotted values for the remove-repository background worker.
    worker_rr_repo_name: ?[]const u8 = null,
    worker_rr_root: ?[]const u8 = null,
    worker_rr_repo_root: ?[]const u8 = null,
    worker_rr_sessions: ?[][]u8 = null,

    // Should the TUI exit and attach to tmux?
    exit_and_attach: ?[]const u8 = null,
    should_quit: bool = false,

    // Tmux client tracking: used to detect when the user has switched
    // away from the session where git-session is running, so we can
    // show a popup/notification on their current client instead.
    tmux_client_name: ?[]const u8 = null,
    tmux_original_session: ?[]const u8 = null,

    /// Heap-allocates a `TuiApp`, initialises all text fields and loads
    /// the repository list from the configured root folders.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, app_config: config.AppConfig) !*TuiApp {
        const self = try allocator.create(TuiApp);
        // Capture tmux client identity first, then query the session
        // through the same code path used by hasUserSwitchedAway() to
        // guarantee identical string formatting.
        const client_name = tmux.tmuxGetClientName(allocator, io, env);
        const original_session = if (client_name) |cn|
            tmux.tmuxGetClientSession(allocator, io, cn)
        else
            tmux.tmuxGetCurrentSession(allocator, io, env);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .app_config = app_config,
            .spinner = .{ .io = io, .style = style.title },
            .input_session_name = vxfw.TextField.init(allocator),
            .input_general = vxfw.TextField.init(allocator),
            .add_repo_url = vxfw.TextField.init(allocator),
            .add_repo_name = vxfw.TextField.init(allocator),
            .add_repo_branch = vxfw.TextField.init(allocator),
            .add_repo_prefixes = vxfw.TextField.init(allocator),
            .add_repo_new_root = vxfw.TextField.init(allocator),
            .tmux_client_name = client_name,
            .tmux_original_session = original_session,
        };
        try self.refreshRepoList();
        return self;
    }

    /// Releases all owned resources: text fields, worktree lists, repo
    /// entries, background thread handle, progress output, and the
    /// heap-allocated `TuiApp` itself.
    pub fn deinit(self: *TuiApp) void {
        self.input_session_name.deinit();
        self.input_general.deinit();
        self.add_repo_url.deinit();
        self.add_repo_name.deinit();
        self.add_repo_branch.deinit();
        self.add_repo_prefixes.deinit();
        self.add_repo_new_root.deinit();
        if (self.add_repo_root_owned) |r| self.allocator.free(r);
        if (self.remove_repo_name) |n| self.allocator.free(n);
        if (self.remove_repo_root) |r| self.allocator.free(r);
        self.freeWorktrees();
        self.freeRepoEntries();
        if (self.selected_repo) |*sr| {
            repo.freeSelectedRepo(self.allocator, sr);
        }
        if (self.pending_tmux_name) |name| {
            self.allocator.free(name);
        }
        if (self.tmux_client_name) |name| {
            self.allocator.free(name);
        }
        if (self.tmux_original_session) |name| {
            self.allocator.free(name);
        }
        if (self.worker_thread) |t| t.join();
        if (self.worker_error) |e| self.allocator.free(e);
        self.freeWorkerSnapshots();
        if (self.worker_progress) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.allocator.destroy(self);
    }

    /// Frees all heap-allocated repo entry names and resets the list.
    fn freeRepoEntries(self: *TuiApp) void {
        for (self.repo_entries.items) |e| self.allocator.free(e.name);
        self.repo_entries.deinit(self.allocator);
        self.repo_entries = .empty;
    }

    /// Frees all heap-allocated worktree names and resets the list.
    fn freeWorktrees(self: *TuiApp) void {
        for (self.worktrees.items) |name| self.allocator.free(name);
        self.worktrees.deinit(self.allocator);
        self.worktrees = .empty;
    }

    /// Reloads the repository list from all configured root folders,
    /// sorted by usage count so that most-used repositories appear first.
    fn refreshRepoList(self: *TuiApp) !void {
        self.freeRepoEntries();
        // Pass `quiet=false`: the main menu is the primary place where
        // users discover that an unreachable centrally-configured repo
        // exists. Surfacing the warning here is the whole point of the
        // strict-match behaviour.
        self.repo_entries = try repo.listAllRepositories(self.allocator, self.io, self.env, self.app_config.roots.items, false);

        var usage_data = usage.loadUsageData(self.allocator, self.io, self.env);
        defer usage.freeUsageData(self.allocator, &usage_data);
        usage.sortByUsage(&usage_data, self.repo_entries.items);

        self.selected_repo_idx = 0;
    }

    /// Reloads the worktree list for the currently selected repository.
    fn refreshWorktrees(self: *TuiApp) !void {
        self.freeWorktrees();
        if (self.selected_repo) |sr| {
            self.worktrees = try repo.listWorktrees(self.allocator, self.io, sr.root);
            self.selected_worktree_idx = 0;
        }
    }

    /// Opens a repository by loading its config and transitions to the
    /// repo sub-menu screen. Records the selection in the usage tracker
    /// so that frequently used repositories appear first in the list.
    fn openRepo(self: *TuiApp, entry: repo.RepoEntry) !void {
        if (self.selected_repo) |*sr| {
            repo.freeSelectedRepo(self.allocator, sr);
            self.selected_repo = null;
        }
        self.selected_repo = (try repo.openRepo(self.allocator, self.io, self.env, entry.root, entry.name)) orelse return;
        usage.recordUsage(self.allocator, self.io, self.env, entry.name);
        self.submenu_cursor = 0;
        self.screen = .repo_menu;
    }

    /// Frees any heap-allocated worker snapshot strings.
    fn freeWorkerSnapshots(self: *TuiApp) void {
        if (self.worker_url) |s| self.allocator.free(s);
        if (self.worker_repo_name) |s| self.allocator.free(s);
        if (self.worker_branch) |s| self.allocator.free(s);
        if (self.worker_prefixes) |s| self.allocator.free(s);
        if (self.worker_root) |s| self.allocator.free(s);
        self.worker_url = null;
        self.worker_repo_name = null;
        self.worker_branch = null;
        self.worker_prefixes = null;
        self.worker_root = null;

        if (self.worker_session_name) |s| self.allocator.free(s);
        if (self.worker_base_branch) |s| self.allocator.free(s);
        if (self.worker_prefix) |s| self.allocator.free(s);
        if (self.worker_bare_repo_name) |s| self.allocator.free(s);
        if (self.worker_repo_root) |s| self.allocator.free(s);
        if (self.worker_sr_name) |s| self.allocator.free(s);
        self.worker_session_name = null;
        self.worker_base_branch = null;
        self.worker_prefix = null;
        self.worker_bare_repo_name = null;
        self.worker_repo_root = null;
        self.worker_sr_name = null;
        self.worker_windows = &.{};

        if (self.worker_rm_session_name) |s| self.allocator.free(s);
        if (self.worker_rm_branch_name) |s| self.allocator.free(s);
        if (self.worker_rm_bare_repo_path) |s| self.allocator.free(s);
        if (self.worker_rm_tmux_name) |s| self.allocator.free(s);
        self.worker_rm_session_name = null;
        self.worker_rm_branch_name = null;
        self.worker_rm_bare_repo_path = null;
        self.worker_rm_tmux_name = null;

        if (self.worker_rr_repo_name) |s| self.allocator.free(s);
        if (self.worker_rr_root) |s| self.allocator.free(s);
        if (self.worker_rr_repo_root) |s| self.allocator.free(s);
        if (self.worker_rr_sessions) |sessions| {
            for (sessions) |s| self.allocator.free(s);
            self.allocator.free(sessions);
        }
        self.worker_rr_repo_name = null;
        self.worker_rr_root = null;
        self.worker_rr_repo_root = null;
        self.worker_rr_sessions = null;
    }

    /// Returns `true` when we are running inside tmux and the user's
    /// client has switched to a different session than the one where
    /// git-session originally started. In that case, the TUI is not
    /// visible and we should use a tmux popup/notification instead.
    fn hasUserSwitchedAway(self: *TuiApp) bool {
        const client = self.tmux_client_name orelse return false;
        const original = self.tmux_original_session orelse return false;
        const current = tmux.tmuxGetClientSession(self.allocator, self.io, client) orelse return false;
        defer self.allocator.free(current);
        return !std.mem.eql(u8, current, original);
    }

    /// Sets the status message and clears `quit_on_dismiss`.
    fn setMessage(self: *TuiApp, msg: []const u8, is_error: bool) void {
        self.status_message = msg;
        self.status_is_error = is_error;
        self.quit_on_dismiss = false;
    }

    /// Milliseconds between spinner animation frames (12 fps).
    const tick_interval: u32 = std.time.ms_per_s / 12;

    /// Starts a background operation: shows the `.working` screen with
    /// a spinner, spawns `work_fn` on a new thread, and schedules tick
    /// events to poll for completion. On success the TUI transitions to
    /// `next_screen`; on failure it shows the error as a message.
    fn startWorking(self: *TuiApp, ctx: *vxfw.EventContext, message: []const u8, next_screen: Screen, work_fn: fn (*TuiApp) void) void {
        self.working_message = message;
        self.worker_next_screen = next_screen;
        self.worker_done.store(false, .release);
        if (self.worker_error) |e| {
            self.allocator.free(e);
            self.worker_error = null;
        }
        self.screen = .working;
        self.spinner.frame = 0;

        // Schedule ticks on our own widget so we control the redraw loop
        ctx.tick(tick_interval, self.widget()) catch {};

        // Spawn worker thread
        self.worker_thread = std.Thread.spawn(.{}, work_fn, .{self}) catch {
            self.worker_done.store(true, .release);
            self.worker_error = self.allocator.dupe(u8, "Failed to start background thread") catch null;
            return;
        };
    }

    /// Store a tmux session name for the "Attach?" prompt.
    /// Copies the name so the caller can free the original.
    fn setPendingAttach(self: *TuiApp, tmux_name: []const u8) void {
        if (self.pending_tmux_name) |old| {
            self.allocator.free(old);
        }
        self.pending_tmux_name = self.allocator.dupe(u8, tmux_name) catch null;
    }

    // ── Widget interface ─────────────────────────────────────────────

    /// Returns the type-erased `vxfw.Widget` backed by this TuiApp.
    pub fn widget(self: *TuiApp) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    /// vxfw type-erased event handler trampoline.
    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *TuiApp = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    /// vxfw type-erased draw trampoline.
    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *TuiApp = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    // ── Event handling ───────────────────────────────────────────────

    /// Top-level event dispatcher. Handles tick events for the spinner,
    /// Ctrl+C for global quit, and delegates key presses to the
    /// screen-specific handler.
    fn handleEvent(self: *TuiApp, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .tick => {
                if (self.screen != .working) return;

                // Check if background work is done
                if (self.worker_done.load(.acquire)) {
                    // Join the thread
                    if (self.worker_thread) |t| {
                        t.join();
                        self.worker_thread = null;
                    }
                    // Transition based on result
                    if (self.worker_error) |err_msg| {
                        self.setMessage(err_msg, true);
                        self.screen = .message;
                    } else {
                        // Refresh repo list on the main thread after successful
                        // add-repo (safe here since the worker has joined).
                        self.refreshRepoList() catch {};

                        // If the next screen would be attach_confirm and the
                        // user has switched to a different tmux session while
                        // the operation was running, show a tmux popup instead
                        // of the TUI prompt (which they can't see).
                        if (self.worker_next_screen == .attach_confirm and self.hasUserSwitchedAway()) {
                            if (self.pending_tmux_name) |tmux_name| {
                                tmux.tmuxDisplayPopup(self.allocator, self.io, tmux_name, self.tmux_client_name);
                            }
                            ctx.quit = true;
                            ctx.redraw = true;
                            return;
                        }

                        // If this was a remove-session and the user has
                        // switched away, show a tmux notification and quit
                        // instead of the (invisible) TUI message screen.
                        if (self.quit_on_dismiss and self.hasUserSwitchedAway()) {
                            self.notifyRemovedAndQuit(ctx);
                            ctx.redraw = true;
                            return;
                        }

                        self.screen = self.worker_next_screen;
                    }
                    // Use ctx.redraw instead of ctx.consumeAndRedraw()
                    // here. The vxfw event loop processes timers before
                    // draining queued key events, and consumeAndRedraw
                    // sets ctx.consume_event = true which leaks into
                    // the first key event, silently swallowing it.
                    ctx.redraw = true;
                    return;
                }

                // Advance spinner frame
                self.spinner.frame +%= 1;
                if (self.spinner.frame >= 8) self.spinner.frame = 0;

                // Schedule next tick and redraw
                ctx.tick(tick_interval, self.widget()) catch {};
                ctx.redraw = true;
                return;
            },
            .key_press => |key| {
                // Global: Ctrl+C to quit
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return ctx.consumeAndRedraw();
                }

                switch (self.screen) {
                    .main_menu => try self.handleMainMenuKey(ctx, key),
                    .repo_menu => try self.handleRepoMenuKey(ctx, key),
                    .create_session => try self.handleCreateSessionKey(ctx, key),
                    .remove_session => try self.handleRemoveSessionKey(ctx, key),
                    .fix_session => try self.handleFixSessionKey(ctx, key),
                    .add_repo => try self.handleAddRepoKey(ctx, key),
                    .remove_repo_confirm => try self.handleRemoveRepoConfirmKey(ctx, key),
                    .working => {}, // ignore keypresses while working
                    .attach_confirm => {
                        if (key.matches('y', .{}) or key.matches(vaxis.Key.enter, .{})) {
                            // Attach to tmux session, then quit
                            if (self.pending_tmux_name) |tmux_name| {
                                tmux.tmuxAttachOrSwitch(self.allocator, self.io, self.env, tmux_name) catch {};
                            }
                            ctx.quit = true;
                            return ctx.consumeAndRedraw();
                        }
                        if (key.matches('n', .{}) or key.matches(vaxis.Key.escape, .{})) {
                            // Don't attach, just quit
                            ctx.quit = true;
                            return ctx.consumeAndRedraw();
                        }
                    },
                    .message => {
                        // Any key dismisses the message
                        if (self.quit_on_dismiss) {
                            ctx.quit = true;
                        } else {
                            self.screen = if (self.selected_repo != null) .repo_menu else .main_menu;
                        }
                        return ctx.consumeAndRedraw();
                    },
                    else => {},
                }
            },
            .init => return ctx.consumeAndRedraw(),
            else => {},
        }
    }

    /// Key handler for the main menu: j/k navigate, enter opens a repo,
    /// `a` starts the add-repo wizard, `q` quits.
    fn handleMainMenuKey(self: *TuiApp, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const repo_count: u32 = @intCast(self.repo_entries.items.len);
        const add_idx: u32 = repo_count; // "Add repository" option
        const quit_idx: u32 = repo_count + 1; // "Quit" option
        const total_items: u32 = quit_idx + 1;

        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.selected_repo_idx < total_items - 1) self.selected_repo_idx += 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.selected_repo_idx > 0) self.selected_repo_idx -= 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{}) or key.matches('l', .{})) {
            if (self.selected_repo_idx < repo_count) {
                // Open repository
                const entry = self.repo_entries.items[self.selected_repo_idx];
                self.openRepo(entry) catch {
                    self.setMessage("Failed to open repository", true);
                    self.screen = .message;
                };
            } else if (self.selected_repo_idx == add_idx) {
                // Add repository
                self.startAddRepo();
                self.screen = .add_repo;
            } else {
                // Quit
                ctx.quit = true;
            }
            return ctx.consumeAndRedraw();
        }
        if (key.matches('a', .{})) {
            self.startAddRepo();
            self.screen = .add_repo;
            return ctx.consumeAndRedraw();
        }
        // Capital D removes the currently highlighted repository. The
        // shift requirement makes accidental keypresses unlikely for
        // an irreversible operation. The "Add" and "Quit" rows below
        // the repo list are not valid targets.
        if (key.matches('D', .{})) {
            if (self.selected_repo_idx < repo_count) {
                const entry = self.repo_entries.items[self.selected_repo_idx];
                self.startRemoveRepo(entry) catch {
                    self.setMessage("Failed to prepare repository removal", true);
                    self.screen = .message;
                };
                return ctx.consumeAndRedraw();
            }
        }
        if (key.matches('q', .{})) {
            ctx.quit = true;
            return ctx.consumeAndRedraw();
        }
    }

    /// Captures the target repository for removal and transitions to
    /// the confirmation screen. Counts the existing sessions on the
    /// main thread so they can be displayed before the user commits.
    fn startRemoveRepo(self: *TuiApp, entry: repo.RepoEntry) !void {
        if (self.remove_repo_name) |n| self.allocator.free(n);
        if (self.remove_repo_root) |r| self.allocator.free(r);
        self.remove_repo_name = try self.allocator.dupe(u8, entry.name);
        self.remove_repo_root = try self.allocator.dupe(u8, entry.root);

        // Count sessions so the warning can show how many will be lost.
        // A failure here is non-fatal: we display 0 rather than aborting.
        const repo_root = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ entry.root, entry.name });
        defer self.allocator.free(repo_root);

        var sessions = repo.listWorktrees(self.allocator, self.io, repo_root) catch std.ArrayList([]u8).empty;
        defer {
            for (sessions.items) |s| self.allocator.free(s);
            sessions.deinit(self.allocator);
        }
        self.remove_repo_session_count = sessions.items.len;

        self.screen = .remove_repo_confirm;
    }

    /// Resets add-repo wizard state and sets the initial step (root
    /// selection).
    fn startAddRepo(self: *TuiApp) void {
        self.add_repo_url.clearRetainingCapacity();
        self.add_repo_name.clearRetainingCapacity();
        self.add_repo_branch.clearRetainingCapacity();
        self.add_repo_prefixes.clearRetainingCapacity();
        self.add_repo_new_root.clearRetainingCapacity();
        self.add_repo_derived_name = "";
        if (self.add_repo_root_owned) |r| {
            self.allocator.free(r);
            self.add_repo_root_owned = null;
        }
        self.add_repo_root = "";
        self.selected_worktree_idx = 0;
        self.add_repo_step = 0;
    }

    /// Key handler for the repository sub-menu: navigate with j/k, enter
    /// to select an action, number shortcuts 1-3, q/esc to go back.
    fn handleRepoMenuKey(self: *TuiApp, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const menu_items: u32 = 4; // create, remove, fix, back
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.submenu_cursor < menu_items - 1) self.submenu_cursor += 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.submenu_cursor > 0) self.submenu_cursor -= 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{}) or key.matches('l', .{})) {
            switch (self.submenu_cursor) {
                0 => { // Create session
                    self.screen = .create_session;
                    self.create_step = 0;
                    self.input_session_name.clearRetainingCapacity();
                    self.input_general.clearRetainingCapacity();
                    self.input_hint = null;
                },
                1 => { // Remove session
                    self.refreshWorktrees() catch {};
                    if (self.worktrees.items.len == 0) {
                        self.setMessage("No sessions found.", false);
                        self.screen = .message;
                    } else {
                        self.screen = .remove_session;
                    }
                },
                2 => { // Fix session
                    self.refreshWorktrees() catch {};
                    if (self.worktrees.items.len == 0) {
                        self.setMessage("No sessions found.", false);
                        self.screen = .message;
                    } else {
                        self.screen = .fix_session;
                    }
                },
                3 => { // Back
                    if (self.selected_repo) |*sr| {
                        repo.freeSelectedRepo(self.allocator, sr);
                        self.selected_repo = null;
                    }
                    self.screen = .main_menu;
                    self.refreshRepoList() catch {};
                },
                else => {},
            }
            return ctx.consumeAndRedraw();
        }
        if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
            if (self.selected_repo) |*sr| {
                repo.freeSelectedRepo(self.allocator, sr);
                self.selected_repo = null;
            }
            self.screen = .main_menu;
            self.refreshRepoList() catch {};
            return ctx.consumeAndRedraw();
        }
        // Shortcuts
        if (key.matches('1', .{})) {
            self.submenu_cursor = 0;
            self.screen = .create_session;
            self.create_step = 0;
            self.input_session_name.clearRetainingCapacity();
            self.input_general.clearRetainingCapacity();
            self.input_hint = null;
            return ctx.consumeAndRedraw();
        }
        if (key.matches('2', .{})) {
            self.submenu_cursor = 1;
            self.refreshWorktrees() catch {};
            self.screen = if (self.worktrees.items.len == 0) .message else .remove_session;
            if (self.worktrees.items.len == 0) self.setMessage("No sessions found.", false);
            return ctx.consumeAndRedraw();
        }
        if (key.matches('3', .{})) {
            self.submenu_cursor = 2;
            self.refreshWorktrees() catch {};
            self.screen = if (self.worktrees.items.len == 0) .message else .fix_session;
            if (self.worktrees.items.len == 0) self.setMessage("No sessions found.", false);
            return ctx.consumeAndRedraw();
        }
    }

    /// Key handler for the multi-step create-session wizard. Steps:
    /// 0 = session name input, 1 = base branch selection,
    /// 2 = prefix selection, 3 = confirmation. Esc goes back one step.
    fn handleCreateSessionKey(self: *TuiApp, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            switch (self.create_step) {
                0 => {
                    self.input_hint = null;
                    self.screen = .repo_menu;
                    self.create_step = 0;
                },
                1 => self.create_step = 0, // base branch -> name
                2 => self.create_step = 1, // prefix -> base branch
                3 => self.create_step = 2, // confirm -> prefix (or base branch if no prefixes)
                else => {
                    self.screen = .repo_menu;
                    self.create_step = 0;
                },
            }
            return ctx.consumeAndRedraw();
        }

        const sr = self.selected_repo orelse return;

        switch (self.create_step) {
            0 => { // Session name input
                if (key.matches(vaxis.Key.enter, .{})) {
                    const name_len = self.input_session_name.buf.realLength();
                    if (name_len == 0) return ctx.consumeAndRedraw();
                    const name_duped = self.input_session_name.buf.dupe() catch return;
                    defer self.allocator.free(name_duped);

                    // Validate the full name as a git branch component
                    if (branch_validate.validateBranchName(name_duped)) |err| {
                        self.input_hint = branch_validate.validationMessage(err);
                        return ctx.consumeAndRedraw();
                    }

                    // Check if session already exists
                    const wt_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sr.root, name_duped }) catch return;
                    defer self.allocator.free(wt_path);
                    if (repo.dirExists(self.io, wt_path)) {
                        self.setMessage("Session already exists!", true);
                        self.screen = .message;
                        return ctx.consumeAndRedraw();
                    }

                    self.input_hint = null;

                    // Move to base branch selection
                    if (sr.config.start_branches.items.len <= 1) {
                        self.create_base_branch = if (sr.config.start_branches.items.len == 1) sr.config.start_branches.items[0] else "main";
                        // Skip to prefix
                        if (sr.config.branch_prefixes.items.len <= 1) {
                            self.create_prefix = if (sr.config.branch_prefixes.items.len == 1) sr.config.branch_prefixes.items[0] else "";
                            self.create_step = 3; // go to confirm
                        } else {
                            self.selected_worktree_idx = 0;
                            self.create_step = 2; // pick prefix
                        }
                    } else {
                        self.selected_worktree_idx = 0;
                        self.create_step = 1; // pick base branch
                    }
                    return ctx.consumeAndRedraw();
                }
                // Only allow characters that are safe for both git branch
                // names and directory names (a-z, A-Z, 0-9, hyphen, underscore).
                if (key.text) |text| {
                    for (text) |c| {
                        if (!branch_validate.isAllowedBranchChar(c)) {
                            self.input_hint = branch_validate.rejected_char_hint;
                            return ctx.consumeAndRedraw();
                        }
                    }
                    self.input_hint = null;
                }
                // Forward to text field (backspace, arrows, etc.)
                self.input_hint = null;
                self.input_session_name.widget().handleEvent(ctx, .{ .key_press = key }) catch {};
                return ctx.consumeAndRedraw();
            },
            1 => { // Base branch selection
                const branches = sr.config.start_branches.items;
                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                    if (self.selected_worktree_idx < @as(u32, @intCast(branches.len)) - 1)
                        self.selected_worktree_idx += 1;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                    if (self.selected_worktree_idx > 0) self.selected_worktree_idx -= 1;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    self.create_base_branch = branches[self.selected_worktree_idx];
                    if (sr.config.branch_prefixes.items.len <= 1) {
                        self.create_prefix = if (sr.config.branch_prefixes.items.len == 1) sr.config.branch_prefixes.items[0] else "";
                        self.create_step = 3;
                    } else {
                        self.selected_worktree_idx = 0;
                        self.create_step = 2;
                    }
                    return ctx.consumeAndRedraw();
                }
            },
            2 => { // Prefix selection
                const prefixes = sr.config.branch_prefixes.items;
                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                    if (self.selected_worktree_idx < @as(u32, @intCast(prefixes.len)) - 1)
                        self.selected_worktree_idx += 1;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                    if (self.selected_worktree_idx > 0) self.selected_worktree_idx -= 1;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    self.create_prefix = prefixes[self.selected_worktree_idx];
                    self.create_step = 3;
                    return ctx.consumeAndRedraw();
                }
            },
            3 => { // Confirmation
                if (key.matches('y', .{}) or key.matches(vaxis.Key.enter, .{})) {
                    self.executeCreateSession(ctx);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('n', .{})) {
                    self.screen = .repo_menu;
                    self.create_step = 0;
                    return ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    /// Key handler for the remove-session screen. Selecting a worktree
    /// enters a y/n confirmation sub-step (`create_step == 10`).
    fn handleRemoveSessionKey(self: *TuiApp, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        // If waiting for y/n confirmation, handle that first
        if (self.create_step == 10) {
            if (key.matches('y', .{}) or key.matches(vaxis.Key.enter, .{})) {
                self.executeRemoveSession(ctx);
                return ctx.consumeAndRedraw();
            }
            if (key.matches('n', .{}) or key.matches(vaxis.Key.escape, .{})) {
                self.create_step = 0;
                return ctx.consumeAndRedraw();
            }
            return;
        }

        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            self.screen = .repo_menu;
            return ctx.consumeAndRedraw();
        }
        const count: u32 = @intCast(self.worktrees.items.len);
        if (count == 0) return;
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.selected_worktree_idx < count - 1) self.selected_worktree_idx += 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.selected_worktree_idx > 0) self.selected_worktree_idx -= 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.create_step = 10; // enter confirmation mode
            return ctx.consumeAndRedraw();
        }
    }

    /// Key handler for the fix-session screen. Selecting a worktree
    /// immediately recreates the tmux session and shows the attach prompt.
    fn handleFixSessionKey(self: *TuiApp, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            self.screen = .repo_menu;
            return ctx.consumeAndRedraw();
        }
        const count: u32 = @intCast(self.worktrees.items.len);
        if (count == 0) return;
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.selected_worktree_idx < count - 1) self.selected_worktree_idx += 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.selected_worktree_idx > 0) self.selected_worktree_idx -= 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.executeFixSession(ctx) catch {
                self.setMessage("Failed to fix session", true);
                self.screen = .message;
            };
            return ctx.consumeAndRedraw();
        }
    }

    /// Key handler for the multi-step add-repo wizard. Steps:
    /// 0 = root folder selection, 6 = new root input, 1 = clone URL,
    /// 2 = repo name, 3 = default branch, 4 = prefixes, 5 = confirmation.
    /// Esc goes back one step.
    fn handleAddRepoKey(self: *TuiApp, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            switch (self.add_repo_step) {
                0 => {
                    // From root list, go back to main menu
                    self.screen = .main_menu;
                    self.refreshRepoList() catch {};
                },
                6 => self.add_repo_step = 0, // new root input -> root list
                1 => self.add_repo_step = 0, // URL -> root list
                2 => self.add_repo_step = 1, // name -> URL
                3 => self.add_repo_step = 2, // branch -> name
                4 => self.add_repo_step = 3, // prefixes -> branch
                5 => self.add_repo_step = 4, // confirm -> prefixes
                else => {
                    self.screen = .main_menu;
                    self.refreshRepoList() catch {};
                },
            }
            return ctx.consumeAndRedraw();
        }

        const roots = self.app_config.roots.items;
        const total_root_items: u32 = @intCast(roots.len + 1); // existing roots + "Add new"

        switch (self.add_repo_step) {
            0 => { // Pick root folder (always shown)
                if (key.matches('q', .{})) {
                    self.screen = .main_menu;
                    self.refreshRepoList() catch {};
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                    if (self.selected_worktree_idx < total_root_items - 1)
                        self.selected_worktree_idx += 1;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                    if (self.selected_worktree_idx > 0) self.selected_worktree_idx -= 1;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('a', .{})) {
                    self.add_repo_new_root.clearRetainingCapacity();
                    self.add_repo_step = 6;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.selected_worktree_idx < @as(u32, @intCast(roots.len))) {
                        // Existing root
                        self.add_repo_root = roots[self.selected_worktree_idx];
                        self.add_repo_step = 1;
                    } else {
                        // Add new root
                        self.add_repo_new_root.clearRetainingCapacity();
                        self.add_repo_step = 6;
                    }
                    return ctx.consumeAndRedraw();
                }
            },
            6 => { // New root folder text input
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.add_repo_new_root.buf.realLength() == 0) return ctx.consumeAndRedraw();
                    // Expand tilde and save
                    const raw = self.add_repo_new_root.buf.dupe() catch return;
                    defer self.allocator.free(raw);
                    const expanded = term.expandTilde(self.allocator, self.env, raw) catch return;
                    // Create the directory
                    std.Io.Dir.cwd().createDirPath(self.io, expanded) catch {
                        self.allocator.free(expanded);
                        self.setMessage("Error creating directory", true);
                        self.screen = .message;
                        return ctx.consumeAndRedraw();
                    };
                    // Save to config
                    self.app_config.roots.append(self.allocator, expanded) catch {
                        self.allocator.free(expanded);
                        return;
                    };
                    config.saveAppConfig(self.allocator, self.io, self.env, self.app_config) catch {};
                    // Free previous owned root if any
                    if (self.add_repo_root_owned) |r| self.allocator.free(r);
                    self.add_repo_root_owned = self.allocator.dupe(u8, expanded) catch null;
                    self.add_repo_root = if (self.add_repo_root_owned) |r| r else expanded;
                    self.add_repo_step = 1;
                    return ctx.consumeAndRedraw();
                }
                self.add_repo_new_root.widget().handleEvent(ctx, .{ .key_press = key }) catch {};
                return ctx.consumeAndRedraw();
            },
            1 => { // Clone URL
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.add_repo_url.buf.realLength() == 0) return ctx.consumeAndRedraw();
                    self.add_repo_step = 2;
                    // Derive repo name from URL
                    const url_text = self.add_repo_url.buf.dupe() catch return;
                    defer self.allocator.free(url_text);
                    const derived = git.deriveRepoName(url_text);
                    // Pre-fill the name field with derived name
                    self.add_repo_name.clearRetainingCapacity();
                    self.add_repo_name.insertSliceAtCursor(derived) catch {};
                    return ctx.consumeAndRedraw();
                }
                self.add_repo_url.widget().handleEvent(ctx, .{ .key_press = key }) catch {};
                return ctx.consumeAndRedraw();
            },
            2 => { // Repository name
                if (key.matches(vaxis.Key.enter, .{})) {
                    // If empty, keep derived name (already in field)
                    if (self.add_repo_name.buf.realLength() == 0) return ctx.consumeAndRedraw();
                    self.add_repo_step = 3;
                    // Pre-fill default branch
                    self.add_repo_branch.clearRetainingCapacity();
                    self.add_repo_branch.insertSliceAtCursor("main") catch {};
                    return ctx.consumeAndRedraw();
                }
                self.add_repo_name.widget().handleEvent(ctx, .{ .key_press = key }) catch {};
                return ctx.consumeAndRedraw();
            },
            3 => { // Default branch
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.add_repo_branch.buf.realLength() == 0) return ctx.consumeAndRedraw();
                    self.add_repo_step = 4;
                    // Pre-fill prefixes from the configured default list
                    // (seeded from the standard list when config.toml does
                    // not specify one).
                    self.add_repo_prefixes.clearRetainingCapacity();
                    if (config.joinPrefixesCsv(self.allocator, self.app_config.default_branch_prefixes.items)) |csv| {
                        defer self.allocator.free(csv);
                        self.add_repo_prefixes.insertSliceAtCursor(csv) catch {};
                    } else |_| {}
                    return ctx.consumeAndRedraw();
                }
                self.add_repo_branch.widget().handleEvent(ctx, .{ .key_press = key }) catch {};
                return ctx.consumeAndRedraw();
            },
            4 => { // Branch prefixes
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.add_repo_prefixes.buf.realLength() == 0) return ctx.consumeAndRedraw();
                    self.add_repo_step = 5;
                    return ctx.consumeAndRedraw();
                }
                self.add_repo_prefixes.widget().handleEvent(ctx, .{ .key_press = key }) catch {};
                return ctx.consumeAndRedraw();
            },
            5 => { // Confirm
                if (key.matches('y', .{}) or key.matches(vaxis.Key.enter, .{})) {
                    self.executeAddRepo(ctx);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('n', .{})) {
                    self.screen = .main_menu;
                    self.refreshRepoList() catch {};
                    return ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    /// Key handler for the remove-repository confirmation screen.
    /// `y` (or Enter) commits the removal; `n` or Esc cancels and
    /// returns to the main menu.
    fn handleRemoveRepoConfirmKey(self: *TuiApp, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches('y', .{}) or key.matches(vaxis.Key.enter, .{})) {
            self.executeRemoveRepo(ctx);
            return ctx.consumeAndRedraw();
        }
        if (key.matches('n', .{}) or key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            // Drop the captured target and return to the main menu.
            if (self.remove_repo_name) |n| self.allocator.free(n);
            if (self.remove_repo_root) |r| self.allocator.free(r);
            self.remove_repo_name = null;
            self.remove_repo_root = null;
            self.remove_repo_session_count = 0;
            self.screen = .main_menu;
            return ctx.consumeAndRedraw();
        }
    }

    // ── Operations ───────────────────────────────────────────────────

    /// Kicks off the create-session operation: validates the branch name,
    /// snapshots values on the main thread, creates a `ProgressOutput`
    /// for live feedback, and spawns the work on a background thread.
    fn executeCreateSession(self: *TuiApp, ctx: *vxfw.EventContext) void {
        const sr = self.selected_repo orelse return;
        // Get the full text from the gap buffer
        const name_owned = self.input_session_name.buf.dupe() catch return;
        defer self.allocator.free(name_owned);
        const name = name_owned;

        var branch_name_buf: [512]u8 = undefined;
        const branch_name = if (self.create_prefix.len > 0)
            std.fmt.bufPrint(&branch_name_buf, "{s}/{s}", .{ self.create_prefix, name }) catch return
        else
            name;

        const bare_repo_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.git", .{ sr.root, sr.config.bare_repo }) catch return;
        defer self.allocator.free(bare_repo_path);

        // Branch existence check is fast (local rev-parse), keep it synchronous
        if (git.gitBranchExists(self.allocator, self.io, bare_repo_path, branch_name)) {
            self.setMessage("Branch already exists!", true);
            self.screen = .message;
            return;
        }

        // Snapshot all values needed by the worker thread
        self.freeWorkerSnapshots();
        self.worker_session_name = self.allocator.dupe(u8, name) catch null;
        self.worker_base_branch = self.allocator.dupe(u8, self.create_base_branch) catch null;
        self.worker_prefix = self.allocator.dupe(u8, self.create_prefix) catch null;
        self.worker_bare_repo_name = self.allocator.dupe(u8, sr.config.bare_repo) catch null;
        self.worker_repo_root = self.allocator.dupe(u8, sr.root) catch null;
        self.worker_sr_name = self.allocator.dupe(u8, sr.name) catch null;
        self.worker_windows = sr.config.windows.items;

        if (self.worker_session_name == null or self.worker_base_branch == null or
            self.worker_prefix == null or self.worker_bare_repo_name == null or
            self.worker_repo_root == null or self.worker_sr_name == null)
        {
            self.setMessage("Allocation failure", true);
            self.screen = .message;
            return;
        }

        // Create progress output for streaming git output
        if (self.worker_progress) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.worker_progress = self.allocator.create(process.ProgressOutput) catch null;
        if (self.worker_progress) |p| {
            p.* = process.ProgressOutput.init(self.allocator, self.io);
        }

        self.setMessage("Session created successfully!", false);
        self.startWorking(ctx, "Creating session...", .attach_confirm, createSessionWorker);
    }

    /// Background thread entry point for the create-session operation.
    /// Sets `worker_done` and optionally `worker_error` on completion.
    fn createSessionWorker(self: *TuiApp) void {
        self.createSessionWorkerInner() catch {
            if (self.worker_error == null) {
                self.worker_error = self.allocator.dupe(u8, "Session creation failed") catch null;
            }
        };
        self.worker_done.store(true, .release);
    }

    /// Inner implementation for `createSessionWorker`. Creates the
    /// worktree, saves session metadata, and creates the tmux session.
    /// Reads only from the `worker_*` snapshot fields (populated on the
    /// main thread) -- never touches TextFields or other UI state.
    fn createSessionWorkerInner(self: *TuiApp) !void {
        const name = self.worker_session_name orelse return error.MissingSnapshot;
        const base_branch = self.worker_base_branch orelse return error.MissingSnapshot;
        const prefix = self.worker_prefix orelse return error.MissingSnapshot;
        const bare_repo_name = self.worker_bare_repo_name orelse return error.MissingSnapshot;
        const repo_root = self.worker_repo_root orelse return error.MissingSnapshot;
        const sr_name = self.worker_sr_name orelse return error.MissingSnapshot;

        // Build the full branch name
        var branch_name_buf: [512]u8 = undefined;
        const branch_name = if (prefix.len > 0)
            std.fmt.bufPrint(&branch_name_buf, "{s}/{s}", .{ prefix, name }) catch {
                self.worker_error = self.allocator.dupe(u8, "Branch name too long") catch null;
                return;
            }
        else
            name;

        // Create worktree with progress feedback
        if (self.worker_progress) |progress| {
            git.gitCreateWorktreeWithProgress(self.allocator, self.io, repo_root, bare_repo_name, name, branch_name, base_branch, progress) catch {
                self.worker_error = self.allocator.dupe(u8, "Failed to create worktree") catch null;
                return;
            };
            progress.appendLine("Saving session file...");
        } else {
            git.gitCreateWorktree(self.allocator, self.io, repo_root, bare_repo_name, name, branch_name, base_branch) catch {
                self.worker_error = self.allocator.dupe(u8, "Failed to create worktree") catch null;
                return;
            };
        }

        // Save session metadata into the bare repo
        const bare_repo_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.git", .{ repo_root, bare_repo_name }) catch {
            self.worker_error = self.allocator.dupe(u8, "Allocation failure") catch null;
            return;
        };
        defer self.allocator.free(bare_repo_path);
        repo.saveSessionFile(self.allocator, self.io, base_branch, branch_name, bare_repo_path, name) catch {
            self.worker_error = self.allocator.dupe(u8, "Failed to save session file") catch null;
            return;
        };

        if (self.worker_progress) |progress| {
            progress.appendLine("Creating tmux session...");
        }

        // Create tmux session
        const wt_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ repo_root, name }) catch {
            self.worker_error = self.allocator.dupe(u8, "Allocation failure") catch null;
            return;
        };
        defer self.allocator.free(wt_path);
        const tmux_name = tmux.tmuxSessionName(self.allocator, name, branch_name, sr_name) catch {
            self.worker_error = self.allocator.dupe(u8, "Failed to generate tmux name") catch null;
            return;
        };
        defer self.allocator.free(tmux_name);
        tmux.tmuxCreateSession(self.allocator, self.io, tmux_name, wt_path, self.worker_windows) catch {
            // Roll back: remove the worktree and session file so the
            // user doesn't end up with an orphaned, half-created session.
            _ = git.gitRemoveWorktree(self.allocator, self.io, bare_repo_path, name) catch {};
            repo.deleteSessionFile(self.allocator, self.io, bare_repo_path, name);
            self.worker_error = self.allocator.dupe(u8, "Failed to create tmux session") catch null;
            return;
        };

        // Set up the pending attach name (safe: main thread only reads this
        // after the worker has been joined in the tick handler).
        self.setPendingAttach(tmux_name);

        if (self.worker_progress) |progress| {
            progress.appendLine("Session created successfully!");
        }
    }

    /// Sends a tmux notification about the remove-session result
    /// (success or failure) and signals the TUI to quit. Used when the
    /// user has switched away from the git-session tmux session and
    /// cannot see the TUI message screen.
    fn notifyRemovedAndQuit(self: *TuiApp, ctx: *vxfw.EventContext) void {
        const session_name = self.worker_rm_session_name orelse "unknown";
        if (self.worker_error) |err_msg| {
            const notify_msg = std.fmt.allocPrint(self.allocator, "[git-session] Removal failed: {s}", .{err_msg}) catch null;
            if (notify_msg) |msg| {
                defer self.allocator.free(msg);
                tmux.tmuxNotify(self.allocator, self.io, msg, 5000, self.tmux_client_name);
            }
        } else {
            const notify_msg = std.fmt.allocPrint(self.allocator, "[git-session] Session removed: {s}", .{session_name}) catch null;
            if (notify_msg) |msg| {
                defer self.allocator.free(msg);
                tmux.tmuxNotify(self.allocator, self.io, msg, 5000, self.tmux_client_name);
            }
        }
        ctx.quit = true;
    }

    /// Removes a session (worktree, branch, session file, and tmux
    /// session) and shows a dismissable message. The app quits on
    /// dismiss.
    fn executeRemoveSession(self: *TuiApp, ctx: *vxfw.EventContext) void {
        const sr = self.selected_repo orelse return;
        const session_name = self.worktrees.items[self.selected_worktree_idx];

        const bare_repo_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.git", .{ sr.root, sr.config.bare_repo }) catch return;
        defer self.allocator.free(bare_repo_path);

        // Try session file first; fall back to asking git for the branch.
        const info = repo.parseSessionFile(self.allocator, self.io, bare_repo_path, session_name) catch repo.SessionInfo{ .branch = "", .branch_name = "" };
        defer {
            if (info.branch.len > 0) self.allocator.free(info.branch);
            if (info.branch_name.len > 0) self.allocator.free(info.branch_name);
        }

        const branch_name: ?[]const u8 = if (info.branch_name.len > 0)
            self.allocator.dupe(u8, info.branch_name) catch null
        else blk: {
            const wt_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sr.root, session_name }) catch break :blk null;
            defer self.allocator.free(wt_path);
            break :blk git.gitWorktreeBranch(self.allocator, self.io, wt_path);
        };

        // Snapshot all values needed by the worker thread
        self.freeWorkerSnapshots();
        self.worker_rm_session_name = self.allocator.dupe(u8, session_name) catch null;
        self.worker_rm_bare_repo_path = self.allocator.dupe(u8, bare_repo_path) catch null;

        if (self.worker_rm_session_name == null or self.worker_rm_bare_repo_path == null) {
            if (branch_name) |bn| self.allocator.free(bn);
            self.setMessage("Out of memory", true);
            self.screen = .message;
            return;
        }

        if (branch_name) |bn| {
            self.worker_rm_branch_name = bn;
            self.worker_rm_tmux_name = tmux.tmuxSessionName(self.allocator, session_name, bn, sr.name) catch null;
        } else {
            self.worker_rm_branch_name = null;
            self.worker_rm_tmux_name = null;
        }

        // If the user has switched to another tmux session, perform the
        // removal synchronously, show an ephemeral notification on their
        // client, and quit silently.
        if (self.hasUserSwitchedAway()) {
            self.removeSessionWorkerInner() catch {};
            self.notifyRemovedAndQuit(ctx);
            return ctx.consumeAndRedraw();
        }

        self.setMessage("Session removed.", false);
        self.quit_on_dismiss = true;
        self.create_step = 0;
        self.startWorking(ctx, "Removing session...", .message, removeSessionWorker);
    }

    /// Background thread entry point for the remove-session operation.
    /// Sets `worker_done` and optionally `worker_error` on completion.
    fn removeSessionWorker(self: *TuiApp) void {
        self.removeSessionWorkerInner() catch {
            if (self.worker_error == null) {
                self.worker_error = self.allocator.dupe(u8, "Session removal failed") catch null;
            }
        };
        self.worker_done.store(true, .release);
    }

    /// Inner implementation for `removeSessionWorker`. Switches the
    /// user away from the tmux session first, performs all git cleanup
    /// (worktree removal, session file deletion, branch deletion), and
    /// then kills the tmux session as the very last step.
    ///
    /// The tmux kill MUST be last because when removing the currently
    /// active session, the git-session TUI process is running inside
    /// that tmux session. Killing it earlier would terminate this
    /// process before cleanup completes, leaving the worktree behind.
    ///
    /// A `defer` block ensures the tmux session is killed even when
    /// git operations fail and the function returns early.
    ///
    /// Reads only from the `worker_*` snapshot fields (populated on the
    /// main thread) -- never touches TextFields or other UI state.
    fn removeSessionWorkerInner(self: *TuiApp) !void {
        const session_name = self.worker_rm_session_name orelse return error.MissingSnapshot;
        const bare_repo_path = self.worker_rm_bare_repo_path orelse return error.MissingSnapshot;

        // Switch the user away from the session being removed so they
        // are not dropped to a bare terminal when we kill it later.
        // This does NOT kill the session -- our process keeps running.
        if (self.worker_rm_tmux_name) |tmux_name| {
            tmux.tmuxSwitchAwayIfCurrent(self.allocator, self.io, self.env, tmux_name);
        }

        // Kill the tmux session as the very last step, even on early
        // return. When removing the active session this terminates our
        // own process, so all git cleanup must complete first. Using
        // `defer` guarantees the kill runs even when git operations
        // fail, preventing a zombie tmux session the user can't see.
        defer {
            if (self.worker_rm_tmux_name) |tmux_name| {
                if (tmux.tmuxSessionExists(self.allocator, self.io, tmux_name)) {
                    tmux.tmuxKillSession(self.allocator, self.io, tmux_name) catch {};
                }
            }
        }

        // Wait briefly for any processes in the tmux session (editors,
        // shells) to notice the client detached. This gives them a
        // chance to release the worktree directory before we remove it.
        // The tmux session is still alive at this point (killed in
        // defer above), but without a client attached, well-behaved
        // programs will start to wind down.
        if (self.worker_rm_tmux_name) |tmux_name| {
            if (tmux.tmuxSessionExists(self.allocator, self.io, tmux_name)) {
                // Send C-c and 'exit' to all panes to encourage
                // processes to release the worktree directory.
                tmux.tmuxSendExitToAllPanes(self.allocator, self.io, tmux_name);

                var attempts: u8 = 0;
                while (attempts < 10) : (attempts += 1) {
                    if (!tmux.tmuxSessionExists(self.allocator, self.io, tmux_name)) break;
                    self.io.sleep(.fromMilliseconds(50), .awake) catch {};
                }
            }
        }

        // Remove the git worktree.
        const wt_err = git.gitRemoveWorktree(self.allocator, self.io, bare_repo_path, session_name) catch {
            self.worker_error = self.allocator.dupe(u8, "Failed to remove worktree") catch null;
            return;
        };
        if (wt_err) |err_msg| {
            self.worker_error = err_msg;
            return;
        }

        // Clean up session metadata now that the worktree is gone.
        repo.deleteSessionFile(self.allocator, self.io, bare_repo_path, session_name);

        if (self.worker_rm_branch_name) |branch_name| {
            git.gitDeleteBranch(self.allocator, self.io, bare_repo_path, branch_name) catch {
                self.worker_error = self.allocator.dupe(u8, "Failed to delete branch") catch null;
                return;
            };
        }
    }

    /// Recreates a tmux session for an existing worktree and transitions
    /// to the attach-confirm screen.
    fn executeFixSession(self: *TuiApp, ctx: *vxfw.EventContext) !void {
        const sr = self.selected_repo orelse return;
        const session_name = self.worktrees.items[self.selected_worktree_idx];

        const wt_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sr.root, session_name });
        defer self.allocator.free(wt_path);
        const bare_repo_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.git", .{ sr.root, sr.config.bare_repo });
        defer self.allocator.free(bare_repo_path);

        // Try session file first; fall back to asking git for the branch.
        const info = repo.parseSessionFile(self.allocator, self.io, bare_repo_path, session_name) catch repo.SessionInfo{ .branch = "", .branch_name = "" };
        defer {
            if (info.branch.len > 0) self.allocator.free(info.branch);
            if (info.branch_name.len > 0) self.allocator.free(info.branch_name);
        }

        const git_branch = if (info.branch_name.len == 0 and info.branch.len == 0)
            git.gitWorktreeBranch(self.allocator, self.io, wt_path)
        else
            null;
        defer if (git_branch) |gb| self.allocator.free(gb);

        const branch_for_name: []const u8 = if (info.branch_name.len > 0)
            info.branch_name
        else if (info.branch.len > 0)
            info.branch
        else
            git_branch orelse {
                self.setMessage("Could not determine branch for session", true);
                self.screen = .message;
                return;
            };
        const tmux_name = try tmux.tmuxSessionName(self.allocator, session_name, branch_for_name, sr.name);
        defer self.allocator.free(tmux_name);

        try tmux.tmuxCreateSession(self.allocator, self.io, tmux_name, wt_path, sr.config.windows.items);

        // If the user switched away, show a popup on their current
        // client instead of the TUI attach-confirm screen.
        if (self.hasUserSwitchedAway()) {
            tmux.tmuxDisplayPopup(self.allocator, self.io, tmux_name, self.tmux_client_name);
            ctx.quit = true;
            return ctx.consumeAndRedraw();
        }

        self.setMessage("Session fixed!", false);
        self.setPendingAttach(tmux_name);
        self.screen = .attach_confirm;
    }

    /// Kicks off the add-repo operation: snapshots text field values on
    /// the main thread, creates a `ProgressOutput` for live clone
    /// feedback, and spawns the clone on a background thread.
    fn executeAddRepo(self: *TuiApp, ctx: *vxfw.EventContext) void {
        // Snapshot text fields on the main thread so the worker never
        // touches the TextField gap buffers (P0 thread-safety fix).
        self.freeWorkerSnapshots();
        self.worker_url = self.add_repo_url.buf.dupe() catch null;
        self.worker_repo_name = self.add_repo_name.buf.dupe() catch null;
        self.worker_branch = self.add_repo_branch.buf.dupe() catch null;
        self.worker_prefixes = self.add_repo_prefixes.buf.dupe() catch null;
        self.worker_root = self.allocator.dupe(u8, self.add_repo_root) catch null;

        if (self.worker_url == null or self.worker_repo_name == null or
            self.worker_branch == null or self.worker_prefixes == null or
            self.worker_root == null)
        {
            self.setMessage("Allocation failure", true);
            self.screen = .message;
            return;
        }

        // Create progress output for streaming clone output
        if (self.worker_progress) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.worker_progress = self.allocator.create(process.ProgressOutput) catch null;
        if (self.worker_progress) |p| {
            p.* = process.ProgressOutput.init(self.allocator, self.io);
        }

        // Set success message (will be shown after worker completes)
        self.setMessage("Repository added successfully!", false);
        self.startWorking(ctx, "Cloning repository...", .message, addRepoWorker);
    }

    /// Background thread entry point for the add-repo operation.
    /// Sets `worker_done` and optionally `worker_error` on completion.
    fn addRepoWorker(self: *TuiApp) void {
        self.addRepoWorkerInner() catch {
            if (self.worker_error == null) {
                self.worker_error = self.allocator.dupe(u8, "Clone failed") catch null;
            }
        };
        self.worker_done.store(true, .release);
    }

    /// Inner implementation for `addRepoWorker`. Clones the repo and writes
    /// the generated repo config to the centralized location
    /// (`~/.config/git-session/repos/<repo-name>.toml`).
    /// Reads only from the `worker_*` snapshot fields (populated on the
    /// main thread) -- never touches TextFields or other UI state.
    fn addRepoWorkerInner(self: *TuiApp) !void {
        // Read from pre-snapshotted values (safe to access from worker thread).
        const url = self.worker_url orelse return error.MissingSnapshot;
        const repo_name = self.worker_repo_name orelse return error.MissingSnapshot;
        const default_branch = self.worker_branch orelse return error.MissingSnapshot;
        const prefixes_raw = self.worker_prefixes orelse return error.MissingSnapshot;
        const root = self.worker_root orelse return error.MissingSnapshot;

        // Create directory
        const repo_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, repo_name });
        defer self.allocator.free(repo_dir);

        std.Io.Dir.cwd().createDirPath(self.io, repo_dir) catch {
            self.worker_error = self.allocator.dupe(u8, "Error creating directory") catch null;
            return;
        };

        // Clone (this is the slow part)
        if (self.worker_progress) |progress| {
            const clone_msg = std.fmt.allocPrint(self.allocator, "git clone --progress {s}", .{url}) catch null;
            if (clone_msg) |m| {
                progress.appendLine(m);
                self.allocator.free(m);
            }
            git.gitCloneForSessionWithProgress(self.allocator, self.io, url, repo_dir, repo_name, progress) catch {
                self.worker_error = self.allocator.dupe(u8, "Clone failed") catch null;
                return;
            };
            progress.appendLine("Configuring repository...");
        } else {
            git.gitCloneForSession(self.allocator, self.io, url, repo_dir, repo_name) catch {
                self.worker_error = self.allocator.dupe(u8, "Clone failed") catch null;
                return;
            };
        }

        // Generate the centralized TOML config. `url` and `root` are
        // recorded as recovery metadata so that `repo.ensureBareRepo`
        // can re-clone if the user accidentally deletes the bare
        // repository (or its parent folders) later. Allocation failures
        // here would corrupt the resulting file, so we surface them via
        // `worker_error` rather than silently swallowing.
        const toml_content = config.generateRepoConfigToml(self.allocator, repo_name, default_branch, prefixes_raw, url, root) catch {
            self.worker_error = self.allocator.dupe(u8, "Error generating config") catch null;
            return;
        };
        defer self.allocator.free(toml_content);

        // Write the generated config to the centralized location
        // (`~/.config/git-session/repos/<repo-name>.toml`) so the working
        // tree is left untouched. The per-repo `.git-session.toml` location
        // is still honoured by the reader as a backward-compatible fallback.
        config.writeCentralRepoConfig(self.allocator, self.io, self.env, repo_name, toml_content) catch |err| {
            const msg = switch (err) {
                error.NoHome => "Error writing config: HOME is not set",
                else => "Error writing config",
            };
            self.worker_error = self.allocator.dupe(u8, msg) catch null;
            return;
        };
    }

    /// Kicks off the remove-repository operation: snapshots the target
    /// name, root, and session list on the main thread, then spawns a
    /// background worker to do the slow work (tmux teardown + tree
    /// deletion + central config removal).
    fn executeRemoveRepo(self: *TuiApp, ctx: *vxfw.EventContext) void {
        const repo_name = self.remove_repo_name orelse return;
        const root = self.remove_repo_root orelse return;

        const repo_root = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, repo_name }) catch {
            self.setMessage("Allocation failure", true);
            self.screen = .message;
            return;
        };

        // Snapshot the session list now (on the main thread) so the
        // worker doesn't need to call into `repo.listWorktrees` -- the
        // main thread is the only place that touches state cleanly.
        var sessions = repo.listWorktrees(self.allocator, self.io, repo_root) catch std.ArrayList([]u8).empty;

        self.freeWorkerSnapshots();
        self.worker_rr_repo_name = self.allocator.dupe(u8, repo_name) catch null;
        self.worker_rr_root = self.allocator.dupe(u8, root) catch null;
        self.worker_rr_repo_root = repo_root; // ownership transferred to the snapshot
        self.worker_rr_sessions = sessions.toOwnedSlice(self.allocator) catch null;
        if (self.worker_rr_sessions == null) {
            for (sessions.items) |s| self.allocator.free(s);
            sessions.deinit(self.allocator);
        }

        if (self.worker_rr_repo_name == null or self.worker_rr_root == null or
            self.worker_rr_repo_root == null or self.worker_rr_sessions == null)
        {
            self.setMessage("Allocation failure", true);
            self.screen = .message;
            return;
        }

        self.setMessage("Repository removed.", false);
        self.startWorking(ctx, "Removing repository...", .message, removeRepoWorker);
    }

    /// Background thread entry point for the remove-repository operation.
    /// Sets `worker_done` and optionally `worker_error` on completion.
    fn removeRepoWorker(self: *TuiApp) void {
        self.removeRepoWorkerInner() catch {
            if (self.worker_error == null) {
                self.worker_error = self.allocator.dupe(u8, "Repository removal failed") catch null;
            }
        };
        self.worker_done.store(true, .release);
    }

    /// Inner implementation for `removeRepoWorker`. Kills every tmux
    /// session for the repository, deletes the on-disk tree (bare repo
    /// + every worktree), and removes the centralized config file.
    ///
    /// Reads only from the `worker_rr_*` snapshot fields populated on
    /// the main thread -- never touches TextFields or other UI state.
    fn removeRepoWorkerInner(self: *TuiApp) !void {
        const repo_name = self.worker_rr_repo_name orelse return error.MissingSnapshot;
        const root = self.worker_rr_root orelse return error.MissingSnapshot;
        const repo_root = self.worker_rr_repo_root orelse return error.MissingSnapshot;
        const sessions = self.worker_rr_sessions orelse return error.MissingSnapshot;

        // Resolve the bare repo name from the per-repo config when
        // possible; fall back to the conventional `<repo_name>` so
        // tmux session-name computation matches what the create flow
        // produced.
        var bare_repo_name_owned: ?[]u8 = null;
        defer if (bare_repo_name_owned) |b| self.allocator.free(b);

        if (repo.loadRepoConfig(self.allocator, self.io, self.env, repo_root)) |loaded_cfg| {
            var cfg = loaded_cfg;
            defer repo.freeRepoConfig(self.allocator, &cfg);
            if (cfg.bare_repo.len > 0) {
                bare_repo_name_owned = try self.allocator.dupe(u8, cfg.bare_repo);
            }
        } else |_| {}

        const bare_repo_name = bare_repo_name_owned orelse repo_name;
        const bare_repo_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.git", .{ repo_root, bare_repo_name }) catch {
            self.worker_error = self.allocator.dupe(u8, "Allocation failure") catch null;
            return;
        };
        defer self.allocator.free(bare_repo_path);

        // Tear down each tmux session before nuking the directory tree.
        for (sessions) |session_name| {
            const info = repo.parseSessionFile(self.allocator, self.io, bare_repo_path, session_name) catch
                repo.SessionInfo{ .branch = "", .branch_name = "" };
            defer {
                if (info.branch.len > 0) self.allocator.free(info.branch);
                if (info.branch_name.len > 0) self.allocator.free(info.branch_name);
            }

            const branch_name: ?[]const u8 = if (info.branch_name.len > 0)
                self.allocator.dupe(u8, info.branch_name) catch null
            else blk: {
                const wt_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ repo_root, session_name }) catch break :blk null;
                defer self.allocator.free(wt_path);
                break :blk git.gitWorktreeBranch(self.allocator, self.io, wt_path);
            };
            defer if (branch_name) |bn| self.allocator.free(bn);

            const tmux_name: ?[]u8 = if (branch_name) |bn|
                tmux.tmuxSessionName(self.allocator, session_name, bn, repo_name) catch null
            else
                null;
            defer if (tmux_name) |tn| self.allocator.free(tn);

            if (tmux_name) |tn| {
                tmux.tmuxSwitchAwayIfCurrent(self.allocator, self.io, self.env, tn);
                if (tmux.tmuxSessionExists(self.allocator, self.io, tn)) {
                    tmux.tmuxSendExitToAllPanes(self.allocator, self.io, tn);
                    var attempts: u8 = 0;
                    while (attempts < 10) : (attempts += 1) {
                        if (!tmux.tmuxSessionExists(self.allocator, self.io, tn)) break;
                        self.io.sleep(.fromMilliseconds(50), .awake) catch {};
                    }
                    if (tmux.tmuxSessionExists(self.allocator, self.io, tn)) {
                        tmux.tmuxKillSession(self.allocator, self.io, tn) catch {};
                    }
                }
            }
        }

        // Delete the on-disk repository tree.
        repo.removeRepositoryDirectory(self.allocator, self.io, root, repo_name) catch {
            self.worker_error = self.allocator.dupe(u8, "Failed to delete repository directory") catch null;
            return;
        };

        // Delete the centralized config file (no error if HOME is unset
        // or the file was never created).
        config.deleteCentralRepoConfig(self.allocator, self.io, self.env, repo_name) catch |err| switch (err) {
            error.NoHome => {},
            else => {
                self.worker_error = self.allocator.dupe(u8, "Failed to delete central config") catch null;
                return;
            },
        };
    }

    // ── Drawing ──────────────────────────────────────────────────────

    /// Root draw function. Constrains content to a fixed box, delegates
    /// to the active screen's draw method, and centres the result in the
    /// terminal.
    fn draw(self: *TuiApp, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();

        // The working screen uses a wider box (3x) so git log output
        // is readable. All other screens use the normal 64-column box.
        const is_working = self.screen == .working;
        const content_width: u16 = @min(max.width, if (is_working) @as(u16, 192) else @as(u16, 64));
        const content_height: u16 = @min(max.height, if (is_working) max.height else @as(u16, 30));

        const content_ctx = ctx.withConstraints(
            .{},
            .{ .width = content_width, .height = content_height },
        );

        // Build inner content based on screen
        const inner_widget = switch (self.screen) {
            .main_menu => self.drawMainMenu(content_ctx),
            .repo_menu => self.drawRepoMenu(content_ctx),
            .create_session => self.drawCreateSession(content_ctx),
            .remove_session => self.drawRemoveSession(content_ctx),
            .fix_session => self.drawFixSession(content_ctx),
            .add_repo => self.drawAddRepo(content_ctx),
            .remove_repo_confirm => self.drawRemoveRepoConfirm(content_ctx),
            .attach_confirm => self.drawAttachConfirm(content_ctx),
            .working => self.drawWorking(content_ctx),
            .message => self.drawMessage(content_ctx),
            else => self.drawMainMenu(content_ctx),
        };

        // Draw the inner content at the constrained size
        const inner_surface = inner_widget.draw(content_ctx) catch return vxfw.Surface{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = &.{},
        };

        // Center the content surface within the terminal
        const col_offset: i17 = @intCast((@as(u17, max.width) -| inner_surface.size.width) / 2);
        const row_offset: i17 = @intCast((@as(u17, max.height) -| inner_surface.size.height) / 2);

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = row_offset, .col = col_offset },
            .surface = inner_surface,
        };

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    /// Renders the main menu: title, repository list, add-repo option,
    /// quit option, and help bar.
    fn drawMainMenu(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        const arena = ctx.arena;
        const repo_count = self.repo_entries.items.len;
        const total_items = repo_count + 2; // repos + add + quit

        // Header + items + footer hint
        const line_count = 3 + total_items + 3; // title + subtitle + gap + items + gap + help
        const children = arena.alloc(vxfw.SubSurface, line_count) catch return emptyWidget(arena);

        var row: i17 = 0;

        // Title
        const title_text: vxfw.Text = .{
            .text = "  Git Session Manager",
            .style = style.title,
            .width_basis = .parent,
        };
        children[0] = .{ .origin = .{ .row = row, .col = 0 }, .surface = title_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
        row += 1;

        // Subtitle
        const subtitle: vxfw.Text = .{
            .text = "  Select a repository",
            .style = style.dimmed,
            .width_basis = .parent,
        };
        children[1] = .{ .origin = .{ .row = row, .col = 0 }, .surface = subtitle.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
        row += 2;

        // Repo items
        var child_idx: usize = 2;
        for (self.repo_entries.items, 0..) |entry, i| {
            const is_selected = i == self.selected_repo_idx;
            const indicator = if (is_selected) "  > " else "    ";
            const entry_style = if (is_selected) style.selected else style.normal;

            const label = std.fmt.allocPrint(arena, "{s}{s}", .{ indicator, entry.name }) catch "?";
            const item_text: vxfw.Text = .{
                .text = label,
                .style = entry_style,
                .width_basis = .parent,
            };
            children[child_idx] = .{
                .origin = .{ .row = row, .col = 0 },
                .surface = item_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
            };
            row += 1;
            child_idx += 1;
        }

        row += 1;

        // Add repository option
        {
            const is_selected = self.selected_repo_idx == @as(u32, @intCast(repo_count));
            const indicator = if (is_selected) "  > " else "    ";
            const entry_style: vaxis.Cell.Style = if (is_selected) style.success else .{ .fg = colors.green };
            const label = std.fmt.allocPrint(arena, "{s}[a] Add a new repository", .{indicator}) catch "Add";
            const item_text: vxfw.Text = .{
                .text = label,
                .style = entry_style,
                .width_basis = .parent,
            };
            children[child_idx] = .{
                .origin = .{ .row = row, .col = 0 },
                .surface = item_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
            };
            row += 1;
            child_idx += 1;
        }

        // Quit option
        {
            const is_selected = self.selected_repo_idx == @as(u32, @intCast(repo_count + 1));
            const indicator = if (is_selected) "  > " else "    ";
            const entry_style = if (is_selected) style.dimmed else style.dimmed;
            const label = std.fmt.allocPrint(arena, "{s}[q] Quit", .{indicator}) catch "Quit";
            const item_text: vxfw.Text = .{
                .text = label,
                .style = entry_style,
                .width_basis = .parent,
            };
            children[child_idx] = .{
                .origin = .{ .row = row, .col = 0 },
                .surface = item_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
            };
            row += 2;
            child_idx += 1;
        }

        // Help bar
        const help: vxfw.Text = .{
            .text = "  j/k: navigate  enter: select  a: add repo  D: remove repo  q: quit",
            .style = style.dimmed,
            .width_basis = .parent,
        };
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 0 },
            .surface = help.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };
        child_idx += 1;

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..child_idx],
        };
        // Return a "wrapper" widget that draws the surface directly
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }

    /// Renders the repository sub-menu with create / remove / fix / back
    /// actions and number shortcuts.
    fn drawRepoMenu(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        const arena = ctx.arena;
        const sr = self.selected_repo orelse return emptyWidget(arena);

        const menu_items = [_][]const u8{
            "Create a new session",
            "Remove a session",
            "Fix a session (reattach)",
            "Back",
        };
        const shortcuts = [_][]const u8{ "1", "2", "3", "q" };
        const item_styles = [_]vaxis.Cell.Style{
            .{ .fg = colors.green, .bold = true },
            .{ .fg = colors.red, .bold = true },
            .{ .fg = colors.yellow, .bold = true },
            style.dimmed,
        };

        // Title + blank + items + blank + help
        const children = arena.alloc(vxfw.SubSurface, 3 + menu_items.len + 2) catch return emptyWidget(arena);
        var row: i17 = 0;

        // Title
        const title_label = std.fmt.allocPrint(arena, "  {s}", .{sr.name}) catch "?";
        const title_text: vxfw.Text = .{
            .text = title_label,
            .style = style.title,
            .width_basis = .parent,
        };
        children[0] = .{ .origin = .{ .row = row, .col = 0 }, .surface = title_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
        row += 1;

        // Subtitle
        const sub_label = std.fmt.allocPrint(arena, "  {s}", .{sr.root}) catch "";
        const subtitle: vxfw.Text = .{
            .text = sub_label,
            .style = style.dimmed,
            .width_basis = .parent,
        };
        children[1] = .{ .origin = .{ .row = row, .col = 0 }, .surface = subtitle.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
        row += 2;

        // Menu items
        var child_idx: usize = 2;
        for (menu_items, 0..) |item, i| {
            const is_selected = i == self.submenu_cursor;
            const indicator = if (is_selected) "  > " else "    ";
            const sel_style = if (is_selected) item_styles[i] else style.normal;

            const label = std.fmt.allocPrint(arena, "{s}[{s}] {s}", .{ indicator, shortcuts[i], item }) catch "?";
            const item_text: vxfw.Text = .{
                .text = label,
                .style = sel_style,
                .width_basis = .parent,
            };
            children[child_idx] = .{
                .origin = .{ .row = row, .col = 0 },
                .surface = item_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
            };
            row += 1;
            child_idx += 1;
        }

        row += 1;

        // Help
        const help: vxfw.Text = .{
            .text = "  j/k: navigate  enter: select  q/esc: back",
            .style = style.dimmed,
            .width_basis = .parent,
        };
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 0 },
            .surface = help.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };
        child_idx += 1;

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..child_idx],
        };
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }

    /// Renders the create-session wizard. Displays the appropriate step:
    /// name input, branch list, prefix list, or confirmation summary.
    fn drawCreateSession(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        const arena = ctx.arena;
        const sr = self.selected_repo orelse return emptyWidget(arena);

        const max_children: usize = 20;
        const children = arena.alloc(vxfw.SubSurface, max_children) catch return emptyWidget(arena);
        var row: i17 = 0;
        var child_idx: usize = 0;

        // Title
        const title: vxfw.Text = .{
            .text = "  Create Session",
            .style = style.title,
            .width_basis = .parent,
        };
        children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = title.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
        row += 2;
        child_idx += 1;

        switch (self.create_step) {
            0 => {
                // Session name input
                const label: vxfw.Text = .{ .text = "  Session name:", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = label.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 1;
                child_idx += 1;

                // Text field
                const field_surface = self.input_session_name.widget().draw(ctx.withConstraints(.{}, .{ .width = if (ctx.max.width) |w| @min(w -| 4, 50) else 50, .height = 1 })) catch return emptyWidget(arena);
                children[child_idx] = .{ .origin = .{ .row = row, .col = 4 }, .surface = field_surface };
                row += 1;
                child_idx += 1;

                // Show validation hint when the user types an invalid character
                // or submits a name that violates git branch naming rules.
                if (self.input_hint) |hint_msg| {
                    const validation_hint: vxfw.Text = .{ .text = hint_msg, .style = style.danger, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 4 }, .surface = validation_hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    child_idx += 1;
                }
                row += 1;

                const hint: vxfw.Text = .{ .text = "  enter: continue  esc: back", .style = style.dimmed, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                child_idx += 1;
            },
            1 => {
                // Base branch selection
                const label: vxfw.Text = .{ .text = "  Select base branch:", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = label.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 1;
                child_idx += 1;

                for (sr.config.start_branches.items, 0..) |branch, i| {
                    if (child_idx >= max_children - 2) break;
                    const is_sel = i == self.selected_worktree_idx;
                    const ind = if (is_sel) "  > " else "    ";
                    const s = if (is_sel) style.selected else style.normal;
                    const lbl = std.fmt.allocPrint(arena, "{s}{s}", .{ ind, branch }) catch "?";
                    const t: vxfw.Text = .{ .text = lbl, .style = s, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = t.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    row += 1;
                    child_idx += 1;
                }
                row += 1;
                if (child_idx < max_children) {
                    const hint: vxfw.Text = .{ .text = "  j/k: navigate  enter: select  esc: back", .style = style.dimmed, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    child_idx += 1;
                }
            },
            2 => {
                // Prefix selection
                const label: vxfw.Text = .{ .text = "  Select branch prefix:", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = label.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 1;
                child_idx += 1;

                for (sr.config.branch_prefixes.items, 0..) |prefix, i| {
                    if (child_idx >= max_children - 2) break;
                    const is_sel = i == self.selected_worktree_idx;
                    const ind = if (is_sel) "  > " else "    ";
                    const s = if (is_sel) style.selected else style.normal;
                    const lbl = std.fmt.allocPrint(arena, "{s}{s}", .{ ind, prefix }) catch "?";
                    const t: vxfw.Text = .{ .text = lbl, .style = s, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = t.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    row += 1;
                    child_idx += 1;
                }
                row += 1;
                if (child_idx < max_children) {
                    const hint: vxfw.Text = .{ .text = "  j/k: navigate  enter: select  esc: back", .style = style.dimmed, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    child_idx += 1;
                }
            },
            3 => {
                // Confirmation
                const name = getTextFieldContent(arena, &self.input_session_name);
                var branch_name_buf: [512]u8 = undefined;
                const branch_name = if (self.create_prefix.len > 0)
                    std.fmt.bufPrint(&branch_name_buf, "{s}/{s}", .{ self.create_prefix, name }) catch "?"
                else
                    name;

                const lines = [_]struct { label: []const u8, value: []const u8 }{
                    .{ .label = "  Repo:     ", .value = sr.name },
                    .{ .label = "  Session:  ", .value = name },
                    .{ .label = "  Branch:   ", .value = branch_name },
                    .{ .label = "  Based on: ", .value = self.create_base_branch },
                };

                for (lines) |line| {
                    if (child_idx >= max_children - 2) break;
                    const lbl = std.fmt.allocPrint(arena, "{s}{s}", .{ line.label, line.value }) catch "?";
                    const t: vxfw.Text = .{ .text = lbl, .style = style.normal, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = t.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    row += 1;
                    child_idx += 1;
                }

                row += 1;
                const confirm: vxfw.Text = .{ .text = "  Create session? (y/n/esc)", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = confirm.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                child_idx += 1;
            },
            else => {},
        }

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..child_idx],
        };
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }

    /// Renders the remove-session screen: either the worktree list or
    /// the delete confirmation prompt.
    fn drawRemoveSession(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        if (self.create_step == 10) {
            return self.drawRemoveConfirm(ctx);
        }
        return self.drawWorktreeList(ctx, "  Remove Session", "  Select session to remove:", style.danger);
    }

    /// Renders the delete-confirmation prompt with the session name
    /// highlighted in red.
    fn drawRemoveConfirm(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        const arena = ctx.arena;
        const children = arena.alloc(vxfw.SubSurface, 4) catch return emptyWidget(arena);
        const session_name = if (self.selected_worktree_idx < self.worktrees.items.len)
            self.worktrees.items[self.selected_worktree_idx]
        else
            "?";

        const title: vxfw.Text = .{ .text = "  Remove Session", .style = style.danger, .width_basis = .parent };
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = title.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };

        const name_label = std.fmt.allocPrint(arena, "  >> {s} <<", .{session_name}) catch "?";
        const name_text: vxfw.Text = .{ .text = name_label, .style = style.danger, .width_basis = .parent };
        children[1] = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = name_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };

        const prompt: vxfw.Text = .{ .text = "  Are you sure you want to delete this session? (y/n/esc)", .style = style.input_label, .width_basis = .parent };
        children[2] = .{
            .origin = .{ .row = 4, .col = 0 },
            .surface = prompt.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..3],
        };
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }

    /// Renders the remove-repository confirmation screen with the
    /// repository name and session count highlighted in red.
    fn drawRemoveRepoConfirm(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        const arena = ctx.arena;
        const children = arena.alloc(vxfw.SubSurface, 8) catch return emptyWidget(arena);
        const repo_name = self.remove_repo_name orelse "?";
        const root = self.remove_repo_root orelse "?";

        var child_idx: usize = 0;
        var row: i17 = 0;

        const title: vxfw.Text = .{ .text = "  Remove Repository", .style = style.danger, .width_basis = .parent };
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 0 },
            .surface = title.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };
        row += 2;
        child_idx += 1;

        const name_label = std.fmt.allocPrint(arena, "  >> {s} <<", .{repo_name}) catch "?";
        const name_text: vxfw.Text = .{ .text = name_label, .style = style.danger, .width_basis = .parent };
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 0 },
            .surface = name_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };
        row += 2;
        child_idx += 1;

        const path_label = std.fmt.allocPrint(arena, "  Location: {s}/{s}", .{ root, repo_name }) catch "?";
        const path_text: vxfw.Text = .{ .text = path_label, .style = style.dimmed, .width_basis = .parent };
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 0 },
            .surface = path_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };
        row += 1;
        child_idx += 1;

        const sessions_label = std.fmt.allocPrint(arena, "  Sessions to remove: {d}", .{self.remove_repo_session_count}) catch "?";
        const sessions_style: vaxis.Cell.Style = if (self.remove_repo_session_count > 0) style.danger else style.dimmed;
        const sessions_text: vxfw.Text = .{ .text = sessions_label, .style = sessions_style, .width_basis = .parent };
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 0 },
            .surface = sessions_text.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };
        row += 2;
        child_idx += 1;

        const warning: vxfw.Text = .{
            .text = "  This deletes the repo directory, ALL sessions, tmux sessions, and config.",
            .style = style.danger,
            .width_basis = .parent,
        };
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 0 },
            .surface = warning.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };
        row += 2;
        child_idx += 1;

        const prompt: vxfw.Text = .{
            .text = "  Are you sure? (y/n/esc)",
            .style = style.input_label,
            .width_basis = .parent,
        };
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 0 },
            .surface = prompt.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };
        child_idx += 1;

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..child_idx],
        };
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }

    /// Renders the fix-session worktree selection list.
    fn drawFixSession(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        return self.drawWorktreeList(ctx, "  Fix Session", "  Select session to fix:", style.input_label);
    }

    /// Shared draw helper for remove/fix session screens. Renders a
    /// titled, styled list of worktrees with a cursor indicator.
    fn drawWorktreeList(self: *TuiApp, ctx: vxfw.DrawContext, title_str: []const u8, subtitle_str: []const u8, title_style: vaxis.Cell.Style) vxfw.Widget {
        const arena = ctx.arena;
        const max_children = self.worktrees.items.len + 5;
        const children = arena.alloc(vxfw.SubSurface, max_children) catch return emptyWidget(arena);
        var row: i17 = 0;
        var child_idx: usize = 0;

        // Title
        const title: vxfw.Text = .{ .text = title_str, .style = title_style, .width_basis = .parent };
        children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = title.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
        row += 1;
        child_idx += 1;

        // Subtitle
        const subtitle: vxfw.Text = .{ .text = subtitle_str, .style = style.dimmed, .width_basis = .parent };
        children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = subtitle.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
        row += 2;
        child_idx += 1;

        // Worktree items. Each row must occupy exactly one line: the draw
        // loop advances `row` by 1 per item, so a label that soft-wraps to a
        // second line would be overdrawn by the next item and appear blank.
        // Truncate labels that exceed the content width so long session names
        // stay visible on a single row.
        const list_width: u16 = if (ctx.max.width) |w| w else 64;
        for (self.worktrees.items, 0..) |wt_name, i| {
            if (child_idx >= max_children - 2) break;
            const is_sel = i == self.selected_worktree_idx;
            const ind = if (is_sel) "  > " else "    ";
            const s = if (is_sel) style.selected else style.normal;
            const lbl = term.truncateLabel(arena, ind, wt_name, list_width) catch "?";
            const t: vxfw.Text = .{ .text = lbl, .style = s, .width_basis = .parent };
            children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = t.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
            row += 1;
            child_idx += 1;
        }

        row += 1;

        // Help
        const help: vxfw.Text = .{ .text = "  j/k: navigate  enter: select  q/esc: back", .style = style.dimmed, .width_basis = .parent };
        children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = help.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
        child_idx += 1;

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..child_idx],
        };
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }

    /// Renders the add-repo wizard. Displays the appropriate step:
    /// root selection, new root input, URL, name, branch, prefixes,
    /// or confirmation summary.
    fn drawAddRepo(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        const arena = ctx.arena;
        const max_children: usize = 25;
        const children = arena.alloc(vxfw.SubSurface, max_children) catch return emptyWidget(arena);
        var row: i17 = 0;
        var child_idx: usize = 0;

        // Title
        const title: vxfw.Text = .{ .text = "  Add Repository", .style = style.title, .width_basis = .parent };
        children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = title.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
        row += 2;
        child_idx += 1;

        const roots = self.app_config.roots.items;

        switch (self.add_repo_step) {
            0 => { // Pick root folder
                const label: vxfw.Text = .{ .text = "  Select root folder:", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = label.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 1;
                child_idx += 1;

                for (roots, 0..) |root, i| {
                    if (child_idx >= max_children - 3) break;
                    const is_sel = i == self.selected_worktree_idx;
                    const ind = if (is_sel) "  > " else "    ";
                    const s = if (is_sel) style.selected else style.normal;
                    const lbl = std.fmt.allocPrint(arena, "{s}{s}", .{ ind, root }) catch "?";
                    const t: vxfw.Text = .{ .text = lbl, .style = s, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = t.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    row += 1;
                    child_idx += 1;
                }

                // "Add new root" option
                if (child_idx < max_children - 2) {
                    row += 1;
                    const is_sel = self.selected_worktree_idx == @as(u32, @intCast(roots.len));
                    const ind = if (is_sel) "  > " else "    ";
                    const s: vaxis.Cell.Style = if (is_sel) style.success else .{ .fg = colors.green };
                    const lbl = std.fmt.allocPrint(arena, "{s}[a] Add new root folder", .{ind}) catch "?";
                    const t: vxfw.Text = .{ .text = lbl, .style = s, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = t.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    row += 2;
                    child_idx += 1;
                }

                // Help
                if (child_idx < max_children) {
                    const hint: vxfw.Text = .{ .text = "  j/k: navigate  enter: select  a: add root  q/esc: back", .style = style.dimmed, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    child_idx += 1;
                }
            },
            6 => { // New root folder input
                const label: vxfw.Text = .{ .text = "  New root folder path:", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = label.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 1;
                child_idx += 1;

                const field_w: u16 = if (ctx.max.width) |w| @min(w -| 6, 56) else 56;
                const field_surface = self.add_repo_new_root.widget().draw(ctx.withConstraints(.{}, .{ .width = field_w, .height = 1 })) catch return emptyWidget(arena);
                children[child_idx] = .{ .origin = .{ .row = row, .col = 4 }, .surface = field_surface };
                row += 2;
                child_idx += 1;

                const hint: vxfw.Text = .{ .text = "  e.g. ~/Developer/Git  enter: continue  esc: back", .style = style.dimmed, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                child_idx += 1;
            },
            1 => { // Clone URL
                const label: vxfw.Text = .{ .text = "  Git clone URL:", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = label.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 1;
                child_idx += 1;

                const field_w: u16 = if (ctx.max.width) |w| @min(w -| 6, 56) else 56;
                const field_surface = self.add_repo_url.widget().draw(ctx.withConstraints(.{}, .{ .width = field_w, .height = 1 })) catch return emptyWidget(arena);
                children[child_idx] = .{ .origin = .{ .row = row, .col = 4 }, .surface = field_surface };
                row += 2;
                child_idx += 1;

                const hint: vxfw.Text = .{ .text = "  enter: continue  esc: back", .style = style.dimmed, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                child_idx += 1;
            },
            2 => { // Repository name
                const url_text = getTextFieldContent(arena, &self.add_repo_url);
                const url_line = std.fmt.allocPrint(arena, "  URL: {s}", .{url_text}) catch "?";
                const url_disp: vxfw.Text = .{ .text = url_line, .style = style.dimmed, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = url_disp.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 2;
                child_idx += 1;

                const label: vxfw.Text = .{ .text = "  Repository name:", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = label.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 1;
                child_idx += 1;

                const field_w: u16 = if (ctx.max.width) |w| @min(w -| 6, 50) else 50;
                const field_surface = self.add_repo_name.widget().draw(ctx.withConstraints(.{}, .{ .width = field_w, .height = 1 })) catch return emptyWidget(arena);
                children[child_idx] = .{ .origin = .{ .row = row, .col = 4 }, .surface = field_surface };
                row += 2;
                child_idx += 1;

                const hint: vxfw.Text = .{ .text = "  enter: continue  esc: back", .style = style.dimmed, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                child_idx += 1;
            },
            3 => { // Default branch
                const label: vxfw.Text = .{ .text = "  Default branch:", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = label.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 1;
                child_idx += 1;

                const field_w: u16 = if (ctx.max.width) |w| @min(w -| 6, 50) else 50;
                const field_surface = self.add_repo_branch.widget().draw(ctx.withConstraints(.{}, .{ .width = field_w, .height = 1 })) catch return emptyWidget(arena);
                children[child_idx] = .{ .origin = .{ .row = row, .col = 4 }, .surface = field_surface };
                row += 2;
                child_idx += 1;

                const hint: vxfw.Text = .{ .text = "  enter: continue  esc: back", .style = style.dimmed, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                child_idx += 1;
            },
            4 => { // Branch prefixes
                const label: vxfw.Text = .{ .text = "  Branch prefixes (comma-separated):", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = label.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                row += 1;
                child_idx += 1;

                const field_w: u16 = if (ctx.max.width) |w| @min(w -| 6, 50) else 50;
                const field_surface = self.add_repo_prefixes.widget().draw(ctx.withConstraints(.{}, .{ .width = field_w, .height = 1 })) catch return emptyWidget(arena);
                children[child_idx] = .{ .origin = .{ .row = row, .col = 4 }, .surface = field_surface };
                row += 2;
                child_idx += 1;

                const hint: vxfw.Text = .{ .text = "  e.g. feature,bugfix  enter: continue  esc: back", .style = style.dimmed, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                child_idx += 1;
            },
            5 => { // Confirmation
                const name_text = getTextFieldContent(arena, &self.add_repo_name);
                const url_text = getTextFieldContent(arena, &self.add_repo_url);
                const branch_text = getTextFieldContent(arena, &self.add_repo_branch);
                const prefixes_text = getTextFieldContent(arena, &self.add_repo_prefixes);

                const lines = [_]struct { label: []const u8, value: []const u8 }{
                    .{ .label = "  Folder:     ", .value = std.fmt.allocPrint(arena, "{s}/{s}", .{ self.add_repo_root, name_text }) catch "?" },
                    .{ .label = "  Clone from: ", .value = url_text },
                    .{ .label = "  Bare repo:  ", .value = std.fmt.allocPrint(arena, "{s}.git", .{name_text}) catch "?" },
                    .{ .label = "  Branch:     ", .value = branch_text },
                    .{ .label = "  Prefixes:   ", .value = prefixes_text },
                };

                for (lines) |line| {
                    if (child_idx >= max_children - 2) break;
                    const lbl = std.fmt.allocPrint(arena, "{s}{s}", .{ line.label, line.value }) catch "?";
                    const t: vxfw.Text = .{ .text = lbl, .style = style.normal, .width_basis = .parent };
                    children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = t.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                    row += 1;
                    child_idx += 1;
                }

                row += 1;
                const confirm: vxfw.Text = .{ .text = "  Continue? (y/n/esc)", .style = style.input_label, .width_basis = .parent };
                children[child_idx] = .{ .origin = .{ .row = row, .col = 0 }, .surface = confirm.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena) };
                child_idx += 1;
            },
            else => {},
        }

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..child_idx],
        };
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }

    /// Renders the working/spinner screen with an animated braille
    /// spinner and live progress output from the background operation.
    fn drawWorking(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        const arena = ctx.arena;
        const max_output_lines: usize = 8;
        const max_children: usize = 3 + max_output_lines;
        const children = arena.alloc(vxfw.SubSurface, max_children) catch return emptyWidget(arena);
        var child_idx: usize = 0;
        var row: i17 = 1;

        const container_width = ctx.max.size().width;

        // Spinner + Message on same line, centred horizontally
        const spinner_frames = [_][]const u8{ "⣶", "⣧", "⣏", "⡟", "⠿", "⢻", "⣹", "⣼" };
        const frame_idx = self.spinner.frame % spinner_frames.len;
        const spinner_label = std.fmt.allocPrint(arena, "{s} {s}", .{ spinner_frames[frame_idx], self.working_message }) catch "?";
        const label_len: u16 = @intCast(@min(spinner_label.len, container_width));
        const spinner_col: i17 = @intCast((@as(u17, container_width) -| label_len) / 2);
        const msg: vxfw.Text = .{ .text = spinner_label, .style = style.title, .width_basis = .parent };
        children[child_idx] = .{
            .origin = .{ .row = row, .col = spinner_col },
            .surface = msg.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };
        child_idx += 1;
        row += 2;

        // Progress output lines (below the spinner), left-aligned at
        // the same column as the spinner label for visual consistency.
        // Copy line data under the lock, then release before drawing
        // to avoid holding the mutex during vxfw rendering.
        if (self.worker_progress) |progress| {
            const line_copies = blk: {
                progress.mutex.lockUncancelable(progress.io);
                defer progress.mutex.unlock(progress.io);
                const total = progress.lines.items.len;
                if (total == 0) break :blk @as([][]const u8, &.{});
                const start_idx = if (total > max_output_lines) total - max_output_lines else 0;
                const count = total - start_idx;
                const copies = arena.alloc([]const u8, count) catch break :blk @as([][]const u8, &.{});
                for (0..count) |ci| {
                    copies[ci] = std.fmt.allocPrint(arena, "{s}", .{progress.lines.items[start_idx + ci]}) catch "?";
                }
                break :blk copies;
            };

            for (line_copies) |line_text| {
                if (child_idx >= max_children) break;
                const t: vxfw.Text = .{ .text = line_text, .style = style.dimmed, .width_basis = .parent };
                children[child_idx] = .{
                    .origin = .{ .row = row, .col = spinner_col },
                    .surface = t.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
                };
                row += 1;
                child_idx += 1;
            }
        }

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..child_idx],
        };
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }

    /// Renders the "Attach to session?" prompt shown after creating
    /// or fixing a session.
    fn drawAttachConfirm(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        const arena = ctx.arena;
        const children = arena.alloc(vxfw.SubSurface, 4) catch return emptyWidget(arena);

        const icon = if (self.status_is_error) "  x " else "  * ";
        const msg_style = if (self.status_is_error) style.danger else style.success;
        const label = std.fmt.allocPrint(arena, "{s}{s}", .{ icon, self.status_message }) catch "?";

        const msg: vxfw.Text = .{ .text = label, .style = msg_style, .width_basis = .parent };
        children[0] = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = msg.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };

        const prompt: vxfw.Text = .{ .text = "  Attach to session? (y/n)", .style = style.input_label, .width_basis = .parent };
        children[1] = .{
            .origin = .{ .row = 4, .col = 0 },
            .surface = prompt.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };

        const hint: vxfw.Text = .{ .text = "  y: attach and quit  n/esc: quit without attaching", .style = style.dimmed, .width_basis = .parent };
        children[2] = .{
            .origin = .{ .row = 6, .col = 0 },
            .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..3],
        };
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }

    /// Renders a success or error message dismissed by any key press.
    /// If `quit_on_dismiss` is set, the app exits on dismiss.
    fn drawMessage(self: *TuiApp, ctx: vxfw.DrawContext) vxfw.Widget {
        const arena = ctx.arena;
        const children = arena.alloc(vxfw.SubSurface, 3) catch return emptyWidget(arena);

        const icon = if (self.status_is_error) "  x " else "  * ";
        const msg_style = if (self.status_is_error) style.danger else style.success;
        const label = std.fmt.allocPrint(arena, "{s}{s}", .{ icon, self.status_message }) catch "?";

        const msg: vxfw.Text = .{ .text = label, .style = msg_style, .width_basis = .parent };
        children[0] = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = msg.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };

        const hint: vxfw.Text = .{ .text = "  Press any key to continue...", .style = style.dimmed, .width_basis = .parent };
        children[1] = .{
            .origin = .{ .row = 4, .col = 0 },
            .surface = hint.draw(ctx.withConstraints(.{}, ctx.max)) catch return emptyWidget(arena),
        };

        const surface = vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children[0..2],
        };
        const wrapper = arena.create(SurfaceHolder) catch return emptyWidget(arena);
        wrapper.* = .{ .surface = surface, .w = self.widget() };
        return wrapper.widget();
    }
};

// ── Helper: SurfaceHolder ────────────────────────────────────────────────

/// Thin wrapper that holds a pre-built `vxfw.Surface` and returns it
/// verbatim from its draw function. Used to bridge the gap between
/// draw methods that build surfaces manually and the widget interface
/// that `vxfw.App` expects.
const SurfaceHolder = struct {
    surface: vxfw.Surface,
    w: vxfw.Widget,

    /// Returns a type-erased widget that draws `self.surface`.
    fn widget(self: *SurfaceHolder) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawFn,
        };
    }

    /// vxfw draw trampoline -- ignores constraints and returns the
    /// pre-built surface.
    fn drawFn(ptr: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *SurfaceHolder = @ptrCast(@alignCast(ptr));
        return self.surface;
    }
};

/// Get the text content from a TextField by concatenating the gap buffer halves.
fn getTextFieldContent(arena: std.mem.Allocator, field: *vxfw.TextField) []const u8 {
    const first = field.buf.firstHalf();
    const second = field.buf.secondHalf();
    if (second.len == 0) return first;
    if (first.len == 0) return second;
    const buf = arena.alloc(u8, first.len + second.len) catch return first;
    @memcpy(buf[0..first.len], first);
    @memcpy(buf[first.len..], second);
    return buf;
}

/// Returns a zero-sized widget with no content. Used as a fallback
/// when arena allocation fails inside a draw method.
fn emptyWidget(arena: std.mem.Allocator) vxfw.Widget {
    const holder = arena.create(SurfaceHolder) catch unreachable;
    holder.* = .{
        .surface = .{
            .size = .{ .width = 0, .height = 0 },
            .widget = undefined,
            .buffer = &.{},
            .children = &.{},
        },
        .w = undefined,
    };
    return holder.widget();
}

// ── Public entry point ───────────────────────────────────────────────────

/// Public entry point for the TUI. Initialises the vxfw application,
/// enters the alternate screen, runs the event loop until the user
/// quits, and restores the terminal on exit. Raw `term.print` /
/// `term.eprint` output is suppressed while the TUI is active.
///
/// When `cli_args` contains a `repository` name the matching repo is
/// opened automatically. When it also contains an `operation`, the TUI
/// starts at the corresponding screen with any supplied `session`,
/// `branch`, and `prefix` values pre-filled, skipping wizard steps that
/// are already resolved.
pub fn runTui(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, app_config: config.AppConfig, cli_args: CliArgs) !void {
    const tui_app = try TuiApp.init(allocator, io, env, app_config);
    defer tui_app.deinit();

    // Pre-select repository when provided.
    if (cli_args.repository) |repo_name| {
        var found = false;
        for (tui_app.repo_entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, repo_name)) {
                try tui_app.openRepo(entry);
                found = true;
                break;
            }
        }
        if (!found) {
            term.eprint(io, "Error: repository '{s}' not found.\n", .{repo_name});
            std.process.exit(1);
        }

        // Apply operation-specific pre-selection when a repo was opened.
        if (cli_args.operation) |op| {
            const sr = tui_app.selected_repo orelse unreachable;
            switch (op) {
                .create => {
                    tui_app.screen = .create_session;
                    tui_app.create_step = 0;
                    tui_app.input_session_name.clearRetainingCapacity();

                    // Resolve branch: CLI arg takes priority; fall back to
                    // auto-select when the config has at most one option.
                    const branch_provided = cli_args.branch != null;
                    const branch_auto = sr.config.start_branches.items.len <= 1;
                    if (branch_provided) {
                        tui_app.create_base_branch = cli_args.branch.?;
                    } else if (branch_auto) {
                        tui_app.create_base_branch = if (sr.config.start_branches.items.len == 1)
                            sr.config.start_branches.items[0]
                        else
                            "main";
                    }
                    const branch_resolved = branch_provided or branch_auto;

                    // Resolve prefix similarly.
                    const prefix_provided = cli_args.prefix != null;
                    const prefix_auto = sr.config.branch_prefixes.items.len <= 1;
                    if (prefix_provided) {
                        tui_app.create_prefix = cli_args.prefix.?;
                    } else if (prefix_auto) {
                        tui_app.create_prefix = if (sr.config.branch_prefixes.items.len == 1)
                            sr.config.branch_prefixes.items[0]
                        else
                            "";
                    }
                    const prefix_resolved = prefix_provided or prefix_auto;

                    // Pre-fill session name and advance past already-resolved steps.
                    if (cli_args.session) |sess| {
                        try tui_app.input_session_name.insertSliceAtCursor(sess);
                        if (branch_resolved) {
                            tui_app.create_step = if (prefix_resolved) 3 else 2;
                        } else {
                            // Reset the list cursor before the branch-selection step;
                            // the worktree and branch lists share this index.
                            tui_app.selected_worktree_idx = 0;
                            tui_app.create_step = 1;
                        }
                    }
                    // When no session name is provided we stay at step 0; the
                    // branch/prefix pre-selections above will be used by the
                    // step-advancement logic in handleCreateSessionKey.
                },

                .remove => {
                    try tui_app.refreshWorktrees();
                    if (tui_app.worktrees.items.len == 0) {
                        tui_app.setMessage("No sessions to remove.", true);
                        tui_app.screen = .message;
                    } else {
                        tui_app.screen = .remove_session;
                        // Pre-select session by name when provided.
                        if (cli_args.session) |sess| {
                            for (tui_app.worktrees.items, 0..) |wt, idx| {
                                if (std.mem.eql(u8, wt, sess)) {
                                    tui_app.selected_worktree_idx = @intCast(idx);
                                    break;
                                }
                            }
                        }
                    }
                },

                .fix => {
                    try tui_app.refreshWorktrees();
                    if (tui_app.worktrees.items.len == 0) {
                        tui_app.setMessage("No sessions to fix.", true);
                        tui_app.screen = .message;
                    } else {
                        tui_app.screen = .fix_session;
                        if (cli_args.session) |sess| {
                            for (tui_app.worktrees.items, 0..) |wt, idx| {
                                if (std.mem.eql(u8, wt, sess)) {
                                    tui_app.selected_worktree_idx = @intCast(idx);
                                    break;
                                }
                            }
                        }
                    }
                },
            }
        }
    }

    // Suppress raw term.print/eprint while TUI owns the alternate screen
    term.setQuiet(true);
    defer term.setQuiet(false);

    // Buffer for the TTY writer used by vaxis to render frames.
    const tty_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(tty_buffer);

    var app = try vxfw.App.init(io, allocator, env, tty_buffer);
    defer app.deinit();

    try app.run(tui_app.widget(), .{});
}
