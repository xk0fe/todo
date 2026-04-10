const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const model = @import("model.zig");
const paths = @import("storage/paths.zig");
const space_store = @import("storage/space_store.zig");
const project_store = @import("storage/project_store.zig");
const task_store = @import("storage/task_store.zig");
const config_store = @import("storage/config_store.zig");
const push_queue = @import("storage/push_queue.zig");
const sync_engine = @import("integrations/sync.zig");
const github_oauth = @import("integrations/github_oauth.zig");

// ── Comptime percentage strings (0–100) ──────────────────────────────────────
// Vaxis stores char.grapheme as a raw pointer; bufPrint'd stack buffers become
// dangling once the render frame returns and vx.render() runs.  These compile-
// time literals live in the binary's rodata and are always valid.
const pct_strs: [101][]const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var arr: [101][]const u8 = undefined;
    for (0..101) |i| arr[i] = std.fmt.comptimePrint(" {d}%", .{i});
    break :blk arr;
};

// ── Colour palette ────────────────────────────────────────────────────────────

const col_active_border  = vaxis.Color{ .rgb = [3]u8{ 99, 179, 237 } };
const col_inactive_border= vaxis.Color{ .rgb = [3]u8{ 70,  70,  70 } };
const col_selected_fg    = vaxis.Color{ .rgb = [3]u8{ 255, 215,   0 } };
const col_selected_bg    = vaxis.Color{ .rgb = [3]u8{  35,  38,  55 } };
const col_normal_fg      = vaxis.Color{ .rgb = [3]u8{ 200, 200, 200 } };
const col_dim_fg         = vaxis.Color{ .rgb = [3]u8{  85,  85,  85 } };
const col_hint_key       = vaxis.Color{ .rgb = [3]u8{  99, 179, 237 } };
const col_hint_text      = vaxis.Color{ .rgb = [3]u8{ 120, 120, 120 } };
const col_input_prompt   = vaxis.Color{ .rgb = [3]u8{  99, 179, 237 } };
const col_todo_fg        = vaxis.Color{ .rgb = [3]u8{ 200, 200, 200 } };
const col_in_progress_fg = vaxis.Color{ .rgb = [3]u8{ 255, 200,  60 } };
const col_in_review_fg   = vaxis.Color{ .rgb = [3]u8{ 180, 120, 240 } };
const col_done_fg        = vaxis.Color{ .rgb = [3]u8{  75,  75,  75 } };
const col_progress_fill  = vaxis.Color{ .rgb = [3]u8{  60, 140,  60 } };
const col_progress_bg    = vaxis.Color{ .rgb = [3]u8{  40,  40,  40 } };
const col_low            = vaxis.Color{ .rgb = [3]u8{  90, 200, 110 } };
const col_medium         = vaxis.Color{ .rgb = [3]u8{ 255, 175,  50 } };
const col_high           = vaxis.Color{ .rgb = [3]u8{ 240,  90,  90 } };
const col_urgent         = vaxis.Color{ .rgb = [3]u8{ 220,  30,  80 } };
const col_overlay_bg     = vaxis.Color{ .rgb = [3]u8{  16,  18,  28 } };
const col_section_header = vaxis.Color{ .rgb = [3]u8{ 130, 130, 130 } };
const col_todo_badge     = vaxis.Color{ .rgb = [3]u8{ 100, 100, 170 } };
const col_warning        = vaxis.Color{ .rgb = [3]u8{ 240,  90,  90 } };

fn itemColorToVaxis(c: model.ItemColor) vaxis.Color {
    return switch (c) {
        .default => col_normal_fg,
        .red     => vaxis.Color{ .rgb = [3]u8{ 220,  70,  70 } },
        .green   => vaxis.Color{ .rgb = [3]u8{  70, 190,  90 } },
        .blue    => vaxis.Color{ .rgb = [3]u8{  99, 179, 237 } },
        .orange  => vaxis.Color{ .rgb = [3]u8{ 255, 150,  50 } },
        .purple  => vaxis.Color{ .rgb = [3]u8{ 180, 120, 240 } },
        .cyan    => vaxis.Color{ .rgb = [3]u8{  70, 200, 200 } },
        .yellow  => vaxis.Color{ .rgb = [3]u8{ 240, 200,  50 } },
    };
}

// ── OAuth ─────────────────────────────────────────────────────────────────────

/// Posted by the background OAuth poll thread when it finishes.
const OAuthEvent = struct {
    token:   ?[]const u8 = null, // heap-owned by this event; save or free
    err_msg: ?[]const u8 = null, // heap-owned; mutually exclusive with token
};

/// Context passed to the background OAuth polling thread.
const OAuthPollCtx = struct {
    allocator:     std.mem.Allocator,
    client_id:     [128]u8,
    client_id_len: usize,
    device_code:   [512]u8,
    device_code_len: usize,
    interval:      i64,
    cancel:        std.atomic.Value(bool),
    loop:          *vaxis.Loop(Event),
};

fn oauthPollThread(ctx: *OAuthPollCtx) void {
    const client_id   = ctx.client_id[0..ctx.client_id_len];
    const device_code = ctx.device_code[0..ctx.device_code_len];
    var   interval_ns: u64 = @intCast(@max(5, ctx.interval) * std.time.ns_per_s);

    while (!ctx.cancel.load(.acquire)) {
        std.Thread.sleep(interval_ns);
        if (ctx.cancel.load(.acquire)) return;

        const poll = github_oauth.pollToken(ctx.allocator, client_id, device_code) catch continue;
        switch (poll) {
            .token     => |t| {
                ctx.loop.postEvent(.{ .oauth_result = .{ .token = t } });
                return;
            },
            .slow_down => interval_ns += 5 * std.time.ns_per_s,
            .expired   => {
                const msg = ctx.allocator.dupe(u8, "Device code expired. Try again.") catch &[_]u8{};
                ctx.loop.postEvent(.{ .oauth_result = .{ .err_msg = msg } });
                return;
            },
            .denied    => {
                const msg = ctx.allocator.dupe(u8, "Access denied.") catch &[_]u8{};
                ctx.loop.postEvent(.{ .oauth_result = .{ .err_msg = msg } });
                return;
            },
            .err       => |msg| {
                ctx.loop.postEvent(.{ .oauth_result = .{ .err_msg = msg } });
                return;
            },
            .pending   => {},
        }
    }
}

fn openBrowser(allocator: std.mem.Allocator, url: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos              => &.{ "open", url },
        .linux, .freebsd    => &.{ "xdg-open", url },
        .windows            => &.{ "cmd.exe", "/c", "start", url },
        else                => return,
    };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior  = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch {};
}

// ── Event ─────────────────────────────────────────────────────────────────────

const Event = union(enum) {
    key_press:    vaxis.Key,
    winsize:      vaxis.Winsize,
    oauth_result: OAuthEvent,
};

// ── App modes ─────────────────────────────────────────────────────────────────

const Mode = enum {
    normal,
    input,                // adding a space / project / task (or subtask/description)
    settings,             // settings overlay open
    settings_confirm,     // hard-reset confirmation dialog
    auth_overlay,         // service authentication input overlay
    onboarding,           // first-launch wizard
    task_detail,          // task detail overlay
    task_confirm_delete,  // confirm before deleting a space/project/task
    color_picker,         // colour picker overlay for spaces/projects
};

const Panel = enum { spaces, projects, tasks };
const InputTarget = enum { space, project, task, subtask, description, task_title };
const AuthMode = enum { choose, device_waiting, token_input };

// ── Settings entries ──────────────────────────────────────────────────────────

const EntryKind = enum {
    section, // non-navigable heading
    action,  // executable item
    toggle,  // boolean toggle (uses app state)
    todo,    // placeholder — not yet implemented
};

const SettingsId = enum { hard_reset, show_progress, alt_priority, task_color_grading, compact_mode, task_sort, linear, github, trello };

const SettingsEntry = struct {
    kind:  EntryKind,
    id:    SettingsId = .hard_reset, // only meaningful for action/toggle/todo
    label: []const u8,
    sub:   []const u8 = "",
};

const settings_entries = [_]SettingsEntry{
    .{ .kind = .section, .label = "General" },
    .{ .kind = .action,  .id = .hard_reset,       .label = "Hard Reset",
       .sub  = "permanently delete all spaces, projects and tasks" },
    .{ .kind = .section, .label = "Display" },
    .{ .kind = .toggle,  .id = .show_progress,    .label = "Show project progress",
       .sub  = "display completion % next to each project" },
    .{ .kind = .toggle,  .id = .alt_priority,     .label = "Alternative priority style",
       .sub  = "show ^ ^^ ^^^ ^^^^ instead of [L][M][H][U]" },
    .{ .kind = .toggle,  .id = .task_color_grading,.label = "Task colour grading",
       .sub  = "tint task row by priority level" },
    .{ .kind = .toggle,  .id = .compact_mode,     .label = "Compact mode",
       .sub  = "expand the active panel to fill the terminal width" },
    .{ .kind = .section, .label = "Tasks" },
    .{ .kind = .action,  .id = .task_sort,        .label = "Sort order",
       .sub  = "cycle: Default / Priority / Status" },
    .{ .kind = .section, .label = "Integrations" },
    .{ .kind = .todo,    .id = .linear,            .label = "Linear",
       .sub  = "sync with Linear — run: todo sync linear <space> <project>" },
    .{ .kind = .todo,    .id = .github,            .label = "GitHub Issues",
       .sub  = "sync with GitHub — run: todo sync github <space> <project>" },
    .{ .kind = .todo,    .id = .trello,            .label = "Trello",
       .sub  = "sync with Trello — run: todo sync trello <space> <project>" },
};

// First selectable index (skips section headers)
const settings_initial_idx: usize = blk: {
    for (settings_entries, 0..) |e, i| {
        if (e.kind != .section) break :blk i;
    }
    break :blk 0;
};

fn isSelectable(e: SettingsEntry) bool {
    return e.kind != .section;
}

fn nextSelectableIdx(cur: usize) usize {
    var i = cur + 1;
    while (i < settings_entries.len) : (i += 1) {
        if (isSelectable(settings_entries[i])) return i;
    }
    return cur;
}

fn prevSelectableIdx(cur: usize) usize {
    if (cur == 0) return cur;
    var i = cur - 1;
    while (true) {
        if (isSelectable(settings_entries[i])) return i;
        if (i == 0) break;
        i -= 1;
    }
    return cur;
}

// ── TaskSort ──────────────────────────────────────────────────────────────────

const TaskSort = enum { by_id, by_priority_desc, by_status };

// ── Sort helpers ──────────────────────────────────────────────────────────────

fn taskLessThanPriority(_: void, a: model.Task, b: model.Task) bool {
    return @intFromEnum(a.priority) > @intFromEnum(b.priority);
}
fn taskLessThanStatus(_: void, a: model.Task, b: model.Task) bool {
    return @intFromEnum(a.status) < @intFromEnum(b.status);
}

// ── App state ─────────────────────────────────────────────────────────────────

const App = struct {
    allocator: std.mem.Allocator,
    root_dir:  std.fs.Dir,

    // main panel state
    active:      Panel = .spaces,
    spaces:      [][]const u8 = &.{},
    space_idx:   usize = 0,
    projects:    [][]const u8 = &.{},
    project_idx: usize = 0,
    tasks:       []model.Task = &.{},
    task_idx:    usize = 0,

    // project progress cache (parallel to projects slice)
    project_progress: []u32 = &.{},

    // input (add mode in main panels)
    mode:         Mode = .normal,
    input_target: InputTarget = .space,
    input_buf:    [256]u8 = undefined,
    input_len:    usize = 0,
    is_refresh_needed: bool = false, // force full redraw on next frame

    // settings overlay
    settings_idx:       usize    = settings_initial_idx,
    show_progress:      bool     = true,
    alt_priority:       bool     = false,
    task_color_grading: bool     = false,
    compact_mode:       bool     = false,
    task_sort:          TaskSort = .by_id,

    // color arrays
    space_colors:   []model.ItemColor = &.{},
    project_colors: []model.ItemColor = &.{},

    // task detail overlay
    detail_subtask_idx: usize = 0,

    // colour picker overlay
    color_picker_idx:   usize = 0,
    color_picker_panel: Panel = .spaces,

    // delete confirmation
    confirm_delete_panel: Panel = .tasks,

    // onboarding wizard
    ob_step:      u2 = 0,
    ob_space_buf: [64]u8 = undefined,
    ob_space_len: usize = 0,
    ob_proj_buf:  [64]u8 = undefined,
    ob_proj_len:  usize = 0,

    // auth overlay
    auth_service:  SettingsId = .linear,
    auth_mode:     AuthMode = .choose,
    auth_choose_idx: u1 = 0, // 0 = browser/device, 1 = paste token
    // token input
    auth_buf:      [512]u8 = undefined,
    auth_len:      usize = 0,
    // OAuth device flow display
    oauth_user_code_buf: [16]u8 = undefined,
    oauth_user_code_len: usize = 0,
    oauth_uri_buf:       [128]u8 = undefined,
    oauth_uri_len:       usize = 0,
    // background polling thread
    oauth_poll_ctx:    ?*OAuthPollCtx = null,
    oauth_poll_thread: ?std.Thread = null,

    // sync notification bar (shown at bottom until next keypress)
    notify_buf: [128]u8 = undefined,
    notify_len: usize = 0,

    // ── lifecycle ─────────────────────────────────────────────────────────────

    fn init(allocator: std.mem.Allocator) !App {
        var app = App{
            .allocator = allocator,
            .root_dir  = try paths.openOrCreateTodoRoot(allocator),
        };
        const cfg = config_store.loadGlobalConfig(allocator, app.root_dir) catch null;
        if (cfg) |c| {
            defer c.deinit(allocator);
            app.compact_mode = c.compact_mode;
        }
        app.reloadSpaces();
        if (app.spaces.len == 0) {
            app.mode    = .onboarding;
            app.ob_step = 0;
        }
        return app;
    }

    fn deinit(self: *App) void {
        self.stopOAuthPoll();
        self.freeSpaces();
        self.freeProjects();
        self.freeTasks();
        self.freeSpaceColors();
        self.freeProjectColors();
        self.root_dir.close();
    }

    fn stopOAuthPoll(self: *App) void {
        if (self.oauth_poll_ctx) |ctx| {
            ctx.cancel.store(true, .release);
        }
        if (self.oauth_poll_thread) |t| {
            t.detach();
            self.oauth_poll_thread = null;
        }
        // ctx leaks intentionally — safe for a CLI tool (single instance, small)
        self.oauth_poll_ctx = null;
    }

    fn startDeviceFlow(self: *App, loop: *vaxis.Loop(Event)) void {
        var cfg = config_store.loadGlobalConfig(self.allocator, self.root_dir) catch return;
        defer cfg.deinit(self.allocator);

        const client_id = cfg.github_oauth_client_id;
        if (client_id.len == 0) {
            self.setNotify("Set github_oauth_client_id in config first (todo sync config --github-client-id ID)", .{});
            self.auth_mode = .choose;
            self.requestRefresh();
            return;
        }

        const dc = github_oauth.requestDeviceCode(self.allocator, client_id) catch |err| {
            self.setNotify("Failed to start device flow: {s}", .{@errorName(err)});
            self.auth_mode = .choose;
            self.requestRefresh();
            return;
        };
        defer dc.deinit(self.allocator);

        // Copy display values
        const uc_len = @min(dc.user_code.len, self.oauth_user_code_buf.len);
        @memcpy(self.oauth_user_code_buf[0..uc_len], dc.user_code[0..uc_len]);
        self.oauth_user_code_len = uc_len;

        const uri_len = @min(dc.verification_uri.len, self.oauth_uri_buf.len);
        @memcpy(self.oauth_uri_buf[0..uri_len], dc.verification_uri[0..uri_len]);
        self.oauth_uri_len = uri_len;

        // Open the browser
        openBrowser(self.allocator, dc.verification_uri);

        // Start background poll
        const ctx = self.allocator.create(OAuthPollCtx) catch return;
        ctx.cancel = std.atomic.Value(bool).init(false);
        ctx.allocator = self.allocator;
        ctx.interval = dc.interval;
        ctx.loop = loop;

        const cid_len = @min(client_id.len, ctx.client_id.len);
        @memcpy(ctx.client_id[0..cid_len], client_id[0..cid_len]);
        ctx.client_id_len = cid_len;

        const dc_len = @min(dc.device_code.len, ctx.device_code.len);
        @memcpy(ctx.device_code[0..dc_len], dc.device_code[0..dc_len]);
        ctx.device_code_len = dc_len;

        self.stopOAuthPoll();
        self.oauth_poll_ctx = ctx;
        self.oauth_poll_thread = std.Thread.spawn(.{}, oauthPollThread, .{ctx}) catch {
            self.allocator.destroy(ctx);
            self.oauth_poll_ctx = null;
            self.setNotify("Failed to start poll thread", .{});
            self.auth_mode = .choose;
            self.requestRefresh();
            return;
        };

        self.auth_mode = .device_waiting;
        self.requestRefresh();
    }

    fn freeSpaceColors(self: *App) void {
        if (self.space_colors.len > 0) self.allocator.free(self.space_colors);
        self.space_colors = &.{};
    }
    fn freeProjectColors(self: *App) void {
        if (self.project_colors.len > 0) self.allocator.free(self.project_colors);
        self.project_colors = &.{};
    }

    fn freeProjectProgress(self: *App) void {
        if (self.project_progress.len > 0) self.allocator.free(self.project_progress);
        self.project_progress = &.{};
    }

    // ── data loaders ──────────────────────────────────────────────────────────

    fn freeSpaces(self: *App) void {
        for (self.spaces) |s| self.allocator.free(s);
        if (self.spaces.len > 0) self.allocator.free(self.spaces);
        self.spaces = &.{};
    }
    fn freeProjects(self: *App) void {
        for (self.projects) |p| self.allocator.free(p);
        if (self.projects.len > 0) self.allocator.free(self.projects);
        self.projects = &.{};
        self.freeProjectProgress();
    }
    fn freeTasks(self: *App) void {
        for (self.tasks) |t| t.deinit(self.allocator);
        if (self.tasks.len > 0) self.allocator.free(self.tasks);
        self.tasks = &.{};
    }

    fn requestRefresh(self: *App) void {
        self.is_refresh_needed = true;
    }

    fn reloadSpaces(self: *App) void {
        self.freeSpaces();
        self.spaces = space_store.list(self.allocator, self.root_dir) catch &.{};
        if (self.spaces.len > 0 and self.space_idx >= self.spaces.len)
            self.space_idx = self.spaces.len - 1;
        // load space colors
        self.freeSpaceColors();
        if (self.spaces.len > 0) {
            self.space_colors = self.allocator.alloc(model.ItemColor, self.spaces.len) catch &.{};
            for (self.spaces, 0..) |sp, i|
                self.space_colors[i] = space_store.getColor(self.root_dir, sp);
        }
        self.reloadProjects();
    }
    fn reloadProjects(self: *App) void {
        self.freeProjects();
        if (self.spaces.len == 0) { self.reloadTasks(); return; }
        self.projects = project_store.list(
            self.allocator, self.root_dir, self.spaces[self.space_idx],
        ) catch &.{};
        if (self.projects.len > 0 and self.project_idx >= self.projects.len)
            self.project_idx = self.projects.len - 1;
        // load project colors
        self.freeProjectColors();
        if (self.projects.len > 0) {
            const sp = self.spaces[self.space_idx];
            self.project_colors = self.allocator.alloc(model.ItemColor, self.projects.len) catch &.{};
            for (self.projects, 0..) |pj, i|
                self.project_colors[i] = project_store.getColor(self.allocator, self.root_dir, sp, pj);
        }
        self.recalcProgress();
        self.reloadTasks();
    }

    fn recalcProgress(self: *App) void {
        self.freeProjectProgress();
        if (self.projects.len == 0 or self.spaces.len == 0) return;
        const sp = self.spaces[self.space_idx];
        self.project_progress = self.allocator.alloc(u32, self.projects.len) catch return;
        for (self.projects, 0..) |pj, i| {
            self.project_progress[i] = task_store.projectProgress(
                self.allocator, self.root_dir, sp, pj,
            );
        }
    }
    fn reloadTasks(self: *App) void {
        self.freeTasks();
        if (self.spaces.len == 0 or self.projects.len == 0) return;
        self.tasks = task_store.list(
            self.allocator, self.root_dir,
            self.spaces[self.space_idx], self.projects[self.project_idx], .all,
        ) catch &.{};
        switch (self.task_sort) {
            .by_id => {},
            .by_priority_desc => std.mem.sort(model.Task, self.tasks, {}, taskLessThanPriority),
            .by_status        => std.mem.sort(model.Task, self.tasks, {}, taskLessThanStatus),
        }
        if (self.tasks.len > 0 and self.task_idx >= self.tasks.len)
            self.task_idx = self.tasks.len - 1;
        self.recalcProgress();
    }

    fn currentSpace(self: *const App) ?[]const u8 {
        return if (self.spaces.len > 0) self.spaces[self.space_idx] else null;
    }
    fn currentProject(self: *const App) ?[]const u8 {
        return if (self.projects.len > 0) self.projects[self.project_idx] else null;
    }
    fn currentTask(self: *const App) ?*const model.Task {
        return if (self.tasks.len > 0) &self.tasks[self.task_idx] else null;
    }

    fn inputSlice(self: *const App) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    // ── actions ───────────────────────────────────────────────────────────────

    fn commitInput(self: *App) void {
        const text = self.inputSlice();
        // Where to return after committing
        const return_mode: Mode = switch (self.input_target) {
            .subtask, .description, .task_title => .task_detail,
            else => .normal,
        };
        if (text.len == 0) {
            self.mode = return_mode;
            self.input_len = 0;
            self.requestRefresh();
            return;
        }
        switch (self.input_target) {
            .space => {
                space_store.add(self.root_dir, text) catch {};
                self.reloadSpaces();
                for (self.spaces, 0..) |s, i| {
                    if (std.mem.eql(u8, s, text)) { self.space_idx = i; break; }
                }
            },
            .project => if (self.currentSpace()) |sp| {
                project_store.add(self.allocator, self.root_dir, sp, text) catch {};
                self.reloadProjects();
                for (self.projects, 0..) |p, i| {
                    if (std.mem.eql(u8, p, text)) { self.project_idx = i; break; }
                }
            },
            .task => if (self.currentSpace() != null and self.currentProject() != null) {
                _ = task_store.add(
                    self.allocator, self.root_dir,
                    self.currentSpace().?, self.currentProject().?,
                    .{ .title = text },
                ) catch {};
                self.reloadTasks();
                self.recalcProgress();
                if (self.tasks.len > 0) self.task_idx = self.tasks.len - 1;
            },
            .subtask => if (self.currentTask()) |task| {
                if (self.currentSpace() != null and self.currentProject() != null) {
                    // Build new subtask list = old + new
                    var new_subs = self.allocator.alloc(model.SubTask, task.subtasks.len + 1) catch {
                        self.mode = return_mode; self.input_len = 0; self.requestRefresh(); return;
                    };
                    defer self.allocator.free(new_subs);
                    for (task.subtasks, 0..) |st, i| new_subs[i] = st;
                    const new_title = self.allocator.dupe(u8, text) catch {
                        self.mode = return_mode; self.input_len = 0; self.requestRefresh(); return;
                    };
                    defer self.allocator.free(new_title);
                    new_subs[task.subtasks.len] = .{ .title = new_title, .done = false };
                    task_store.update(
                        self.allocator, self.root_dir,
                        self.currentSpace().?, self.currentProject().?,
                        task.id, .{ .subtasks = new_subs },
                    ) catch {};
                    self.reloadTasks();
                    self.detail_subtask_idx = if (self.currentTask()) |t| t.subtasks.len -| 1 else 0;
                }
            },
            .description => if (self.currentTask()) |task| {
                if (self.currentSpace() != null and self.currentProject() != null) {
                    task_store.update(
                        self.allocator, self.root_dir,
                        self.currentSpace().?, self.currentProject().?,
                        task.id, .{ .description = text },
                    ) catch {};
                    self.reloadTasks();
                }
            },
            .task_title => if (self.currentTask()) |task| {
                if (self.currentSpace() != null and self.currentProject() != null) {
                    const sp = self.currentSpace().?;
                    const pj = self.currentProject().?;
                    task_store.update(
                        self.allocator, self.root_dir, sp, pj,
                        task.id, .{ .title = text },
                    ) catch {};
                    self.enqueuePush(sp, pj, task, null, text);
                    self.reloadTasks();
                }
            },
        }
        self.mode = return_mode;
        self.input_len = 0;
        self.requestRefresh();
    }

    fn setNotify(self: *App, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.notify_buf, fmt, args) catch {
            self.notify_len = 0; return;
        };
        self.notify_len = s.len;
    }

    /// Queue a push for a synced task then flush on next sync.
    fn enqueuePush(
        self: *App,
        space: []const u8,
        project: []const u8,
        task: *const model.Task,
        new_status: ?model.Status,
        new_title: []const u8,
    ) void {
        if (task.external_id.len == 0) return;
        const src: []const u8 = switch (task.integration_source) {
            .github => "github",
            .linear => "linear",
            .trello => "trello",
            .none   => return,
        };
        // Derive owner/repo from the project name (format: "owner - repo")
        var owner: []const u8 = "";
        var repo:  []const u8 = "";
        if (task.integration_source == .github) {
            if (std.mem.indexOf(u8, project, " - ")) |idx| {
                owner = project[0..idx];
                repo  = project[idx + 3 ..];
            }
        }
        const status_str: []const u8 = if (new_status) |s| s.toString() else "";
        const entry = push_queue.PushEntry{
            .space       = space,
            .project     = project,
            .external_id = task.external_id,
            .source      = src,
            .owner       = owner,
            .repo        = repo,
            .new_status  = status_str,
            .new_title   = new_title,
        };
        push_queue.append(self.root_dir, self.allocator, entry) catch {};
    }

    /// Save the API token from auth_buf, run the full auto-sync, reload data.
    fn submitAuth(self: *App) void {
        const token = self.auth_buf[0..self.auth_len];
        if (token.len == 0) {
            self.mode = .settings;
            self.requestRefresh();
            return;
        }

        var cfg = config_store.loadGlobalConfig(self.allocator, self.root_dir) catch {
            self.setNotify("Error: could not load config", .{});
            self.mode = .settings;
            self.requestRefresh();
            return;
        };
        defer cfg.deinit(self.allocator);

        switch (self.auth_service) {
            .linear => {
                self.allocator.free(cfg.linear_api_key);
                cfg.linear_api_key = self.allocator.dupe(u8, token) catch return;
                cfg.linear_enabled = true;
            },
            .github => {
                self.allocator.free(cfg.github_token);
                cfg.github_token = self.allocator.dupe(u8, token) catch return;
                cfg.github_enabled = true;
            },
            else => { self.mode = .settings; self.requestRefresh(); return; },
        }

        config_store.saveGlobalConfig(self.allocator, self.root_dir, cfg) catch {
            self.setNotify("Error: could not save config", .{});
            self.mode = .settings;
            self.requestRefresh();
            return;
        };

        // Flush any queued local changes before pulling remote
        sync_engine.flushPushQueue(self.allocator, self.root_dir, cfg);

        const result: sync_engine.SyncResult = switch (self.auth_service) {
            .linear => sync_engine.autoSyncLinear(self.allocator, self.root_dir, cfg),
            .github => sync_engine.autoSyncGitHub(self.allocator, self.root_dir, cfg),
            else    => unreachable,
        } catch |err| {
            self.setNotify("Sync failed: {s}", .{@errorName(err)});
            self.reloadSpaces();
            self.mode = .settings;
            self.requestRefresh();
            return;
        };

        self.setNotify("Sync complete: {d} created, {d} updated, {d} errors",
            .{ result.created, result.updated, result.errors });
        self.reloadSpaces();
        self.mode = .settings;
        self.auth_len = 0;
        self.requestRefresh();
    }

    fn hardReset(self: *App) void {
        self.freeSpaces();
        self.freeProjects();
        self.freeTasks();
        self.root_dir.close();

        const root_path = paths.todoRootPath(self.allocator) catch return;
        defer self.allocator.free(root_path);
        std.fs.deleteTreeAbsolute(root_path) catch {};

        self.root_dir = paths.openOrCreateTodoRoot(self.allocator) catch return;
        self.reloadSpaces(); // everything empty after reset

        self.mode      = .onboarding;
        self.ob_step   = 0;
        self.ob_space_len = 0;
        self.ob_proj_len  = 0;
    }
};

// ── Key handlers ──────────────────────────────────────────────────────────────

fn deleteCurrentItem(app: *App) void {
    switch (app.active) {
        .spaces => if (app.currentSpace()) |sp| {
            space_store.remove(app.root_dir, sp) catch {};
            if (app.space_idx > 0) app.space_idx -= 1;
            app.reloadSpaces();
        },
        .projects => if (app.currentSpace()) |sp| {
            if (app.currentProject()) |pj| {
                project_store.remove(app.root_dir, sp, pj) catch {};
                if (app.project_idx > 0) app.project_idx -= 1;
                app.reloadProjects();
            }
        },
        .tasks => if (app.tasks.len > 0) {
            const id = app.tasks[app.task_idx].id;
            const sp = app.currentSpace() orelse return;
            const pj = app.currentProject() orelse return;
            task_store.remove(app.root_dir, sp, pj, id) catch {};
            if (app.task_idx > 0) app.task_idx -= 1;
            app.reloadTasks();
        },
    }
    app.requestRefresh();
}

fn handleKey(app: *App, key: vaxis.Key) bool {
    // Any keypress clears the notify bar
    app.notify_len = 0;

    switch (app.mode) {
        .input                => return handleInputKey(app, key),
        .settings             => return handleSettingsKey(app, key),
        .settings_confirm     => return handleSettingsConfirmKey(app, key),
        .auth_overlay         => return handleAuthOverlayKey(app, key),
        .onboarding           => return handleOnboardingKey(app, key),
        .task_detail          => return handleTaskDetailKey(app, key),
        .task_confirm_delete  => return handleConfirmDeleteKey(app, key),
        .color_picker         => return handleColorPickerKey(app, key),
        .normal               => {},
    }

    // quit
    if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return true;

    // open settings
    if (key.matches('s', .{})) {
        app.mode         = .settings;
        app.settings_idx = settings_initial_idx;
        app.requestRefresh();
        return false;
    }

    // switch panels: tab / shift+tab, h/l, ←/→
    if (key.matches(vaxis.Key.tab, .{}) or key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        app.active = switch (app.active) {
            .spaces => .projects, .projects => .tasks, .tasks => .tasks,
        };
    }
    if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        app.active = switch (app.active) {
            .spaces => .spaces, .projects => .spaces, .tasks => .projects,
        };
    }

    // navigate up
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        switch (app.active) {
            .spaces   => if (app.space_idx > 0)   { app.space_idx   -= 1; app.reloadProjects(); },
            .projects => if (app.project_idx > 0) { app.project_idx -= 1; app.reloadTasks(); },
            .tasks    => if (app.task_idx > 0)    { app.task_idx    -= 1; },
        }
    }

    // navigate down
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        switch (app.active) {
            .spaces   => if (app.space_idx   + 1 < app.spaces.len)   { app.space_idx   += 1; app.reloadProjects(); },
            .projects => if (app.project_idx + 1 < app.projects.len) { app.project_idx += 1; app.reloadTasks(); },
            .tasks    => if (app.task_idx    + 1 < app.tasks.len)    { app.task_idx    += 1; },
        }
    }

    // add item
    if (key.matches('a', .{})) {
        app.mode = .input;
        app.input_target = switch (app.active) {
            .spaces => .space, .projects => .project, .tasks => .task,
        };
        app.input_len = 0;
    }

    // delete item — d asks for confirmation, shift+d deletes immediately
    if (key.matches('d', .{}) or key.matches('D', .{ .shift = true })) {
        const force = key.matches('D', .{ .shift = true });
        if (force) {
            deleteCurrentItem(app);
        } else {
            // show confirmation dialog
            const has_target = switch (app.active) {
                .spaces   => app.currentSpace() != null,
                .projects => app.currentProject() != null,
                .tasks    => app.tasks.len > 0,
            };
            if (has_target) {
                app.confirm_delete_panel = app.active;
                app.mode = .task_confirm_delete;
                app.requestRefresh();
            }
        }
    }

    // enter: open colour picker (spaces/projects) or task detail (tasks)
    if (key.matches(vaxis.Key.enter, .{})) {
        switch (app.active) {
            .spaces => if (app.spaces.len > 0) {
                const cur: model.ItemColor = if (app.space_idx < app.space_colors.len)
                    app.space_colors[app.space_idx] else .default;
                app.color_picker_idx   = @intFromEnum(cur);
                app.color_picker_panel = .spaces;
                app.mode = .color_picker;
                app.requestRefresh();
            },
            .projects => if (app.projects.len > 0) {
                const cur: model.ItemColor = if (app.project_idx < app.project_colors.len)
                    app.project_colors[app.project_idx] else .default;
                app.color_picker_idx   = @intFromEnum(cur);
                app.color_picker_panel = .projects;
                app.mode = .color_picker;
                app.requestRefresh();
            },
            .tasks => if (app.tasks.len > 0) {
                app.detail_subtask_idx = 0;
                app.mode = .task_detail;
                app.requestRefresh();
            },
        }
    }

    // status / priority shortcuts work directly in tasks panel too
    if (app.active == .tasks and app.tasks.len > 0) {
        if (app.currentSpace()) |sp| if (app.currentProject()) |pj| {
            const task = &app.tasks[app.task_idx];
            if (key.matches(']', .{})) { applyStatusChange(app, sp, pj, task, task.status.next()); }
            if (key.matches('[', .{})) { applyStatusChange(app, sp, pj, task, task.status.prev()); }
            if (key.matches('}', .{})) { applyPriorityChange(app, sp, pj, task, task.priority.next()); }
            if (key.matches('{', .{})) { applyPriorityChange(app, sp, pj, task, task.priority.prev()); }
            if (key.matches('X', .{ .shift = true })) { applyStatusChange(app, sp, pj, task, .done); }
        };
    }

    return false;
}

fn handleInputKey(app: *App, key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.escape, .{})) {
        app.mode = switch (app.input_target) {
            .subtask, .description, .task_title => .task_detail,
            else => .normal,
        };
        app.input_len = 0;
        app.requestRefresh();
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{}))   { app.commitInput(); return false; }
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (app.input_len > 0) app.input_len -= 1;
        return false;
    }
    if (key.text) |t| {
        if (app.input_len + t.len <= app.input_buf.len) {
            @memcpy(app.input_buf[app.input_len..][0..t.len], t);
            app.input_len += t.len;
        }
    }
    return false;
}

fn handleSettingsKey(app: *App, key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.escape, .{})) { app.mode = .normal; app.requestRefresh(); return false; }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        app.settings_idx = prevSelectableIdx(app.settings_idx);
        return false;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        app.settings_idx = nextSelectableIdx(app.settings_idx);
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const entry = settings_entries[app.settings_idx];
        switch (entry.kind) {
            .toggle => {
                switch (entry.id) {
                    .show_progress      => app.show_progress      = !app.show_progress,
                    .alt_priority       => app.alt_priority       = !app.alt_priority,
                    .task_color_grading => app.task_color_grading = !app.task_color_grading,
                    .compact_mode       => {
                        app.compact_mode = !app.compact_mode;
                        var cfg = config_store.loadGlobalConfig(app.allocator, app.root_dir) catch null;
                        if (cfg) |*c| {
                            defer c.deinit(app.allocator);
                            c.compact_mode = app.compact_mode;
                            config_store.saveGlobalConfig(app.allocator, app.root_dir, c.*) catch {};
                        }
                    },
                    else => {},
                }
                app.requestRefresh();
            },
            .action => switch (entry.id) {
                .hard_reset => app.mode = .settings_confirm,
                .task_sort  => {
                    app.task_sort = switch (app.task_sort) {
                        .by_id           => .by_priority_desc,
                        .by_priority_desc => .by_status,
                        .by_status       => .by_id,
                    };
                    app.reloadTasks();
                    app.requestRefresh();
                },
                else => {},
            },
            .todo => switch (entry.id) {
                .linear, .github => {
                    app.auth_service = entry.id;
                    app.auth_mode = .choose;
                    app.auth_choose_idx = 0;
                    app.auth_len = 0;
                    // Pre-fill with existing token so user can see it's set
                    const cfg = config_store.loadGlobalConfig(app.allocator, app.root_dir) catch {
                        app.mode = .auth_overlay;
                        app.requestRefresh();
                        return false;
                    };
                    defer cfg.deinit(app.allocator);
                    const existing: []const u8 = switch (entry.id) {
                        .linear => cfg.linear_api_key,
                        .github => cfg.github_token,
                        else    => "",
                    };
                    const copy_len = @min(existing.len, app.auth_buf.len);
                    @memcpy(app.auth_buf[0..copy_len], existing[0..copy_len]);
                    app.auth_len = copy_len;
                    app.mode = .auth_overlay;
                    app.requestRefresh();
                },
                else => {},
            },
            .section => {},
        }
        return false;
    }
    return false;
}

fn handleAuthOverlayKey(app: *App, key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.escape, .{})) {
        switch (app.auth_mode) {
            .choose => { app.mode = .settings; },
            .device_waiting => {
                app.stopOAuthPoll();
                app.auth_mode = .choose;
            },
            .token_input => { app.auth_mode = .choose; },
        }
        app.requestRefresh();
        return false;
    }

    switch (app.auth_mode) {
        .choose => {
            if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                app.auth_choose_idx = 0;
                app.requestRefresh();
            } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                app.auth_choose_idx = 1;
                app.requestRefresh();
            } else if (key.matches(vaxis.Key.enter, .{})) {
                const want_device_flow = app.auth_service == .github and app.auth_choose_idx == 0;
                if (want_device_flow) {
                    // Signals run() to call startDeviceFlow on the next iteration
                    app.auth_mode = .device_waiting;
                } else {
                    // Token paste path
                    if (app.auth_service == .linear and app.auth_choose_idx == 0) {
                        openBrowser(app.allocator, "https://linear.app/settings/api");
                    }
                    app.auth_mode = .token_input;
                }
                app.requestRefresh();
            }
        },
        .device_waiting => {
            // No keys do anything while polling except Esc (handled above)
        },
        .token_input => {
            if (key.matches(vaxis.Key.enter, .{})) {
                app.submitAuth();
            } else if (key.matches(vaxis.Key.backspace, .{})) {
                if (app.auth_len > 0) app.auth_len -= 1;
                app.requestRefresh();
            } else if (key.text) |t| {
                for (t) |ch| {
                    if (app.auth_len < app.auth_buf.len) {
                        app.auth_buf[app.auth_len] = ch;
                        app.auth_len += 1;
                    }
                }
                app.requestRefresh();
            }
        },
    }
    return false;
}

fn handleOAuthResult(app: *App, ev: OAuthEvent) void {
    app.stopOAuthPoll();

    if (ev.token) |token| {
        defer app.allocator.free(token);
        // Save the token the same way submitAuth does
        var cfg = config_store.loadGlobalConfig(app.allocator, app.root_dir) catch {
            app.setNotify("Error: could not load config", .{});
            app.auth_mode = .choose;
            app.mode = .settings;
            app.requestRefresh();
            return;
        };
        defer cfg.deinit(app.allocator);

        app.allocator.free(cfg.github_token);
        cfg.github_token = app.allocator.dupe(u8, token) catch return;
        cfg.github_enabled = true;

        config_store.saveGlobalConfig(app.allocator, app.root_dir, cfg) catch {
            app.setNotify("Error: could not save config", .{});
            app.auth_mode = .choose;
            app.mode = .settings;
            app.requestRefresh();
            return;
        };

        sync_engine.flushPushQueue(app.allocator, app.root_dir, cfg);

        const result = sync_engine.autoSyncGitHub(app.allocator, app.root_dir, cfg) catch |err| {
            app.setNotify("Sync failed: {s}", .{@errorName(err)});
            app.reloadSpaces();
            app.auth_mode = .choose;
            app.mode = .settings;
            app.requestRefresh();
            return;
        };
        app.setNotify("GitHub connected! Sync: {d} created, {d} updated", .{ result.created, result.updated });
        app.reloadSpaces();
    } else if (ev.err_msg) |msg| {
        defer app.allocator.free(msg);
        app.setNotify("OAuth failed: {s}", .{msg});
    } else {
        app.setNotify("OAuth cancelled.", .{});
    }

    app.auth_mode = .choose;
    app.mode = .settings;
    app.requestRefresh();
}

fn handleSettingsConfirmKey(app: *App, key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.escape, .{})) { app.mode = .settings; app.requestRefresh(); return false; }
    if (key.matches(vaxis.Key.enter, .{}))  { app.hardReset(); app.requestRefresh(); return false; }
    return false;
}

fn handleConfirmDeleteKey(app: *App, key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.escape, .{})) { app.mode = .normal; app.requestRefresh(); return false; }
    if (key.matches(vaxis.Key.enter, .{})) {
        deleteCurrentItem(app);  // already calls requestRefresh()
        app.mode = .normal;
    }
    return false;
}

fn handleColorPickerKey(app: *App, key: vaxis.Key) bool {
    const color_count = @typeInfo(model.ItemColor).@"enum".fields.len;
    if (key.matches(vaxis.Key.escape, .{})) {
        app.mode = .normal;
        app.requestRefresh();
        return false;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (app.color_picker_idx > 0) app.color_picker_idx -= 1;
        return false;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (app.color_picker_idx + 1 < color_count) app.color_picker_idx += 1;
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const new_color: model.ItemColor = @enumFromInt(app.color_picker_idx);
        switch (app.color_picker_panel) {
            .spaces => if (app.currentSpace()) |sp| {
                space_store.setColor(app.root_dir, sp, new_color) catch {};
                app.reloadSpaces();
            },
            .projects => if (app.currentSpace()) |sp| if (app.currentProject()) |pj| {
                project_store.setColor(app.allocator, app.root_dir, sp, pj, new_color) catch {};
                app.reloadProjects();
            },
            .tasks => {},
        }
        app.mode = .normal;
        app.requestRefresh();
        return false;
    }
    return false;
}

fn applyStatusChange(app: *App, sp: []const u8, pj: []const u8, task: *const model.Task, new_status: ?model.Status) void {
    if (new_status) |s| {
        task_store.update(app.allocator, app.root_dir, sp, pj, task.id, .{ .status = s }) catch {};
        app.enqueuePush(sp, pj, task, s, "");
        app.reloadTasks();
        app.recalcProgress();
        app.requestRefresh();
    }
}

fn applyPriorityChange(app: *App, sp: []const u8, pj: []const u8, task: *const model.Task, new_priority: ?model.Priority) void {
    if (new_priority) |p| {
        task_store.update(app.allocator, app.root_dir, sp, pj, task.id, .{ .priority = p }) catch {};
        app.reloadTasks();
        app.requestRefresh();
    }
}

fn handleTaskDetailKey(app: *App, key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.escape, .{})) { app.mode = .normal; app.requestRefresh(); return false; }

    const task = app.currentTask() orelse { app.mode = .normal; app.requestRefresh(); return false; };
    const sp = app.currentSpace() orelse { app.mode = .normal; app.requestRefresh(); return false; };
    const pj = app.currentProject() orelse { app.mode = .normal; app.requestRefresh(); return false; };

    // ] = next status, [ = prev status
    if (key.matches(']', .{})) { applyStatusChange(app, sp, pj, task, task.status.next()); return false; }
    if (key.matches('[', .{})) { applyStatusChange(app, sp, pj, task, task.status.prev()); return false; }
    // } = next priority (lower), { = prev priority (higher) — shift+]/[
    if (key.matches('}', .{})) { applyPriorityChange(app, sp, pj, task, task.priority.next()); return false; }
    if (key.matches('{', .{})) { applyPriorityChange(app, sp, pj, task, task.priority.prev()); return false; }
    // X = force task done
    if (key.matches('X', .{ .shift = true })) {
        applyStatusChange(app, sp, pj, task, .done);
        return false;
    }
    // Rename task title
    if (key.matches('r', .{})) {
        app.mode = .input;
        app.input_target = .task_title;
        const title = task.title;
        const copy_len = @min(title.len, app.input_buf.len);
        @memcpy(app.input_buf[0..copy_len], title[0..copy_len]);
        app.input_len = copy_len;
        return false;
    }
    // Edit description
    if (key.matches('e', .{})) {
        app.mode = .input;
        app.input_target = .description;
        // Pre-fill with existing description
        const desc = task.description;
        const copy_len = @min(desc.len, app.input_buf.len);
        @memcpy(app.input_buf[0..copy_len], desc[0..copy_len]);
        app.input_len = copy_len;
        return false;
    }
    // Add subtask
    if (key.matches('a', .{})) {
        app.mode = .input;
        app.input_target = .subtask;
        app.input_len = 0;
        return false;
    }
    // Navigate subtasks
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (task.subtasks.len > 0 and app.detail_subtask_idx + 1 < task.subtasks.len)
            app.detail_subtask_idx += 1;
        return false;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (app.detail_subtask_idx > 0) app.detail_subtask_idx -= 1;
        return false;
    }
    // Delete selected subtask
    if (key.matches('d', .{}) and task.subtasks.len > 0) {
        const idx = app.detail_subtask_idx;
        const new_len = task.subtasks.len - 1;
        var new_subs = app.allocator.alloc(model.SubTask, new_len) catch return false;
        defer app.allocator.free(new_subs);
        var j: usize = 0;
        for (task.subtasks, 0..) |st, i| {
            if (i == idx) continue;
            new_subs[j] = .{ .title = st.title, .done = st.done };
            j += 1;
        }
        task_store.update(app.allocator, app.root_dir, sp, pj, task.id,
            .{ .subtasks = new_subs }) catch {};
        app.reloadTasks();
        if (app.detail_subtask_idx > 0 and
            (app.currentTask() == null or app.detail_subtask_idx >= (app.currentTask() orelse task).subtasks.len))
            app.detail_subtask_idx -= 1;
        return false;
    }
    return false;
}

fn handleOnboardingKey(app: *App, key: vaxis.Key) bool {
    switch (app.ob_step) {
        0 => { // welcome
            if (key.matches(vaxis.Key.escape, .{})) { app.mode = .normal; return false; }
            if (key.matches(vaxis.Key.enter, .{}))  { app.ob_step = 1; return false; }
        },
        1 => { // enter space name
            if (key.matches(vaxis.Key.escape, .{})) { app.mode = .normal; return false; }
            if (key.matches(vaxis.Key.backspace, .{})) {
                if (app.ob_space_len > 0) app.ob_space_len -= 1;
                return false;
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                if (app.ob_space_len > 0) {
                    const name = app.ob_space_buf[0..app.ob_space_len];
                    space_store.add(app.root_dir, name) catch {};
                    app.reloadSpaces();
                    for (app.spaces, 0..) |s, i| {
                        if (std.mem.eql(u8, s, name)) { app.space_idx = i; break; }
                    }
                    app.ob_step = 2;
                }
                return false;
            }
            if (key.text) |t| {
                if (app.ob_space_len + t.len <= app.ob_space_buf.len) {
                    @memcpy(app.ob_space_buf[app.ob_space_len..][0..t.len], t);
                    app.ob_space_len += t.len;
                }
            }
        },
        2 => { // enter project name
            if (key.matches(vaxis.Key.escape, .{})) { app.mode = .normal; return false; }
            if (key.matches(vaxis.Key.backspace, .{})) {
                if (app.ob_proj_len > 0) app.ob_proj_len -= 1;
                return false;
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                if (app.ob_proj_len > 0) {
                    const sp   = app.ob_space_buf[0..app.ob_space_len];
                    const name = app.ob_proj_buf[0..app.ob_proj_len];
                    project_store.add(app.allocator, app.root_dir, sp, name) catch {};
                    app.reloadProjects();
                    for (app.projects, 0..) |p, i| {
                        if (std.mem.eql(u8, p, name)) { app.project_idx = i; break; }
                    }
                    app.ob_step = 3;
                }
                return false;
            }
            if (key.text) |t| {
                if (app.ob_proj_len + t.len <= app.ob_proj_buf.len) {
                    @memcpy(app.ob_proj_buf[app.ob_proj_len..][0..t.len], t);
                    app.ob_proj_len += t.len;
                }
            }
        },
        3 => { // done
            if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.enter, .{})) {
                app.mode = .normal;
            }
        },
    }
    return false;
}

// ── Rendering ─────────────────────────────────────────────────────────────────

pub fn render(app: *const App, win: vaxis.Window) void {
    win.fill(.{}); // NOT clear(): clear() sets Cell{.default=true} which vaxis skips even
                   // on full refresh — old overlay backgrounds stay visible. fill(.{})
                   // writes explicit blanks (default=false) that vaxis actually emits.

    if (win.width < 50 or win.height < 8) {
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = "Terminal too small — resize to continue.", .style = .{ .fg = col_warning } },
        }, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });
        return;
    }

    const panel_h: u16 = win.height -| 4;
    const spaces_w: u16  = if (app.compact_mode) (if (app.active == .spaces)   win.width else 0) else @max(16, win.width * 18 / 100);
    const projects_w: u16 = if (app.compact_mode) (if (app.active == .projects) win.width else 0) else @max(18, win.width * 23 / 100);
    const tasks_w: u16    = if (app.compact_mode) (if (app.active == .tasks)    win.width else 0) else win.width -| spaces_w -| projects_w;

    // compute accent colors
    const space_accent = col_active_border;
    const proj_accent: vaxis.Color = if (app.spaces.len > 0 and app.space_idx < app.space_colors.len and app.space_colors[app.space_idx] != .default)
        itemColorToVaxis(app.space_colors[app.space_idx])
    else col_active_border;
    const tasks_accent: vaxis.Color = if (app.projects.len > 0 and app.project_idx < app.project_colors.len and app.project_colors[app.project_idx] != .default)
        itemColorToVaxis(app.project_colors[app.project_idx])
    else if (app.spaces.len > 0 and app.space_idx < app.space_colors.len and app.space_colors[app.space_idx] != .default)
        itemColorToVaxis(app.space_colors[app.space_idx])
    else col_active_border;

    // panels (always rendered — overlay draws on top afterwards)
    if (!app.compact_mode or app.active == .spaces) {
        const spaces_inner = renderPanel(win, 0, 0, spaces_w, panel_h,
            " Spaces ", app.active == .spaces, space_accent);
        renderStringList(spaces_inner, app.spaces, app.space_colors, app.space_idx, app.active == .spaces);
    }

    if (!app.compact_mode or app.active == .projects) {
        const proj_x: i17 = if (app.compact_mode) 0 else @intCast(spaces_w);
        const projects_inner = renderPanel(win, proj_x, 0, projects_w, panel_h,
            " Projects ", app.active == .projects, proj_accent);
        renderProjectList(projects_inner, app.projects, app.project_progress, app.project_colors, app.project_idx,
            app.active == .projects, app.show_progress);
    }

    if (!app.compact_mode or app.active == .tasks) {
        const tasks_x: i17 = if (app.compact_mode) 0 else @intCast(spaces_w + projects_w);
        const tasks_inner = renderPanel(win, tasks_x, 0, tasks_w, panel_h,
            " Tasks ", app.active == .tasks, tasks_accent);
        renderTasks(tasks_inner, app.tasks, app.task_idx, app.active == .tasks, app.alt_priority, app.task_color_grading);
    }

    renderBottom(win, app, panel_h);

    // overlays — drawn last so they sit on top
    switch (app.mode) {
        .settings, .settings_confirm => renderSettingsOverlay(win, app),
        .auth_overlay                => renderAuthOverlay(win, app),
        .onboarding                  => renderOnboardingOverlay(win, app),
        .task_detail                 => renderTaskDetailOverlay(win, app),
        .task_confirm_delete         => renderConfirmDeleteDialog(win, app),
        .color_picker                => renderColorPickerOverlay(win, app),
        .input => switch (app.input_target) {
            .subtask, .description, .task_title => renderTaskDetailOverlay(win, app),
            else => {},
        },
        else => {},
    }

    // Notification bar (shown over everything when notify_len > 0)
    if (app.notify_len > 0) {
        const msg = app.notify_buf[0..app.notify_len];
        const ny = win.height -| 1;
        var col: u16 = 0;
        while (col < win.width) : (col += 1) {
            win.writeCell(col, ny, .{
                .char  = .{ .grapheme = " ", .width = 1 },
                .style = .{ .fg = col_selected_fg, .bg = vaxis.Color{ .rgb = [3]u8{ 20, 60, 20 } } },
            });
        }
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = " ", .style = .{ .bg = vaxis.Color{ .rgb = [3]u8{ 20, 60, 20 } } } },
            .{ .text = msg, .style = .{ .fg = col_selected_fg, .bg = vaxis.Color{ .rgb = [3]u8{ 20, 60, 20 } } } },
        }, .{ .row_offset = ny, .col_offset = 0, .wrap = .none });
    }
}

// ── Panel helpers ─────────────────────────────────────────────────────────────

fn renderPanel(win: vaxis.Window, x: i17, y: i17, w: u16, h: u16, title: []const u8, active: bool, accent: vaxis.Color) vaxis.Window {
    const border_fg = if (active) accent else col_inactive_border;
    const bs = vaxis.Style{ .fg = border_fg };
    const inner = win.child(.{
        .x_off = x, .y_off = y, .width = w, .height = h,
        .border = .{ .where = .all, .style = bs, .glyphs = .single_rounded },
    });
    _ = win.print(&[_]vaxis.Segment{
        .{ .text = title, .style = .{ .fg = border_fg, .bold = active } },
    }, .{ .row_offset = @intCast(y), .col_offset = @intCast(x + 2), .wrap = .none });
    return inner;
}

fn renderStringList(win: vaxis.Window, items: []const []const u8, colors: []const model.ItemColor, sel: usize, active: bool) void {
    if (items.len == 0) {
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = " empty", .style = .{ .fg = col_dim_fg, .italic = true } },
        }, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });
        return;
    }
    const visible: usize = win.height;
    const scroll: usize  = if (sel >= visible) sel - visible + 1 else 0;
    for (items[scroll..], 0..) |item, vi| {
        if (vi >= visible) break;
        const idx    = scroll + vi;
        const is_sel = idx == sel;
        const item_color = if (idx < colors.len) colors[idx] else model.ItemColor.default;
        const base_fg = if (item_color != .default) itemColorToVaxis(item_color) else col_normal_fg;
        const fg = base_fg;
        const bg     = if (is_sel and active) col_selected_bg else vaxis.Color.default;
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = if (is_sel) " > " else "   ", .style = .{ .fg = fg, .bg = bg } },
            .{ .text = item, .style = .{ .fg = fg, .bg = bg, .bold = is_sel and active } },
        }, .{ .row_offset = @intCast(vi), .col_offset = 0, .wrap = .none });
    }
}

fn renderProjectList(win: vaxis.Window, items: []const []const u8, progress: []const u32, project_colors: []const model.ItemColor, sel: usize, active: bool, show_progress: bool) void {
    if (items.len == 0) {
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = " empty", .style = .{ .fg = col_dim_fg, .italic = true } },
        }, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });
        return;
    }
    const visible: usize = win.height;
    const scroll: usize  = if (sel >= visible) sel - visible + 1 else 0;
    for (items[scroll..], 0..) |item, vi| {
        if (vi >= visible) break;
        const idx    = scroll + vi;
        const is_sel = idx == sel;
        const item_color = if (idx < project_colors.len) project_colors[idx] else model.ItemColor.default;
        const base_fg = if (item_color != .default) itemColorToVaxis(item_color) else col_normal_fg;
        const fg = base_fg;
        const bg     = if (is_sel and active) col_selected_bg else vaxis.Color.default;
        if (show_progress and idx < progress.len) {
            const pct = @min(progress[idx], 100);
            const pct_str = pct_strs[pct];
            _ = win.print(&[_]vaxis.Segment{
                .{ .text = if (is_sel) " > " else "   ", .style = .{ .fg = fg, .bg = bg } },
                .{ .text = item,    .style = .{ .fg = fg, .bg = bg, .bold = is_sel and active } },
                .{ .text = pct_str, .style = .{ .fg = if (pct == 100) col_low else col_hint_text, .bg = bg } },
            }, .{ .row_offset = @intCast(vi), .col_offset = 0, .wrap = .none });
        } else {
            _ = win.print(&[_]vaxis.Segment{
                .{ .text = if (is_sel) " > " else "   ", .style = .{ .fg = fg, .bg = bg } },
                .{ .text = item, .style = .{ .fg = fg, .bg = bg, .bold = is_sel and active } },
            }, .{ .row_offset = @intCast(vi), .col_offset = 0, .wrap = .none });
        }
    }
}

fn renderTasks(win: vaxis.Window, tasks: []const model.Task, sel: usize, active: bool, alt_priority: bool, task_color_grading: bool) void {
    if (tasks.len == 0) {
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = " no tasks — press [a] to add one", .style = .{ .fg = col_dim_fg, .italic = true } },
        }, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });
        return;
    }
    const visible: usize = win.height;
    const scroll: usize  = if (sel >= visible) sel - visible + 1 else 0;
    for (tasks[scroll..], 0..) |task, vi| {
        if (vi >= visible) break;
        const idx    = scroll + vi;
        const is_sel = idx == sel;
        const bg     = if (is_sel and active) col_selected_bg else vaxis.Color.default;
        const icon: []const u8 = switch (task.status) {
            .todo => "[ ]", .in_progress => "[~]", .in_review => "[?]", .done => "[x]",
        };
        const st_fg: vaxis.Color = switch (task.status) {
            .todo => col_todo_fg, .in_progress => col_in_progress_fg,
            .in_review => col_in_review_fg, .done => col_done_fg,
        };
        const pr_fg: vaxis.Color = switch (task.priority) {
            .low => col_low, .medium => col_medium, .high => col_high, .urgent => col_urgent,
        };
        const pr_badge: []const u8 = if (alt_priority) switch (task.priority) {
            .low => " ^  ", .medium => " ^^ ", .high => " ^^^", .urgent => " !!!",
        } else switch (task.priority) {
            .low => " [L]", .medium => " [M]", .high => " [H]", .urgent => " [U]",
        };
        const title_fg: vaxis.Color = if (task.status == .done)
            col_done_fg
        else if (task_color_grading)
            pr_fg
        else
            col_normal_fg;
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = if (is_sel) " > " else "   ", .style = .{ .fg = st_fg, .bg = bg } },
            .{ .text = icon,       .style = .{ .fg = st_fg, .bg = bg } },
            .{ .text = pr_badge,   .style = .{ .fg = pr_fg, .bg = bg } },
            .{ .text = " ",        .style = .{ .bg = bg } },
            .{ .text = task.title, .style = .{ .fg = title_fg, .bg = bg, .strikethrough = task.status == .done } },
        }, .{ .row_offset = @intCast(vi), .col_offset = 0, .wrap = .none });
    }
}

fn renderBottom(win: vaxis.Window, app: *const App, panel_h: u16) void {
    // separator
    var i: u16 = 0;
    while (i < win.width) : (i += 1) {
        win.writeCell(i, panel_h, .{
            .char  = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = col_inactive_border },
        });
    }
    // hints
    _ = win.print(&[_]vaxis.Segment{
        .{ .text = " tab",   .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " panel  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "↑↓/jk",   .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " nav  ",   .style = .{ .fg = col_hint_text } },
        .{ .text = "a",        .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " add  ",   .style = .{ .fg = col_hint_text } },
        .{ .text = "d",        .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " delete  ",.style = .{ .fg = col_hint_text } },
        .{ .text = "enter",    .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " open  ",  .style = .{ .fg = col_hint_text } },
        .{ .text = "[/]",      .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " status  ",.style = .{ .fg = col_hint_text } },
        .{ .text = "{/}",      .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " priority  ",.style = .{ .fg = col_hint_text } },
        .{ .text = "s",        .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " settings  ",.style = .{ .fg = col_hint_text } },
        .{ .text = "q",        .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " quit",    .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = panel_h + 1, .col_offset = 0, .wrap = .none });
    // context / input
    const ctx_y = panel_h + 2;
    if (app.mode == .input) {
        const prompt: []const u8 = switch (app.input_target) {
            .space       => " New space name: ",
            .project     => " New project name: ",
            .task        => " New task title: ",
            .subtask     => " New subtask: ",
            .description => " Description: ",
            .task_title  => " Rename task: ",
        };
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = prompt,           .style = .{ .fg = col_input_prompt, .bold = true } },
            .{ .text = app.inputSlice(), .style = .{ .fg = col_normal_fg } },
            .{ .text = "|",              .style = .{ .fg = col_input_prompt } },
        }, .{ .row_offset = ctx_y, .col_offset = 0, .wrap = .none });
    } else {
        if (app.currentSpace()) |sp| {
            if (app.currentProject()) |pj| {
                _ = win.print(&[_]vaxis.Segment{
                    .{ .text = " ",  .style = .{ .fg = col_hint_text } },
                    .{ .text = sp,   .style = .{ .fg = col_hint_text } },
                    .{ .text = " / ", .style = .{ .fg = col_hint_text } },
                    .{ .text = pj,   .style = .{ .fg = col_hint_text } },
                }, .{ .row_offset = ctx_y, .col_offset = 0, .wrap = .none });
            }
        }
    }
}

// ── Overlay helpers ───────────────────────────────────────────────────────────

/// Fills an area with the overlay background, draws a border, returns the inner window.
fn makeOverlay(win: vaxis.Window, ow: u16, oh: u16) vaxis.Window {
    const x: u16 = (win.width  -| ow) / 2;
    const y: u16 = (win.height -| oh) / 2;
    // flood-fill the footprint so panel content doesn't show through
    var row: u16 = 0;
    while (row < oh) : (row += 1) {
        var col: u16 = 0;
        while (col < ow) : (col += 1) {
            win.writeCell(x + col, y + row, .{
                .char  = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = col_overlay_bg },
            });
        }
    }
    return win.child(.{
        .x_off = @intCast(x), .y_off = @intCast(y),
        .width = ow, .height = oh,
        .border = .{ .where = .all,
                     .style  = .{ .fg = col_active_border, .bg = col_overlay_bg },
                     .glyphs = .single_rounded },
    });
}

fn overlayTitle(inner: vaxis.Window, title: []const u8) void {
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = title, .style = .{ .fg = col_active_border, .bold = true } },
    }, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
}

fn overlayHints(inner: vaxis.Window, row: u16, segments: []const vaxis.Segment) void {
    _ = inner.print(segments, .{ .row_offset = row, .col_offset = 1, .wrap = .none });
}

// ── Auth overlay ──────────────────────────────────────────────────────────────

fn renderAuthOverlay(win: vaxis.Window, app: *const App) void {
    const ow: u16 = 64;
    const service_name: []const u8 = switch (app.auth_service) {
        .linear => " Connect to Linear ",
        .github => " Connect to GitHub ",
        else    => " Connect ",
    };

    switch (app.auth_mode) {
        .choose => renderAuthChoose(win, app, ow, service_name),
        .device_waiting => renderAuthDeviceWaiting(win, app, ow, service_name),
        .token_input => renderAuthTokenInput(win, app, ow, service_name),
    }
}

fn renderAuthChoose(win: vaxis.Window, app: *const App, ow: u16, title: []const u8) void {
    const oh: u16 = 13;
    const inner = makeOverlay(win, ow, oh);
    overlayTitle(inner, title);

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "How would you like to authenticate?", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });

    // Option 0 — device flow (GitHub only) or browser PAT (Linear)
    const opt0_label: []const u8 = switch (app.auth_service) {
        .github => "Login with GitHub  (opens browser, no copy-paste needed)",
        .linear => "Open Linear API keys in browser",
        else    => "Open in browser",
    };
    const opt0_sel = app.auth_choose_idx == 0;
    const opt1_sel = app.auth_choose_idx == 1;

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = if (opt0_sel) " >  " else "    ", .style = .{ .fg = if (opt0_sel) col_selected_fg else col_dim_fg, .bg = if (opt0_sel) col_selected_bg else vaxis.Color.default } },
        .{ .text = opt0_label, .style = .{ .fg = if (opt0_sel) col_selected_fg else col_normal_fg, .bg = if (opt0_sel) col_selected_bg else vaxis.Color.default, .bold = opt0_sel } },
    }, .{ .row_offset = 4, .col_offset = 0, .wrap = .none });

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = if (opt1_sel) " >  " else "    ", .style = .{ .fg = if (opt1_sel) col_selected_fg else col_dim_fg, .bg = if (opt1_sel) col_selected_bg else vaxis.Color.default } },
        .{ .text = "Paste an API key / personal access token", .style = .{ .fg = if (opt1_sel) col_selected_fg else col_normal_fg, .bg = if (opt1_sel) col_selected_bg else vaxis.Color.default, .bold = opt1_sel } },
    }, .{ .row_offset = 6, .col_offset = 0, .wrap = .none });

    overlayHints(inner, oh -| 3, &[_]vaxis.Segment{
        .{ .text = "↑↓/jk",  .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " nav  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "enter",  .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " select  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc",    .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " back",  .style = .{ .fg = col_hint_text } },
    });
}

fn renderAuthDeviceWaiting(win: vaxis.Window, app: *const App, ow: u16, title: []const u8) void {
    const oh: u16 = 14;
    const inner = makeOverlay(win, ow, oh);
    overlayTitle(inner, title);

    const user_code = app.oauth_user_code_buf[0..app.oauth_user_code_len];
    const uri       = app.oauth_uri_buf[0..app.oauth_uri_len];
    const show_uri  = if (uri.len > 0) uri else "github.com/login/device";

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "1.  Your browser has been opened to:", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = show_uri, .style = .{ .fg = col_active_border, .bold = true } },
    }, .{ .row_offset = 3, .col_offset = 6, .wrap = .none });

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "2.  Enter this one-time code:", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = 5, .col_offset = 2, .wrap = .none });

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = if (user_code.len > 0) user_code else "fetching…",
           .style = .{ .fg = col_selected_fg, .bold = true } },
    }, .{ .row_offset = 6, .col_offset = 6, .wrap = .none });

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "Waiting for you to authorise in the browser…", .style = .{ .fg = col_dim_fg, .italic = true } },
    }, .{ .row_offset = 8, .col_offset = 2, .wrap = .none });

    overlayHints(inner, oh -| 3, &[_]vaxis.Segment{
        .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " cancel", .style = .{ .fg = col_hint_text } },
    });
}

fn renderAuthTokenInput(win: vaxis.Window, app: *const App, ow: u16, title: []const u8) void {
    const oh: u16 = 14;
    const inner = makeOverlay(win, ow, oh);
    overlayTitle(inner, title);

    const instr: []const u8 = switch (app.auth_service) {
        .linear => "Your browser has opened linear.app/settings/api\nCreate a new token, copy it, then paste it below:",
        .github => "Create a token at github.com/settings/tokens/new\n(scopes: repo, read:user), then paste it below:",
        else    => "Paste your API token:",
    };
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = instr, .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = 2, .col_offset = 2, .wrap = .word });

    // Input field background
    var c: u16 = 2;
    while (c < ow -| 3) : (c += 1) {
        inner.writeCell(c, 6, .{
            .char  = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = col_selected_bg },
        });
    }

    // Show token masked (only last 8 visible once longer than field)
    const field_w: usize = ow -| 6;
    const token = app.auth_buf[0..app.auth_len];
    var display_buf: [128]u8 = undefined;
    const display: []const u8 = blk: {
        if (token.len == 0) break :blk "";
        if (token.len <= field_w) break :blk token;
        const tail = @min(8, token.len);
        const stars = @min(field_w -| tail, display_buf.len -| tail);
        @memset(display_buf[0..stars], '*');
        @memcpy(display_buf[stars .. stars + tail], token[token.len - tail ..]);
        break :blk display_buf[0 .. stars + tail];
    };

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = display, .style = .{ .fg = col_normal_fg, .bg = col_selected_bg } },
        .{ .text = "█",     .style = .{ .fg = col_input_prompt, .bg = col_selected_bg } },
    }, .{ .row_offset = 6, .col_offset = 2, .wrap = .none });

    const hint_text: []const u8 = if (app.auth_len > 0) "Token ready" else "Waiting for token…";
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = hint_text, .style = .{ .fg = col_dim_fg, .italic = true } },
    }, .{ .row_offset = 8, .col_offset = 2, .wrap = .none });

    overlayHints(inner, oh -| 3, &[_]vaxis.Segment{
        .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " connect  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc",   .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " back", .style = .{ .fg = col_hint_text } },
    });
}

// ── Settings overlay ──────────────────────────────────────────────────────────

fn renderSettingsOverlay(win: vaxis.Window, app: *const App) void {
    const ow: u16 = 56;
    const oh: u16 = 40;
    const inner = makeOverlay(win, ow, oh);
    overlayTitle(inner, " Settings");

    var row: u16 = 2;
    for (settings_entries, 0..) |entry, ei| {
        switch (entry.kind) {
            .section => {
                // Section heading
                _ = inner.print(&[_]vaxis.Segment{
                    .{ .text = entry.label, .style = .{ .fg = col_section_header, .bold = true } },
                }, .{ .row_offset = row, .col_offset = 1, .wrap = .none });
                // Underline the section header
                var sep_col: u16 = 1;
                const sep_end: u16 = ow -| 3;
                while (sep_col < sep_end) : (sep_col += 1) {
                    inner.writeCell(sep_col, row + 1, .{
                        .char  = .{ .grapheme = "─", .width = 1 },
                        .style = .{ .fg = col_inactive_border },
                    });
                }
                row += 2;
            },
            .toggle => {
                const is_sel = ei == app.settings_idx;
                const fg     = if (is_sel) col_selected_fg else col_normal_fg;
                const bg     = if (is_sel) col_selected_bg else vaxis.Color.default;
                const checked: bool = switch (entry.id) {
                    .show_progress     => app.show_progress,
                    .alt_priority      => app.alt_priority,
                    .task_color_grading => app.task_color_grading,
                    else => false,
                };
                _ = inner.print(&[_]vaxis.Segment{
                    .{ .text = if (is_sel) " >  " else "    ", .style = .{ .fg = fg, .bg = bg } },
                    .{ .text = if (checked) "[x] " else "[ ] ", .style = .{ .fg = col_low, .bg = bg } },
                    .{ .text = entry.label, .style = .{ .fg = fg, .bg = bg, .bold = is_sel } },
                }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
                if (entry.sub.len > 0) {
                    _ = inner.print(&[_]vaxis.Segment{
                        .{ .text = "        ", .style = .{ .bg = bg } },
                        .{ .text = entry.sub, .style = .{ .fg = col_hint_text, .bg = bg, .italic = true } },
                    }, .{ .row_offset = row + 1, .col_offset = 0, .wrap = .none });
                }
                row += 3;
            },
            .action => {
                const is_sel = ei == app.settings_idx;
                const fg     = if (is_sel) col_selected_fg else col_normal_fg;
                const bg     = if (is_sel) col_selected_bg else vaxis.Color.default;
                if (entry.id == .task_sort) {
                    const sort_label: []const u8 = switch (app.task_sort) {
                        .by_id            => "Sort order: Default",
                        .by_priority_desc => "Sort order: Priority",
                        .by_status        => "Sort order: Status",
                    };
                    _ = inner.print(&[_]vaxis.Segment{
                        .{ .text = if (is_sel) " >  " else "    ", .style = .{ .fg = fg, .bg = bg } },
                        .{ .text = sort_label, .style = .{ .fg = fg, .bg = bg, .bold = is_sel } },
                    }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
                } else {
                    _ = inner.print(&[_]vaxis.Segment{
                        .{ .text = if (is_sel) " >  " else "    ", .style = .{ .fg = fg, .bg = bg } },
                        .{ .text = entry.label, .style = .{ .fg = fg, .bg = bg, .bold = is_sel } },
                    }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
                }
                if (entry.sub.len > 0) {
                    _ = inner.print(&[_]vaxis.Segment{
                        .{ .text = "    ", .style = .{ .bg = bg } },
                        .{ .text = entry.sub, .style = .{ .fg = col_hint_text, .bg = bg, .italic = true } },
                    }, .{ .row_offset = row + 1, .col_offset = 0, .wrap = .none });
                }
                row += 3;
            },
            .todo => {
                const is_sel = ei == app.settings_idx;
                const fg     = if (is_sel) col_selected_fg else col_dim_fg;
                const bg     = if (is_sel) col_selected_bg else vaxis.Color.default;
                _ = inner.print(&[_]vaxis.Segment{
                    .{ .text = if (is_sel) " >  " else "    ", .style = .{ .fg = fg, .bg = bg } },
                    .{ .text = entry.label, .style = .{ .fg = fg, .bg = bg } },
                    .{ .text = "  ", .style = .{ .bg = bg } },
                    .{ .text = "[TODO]", .style = .{ .fg = col_todo_badge, .bg = bg, .bold = true } },
                }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
                if (entry.sub.len > 0) {
                    _ = inner.print(&[_]vaxis.Segment{
                        .{ .text = "    ", .style = .{ .bg = bg } },
                        .{ .text = entry.sub, .style = .{ .fg = col_dim_fg, .bg = bg, .italic = true } },
                    }, .{ .row_offset = row + 1, .col_offset = 0, .wrap = .none });
                }
                row += 3;
            },
        }
    }

    const hint_row = oh -| 3;
    overlayHints(inner, hint_row, &[_]vaxis.Segment{
        .{ .text = "↑↓/jk",  .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " nav  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "enter",  .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " select  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc",    .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " close", .style = .{ .fg = col_hint_text } },
    });

    if (app.mode == .settings_confirm) renderConfirmDialog(win);
}

fn renderConfirmDialog(win: vaxis.Window) void {
    const cw: u16 = 48;
    const ch: u16 =  7;
    const inner = makeOverlay(win, cw, ch);
    overlayTitle(inner, " Hard Reset");

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = " ⚠  This will permanently delete ALL your data.", .style = .{ .fg = col_warning, .bold = true } },
    }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "    Spaces, projects and tasks cannot be recovered.", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = 3, .col_offset = 0, .wrap = .none });

    overlayHints(inner, ch -| 2, &[_]vaxis.Segment{
        .{ .text = "enter",  .style = .{ .fg = col_warning, .bold = true } },
        .{ .text = " confirm  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc",    .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " cancel", .style = .{ .fg = col_hint_text } },
    });
}

// ── Onboarding overlay ────────────────────────────────────────────────────────

fn renderConfirmDeleteDialog(win: vaxis.Window, app: *const App) void {
    const cw: u16 = 52;
    const ch: u16 = 7;
    const inner = makeOverlay(win, cw, ch);
    const label: []const u8 = switch (app.confirm_delete_panel) {
        .spaces   => "Delete this space and ALL its contents?",
        .projects => "Delete this project and ALL its tasks?",
        .tasks    => "Delete this task?",
    };
    overlayTitle(inner, " Confirm Delete");
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = " ⚠  ", .style = .{ .fg = col_warning } },
        .{ .text = label,  .style = .{ .fg = col_warning, .bold = true } },
    }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "    This action cannot be undone.", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = 3, .col_offset = 0, .wrap = .none });
    overlayHints(inner, ch -| 2, &[_]vaxis.Segment{
        .{ .text = "enter", .style = .{ .fg = col_warning, .bold = true } },
        .{ .text = " confirm  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc",   .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " cancel", .style = .{ .fg = col_hint_text } },
    });
}

fn renderTaskDetailOverlay(win: vaxis.Window, app: *const App) void {
    const task = app.currentTask() orelse return;

    const ow: u16 = @min(win.width -| 4, 70);
    // Height: title(1) + gap(1) + status+priority(1) + [integration(1) + gap(1) if linked] +
    //         gap(1) + desc_label(1) + desc(1) + gap(1) + subtask_label(1) + subtasks(up to 6) + hints(3)
    const has_integration = task.external_id.len > 0;
    const integration_rows: u16 = if (has_integration) 2 else 0; // row + extra gap
    const subtask_rows: u16 = @intCast(@min(task.subtasks.len + 1, 8));
    const oh: u16 = 13 + subtask_rows + integration_rows;

    const inner = makeOverlay(win, ow, oh);

    // Title
    const is_editing_title = app.mode == .input and app.input_target == .task_title;
    if (is_editing_title) {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = " ", .style = .{} },
            .{ .text = app.inputSlice(), .style = .{ .fg = col_normal_fg, .bold = true } },
            .{ .text = "|", .style = .{ .fg = col_input_prompt } },
        }, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });
    } else {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = " ",          .style = .{ .fg = col_active_border, .bold = true } },
            .{ .text = task.title,   .style = .{ .fg = col_active_border, .bold = true } },
        }, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    }

    // Status + Priority row
    const status_icon: []const u8 = switch (task.status) {
        .todo => "[ ]", .in_progress => "[~]", .in_review => "[?]", .done => "[x]",
    };
    const status_label: []const u8 = switch (task.status) {
        .todo => "todo", .in_progress => "in-progress", .in_review => "in-review", .done => "done",
    };
    const st_fg: vaxis.Color = switch (task.status) {
        .todo => col_todo_fg, .in_progress => col_in_progress_fg,
        .in_review => col_in_review_fg, .done => col_done_fg,
    };
    const pr_fg: vaxis.Color = switch (task.priority) {
        .low => col_low, .medium => col_medium, .high => col_high, .urgent => col_urgent,
    };
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "  Status  ", .style = .{ .fg = col_hint_text } },
        .{ .text = status_icon,  .style = .{ .fg = st_fg } },
        .{ .text = " ", .style = .{} },
        .{ .text = status_label, .style = .{ .fg = st_fg, .bold = true } },
        .{ .text = "    Priority  ", .style = .{ .fg = col_hint_text } },
        .{ .text = task.priority.toString(), .style = .{ .fg = pr_fg, .bold = true } },
    }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });

    // Integration row (only when task is linked to an external service)
    var detail_row: u16 = 4;
    if (has_integration) {
        const source_label: []const u8 = switch (task.integration_source) {
            .linear => "linear",
            .github => "github",
            .trello => "trello",
            .none   => "",
        };
        const synced_label = if (task.synced_at.len > 0) task.synced_at else "never";
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  Integration  ", .style = .{ .fg = col_hint_text } },
            .{ .text = source_label,      .style = .{ .fg = col_hint_key,  .bold = true } },
            .{ .text = "  ",              .style = .{} },
            .{ .text = task.external_id,  .style = .{ .fg = col_normal_fg } },
            .{ .text = "  synced ",       .style = .{ .fg = col_dim_fg } },
            .{ .text = synced_label,      .style = .{ .fg = col_dim_fg } },
        }, .{ .row_offset = 3, .col_offset = 0, .wrap = .none });
        detail_row = 6; // shift subsequent rows down by 2
    }

    // Description
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "  Description ", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = detail_row, .col_offset = 0, .wrap = .none });

    const is_editing_desc = app.mode == .input and app.input_target == .description;
    if (is_editing_desc) {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  ", .style = .{} },
            .{ .text = app.inputSlice(), .style = .{ .fg = col_normal_fg } },
            .{ .text = "|", .style = .{ .fg = col_input_prompt } },
        }, .{ .row_offset = detail_row + 1, .col_offset = 0, .wrap = .none });
    } else if (task.description.len > 0) {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  ", .style = .{} },
            .{ .text = task.description, .style = .{ .fg = col_normal_fg } },
        }, .{ .row_offset = detail_row + 1, .col_offset = 0, .wrap = .none });
    } else {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  (none — press e to add)", .style = .{ .fg = col_dim_fg, .italic = true } },
        }, .{ .row_offset = detail_row + 1, .col_offset = 0, .wrap = .none });
    }

    // Subtasks
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "  Subtasks ", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = detail_row + 3, .col_offset = 0, .wrap = .none });

    const subtask_base_row = detail_row + 4;
    const is_adding_sub = app.mode == .input and app.input_target == .subtask;
    if (task.subtasks.len == 0 and !is_adding_sub) {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  (none — press a to add)", .style = .{ .fg = col_dim_fg, .italic = true } },
        }, .{ .row_offset = subtask_base_row, .col_offset = 0, .wrap = .none });
    } else {
        const max_show: usize = 6;
        const show = @min(task.subtasks.len, max_show);
        const scroll: usize = if (app.detail_subtask_idx >= max_show)
            app.detail_subtask_idx - max_show + 1 else 0;
        for (task.subtasks[scroll..][0..@min(show, task.subtasks.len -| scroll)], 0..) |st, vi| {
            const idx    = scroll + vi;
            const is_sel = idx == app.detail_subtask_idx;
            const bg     = if (is_sel) col_selected_bg else vaxis.Color.default;
            const fg     = if (is_sel) col_selected_fg else col_normal_fg;
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = if (is_sel) "  > " else "    ", .style = .{ .fg = fg, .bg = bg } },
                .{ .text = if (st.done) "[x] " else "[ ] ", .style = .{ .fg = if (st.done) col_low else col_normal_fg, .bg = bg } },
                .{ .text = st.title, .style = .{ .fg = if (st.done) col_done_fg else fg,
                    .bg = bg, .strikethrough = st.done } },
            }, .{ .row_offset = subtask_base_row + @as(u16, @intCast(vi)), .col_offset = 0, .wrap = .none });
        }
        if (is_adding_sub) {
            const add_row = subtask_base_row + @as(u16, @intCast(@min(show, task.subtasks.len -| scroll)));
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = "  + ", .style = .{ .fg = col_input_prompt } },
                .{ .text = app.inputSlice(), .style = .{ .fg = col_normal_fg } },
                .{ .text = "|", .style = .{ .fg = col_input_prompt } },
            }, .{ .row_offset = add_row, .col_offset = 0, .wrap = .none });
        }
    }

    // Hints (two rows)
    const hint_row = oh -| 3;
    overlayHints(inner, hint_row, &[_]vaxis.Segment{
        .{ .text = "[/]",   .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " status  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "{/}",   .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " priority  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "X",     .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " done  ", .style = .{ .fg = col_hint_text } },
    });
    overlayHints(inner, hint_row + 1, &[_]vaxis.Segment{
        .{ .text = "r",     .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " rename  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "e",     .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " desc  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "a",     .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " subtask  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "d",     .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " del sub  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc",   .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " close", .style = .{ .fg = col_hint_text } },
    });
}

// ── Colour picker overlay ─────────────────────────────────────────────────────

const color_picker_names  = [_][]const u8{
    "Default", "Red", "Green", "Blue", "Orange", "Purple", "Cyan", "Yellow",
};
const color_picker_values = [_]model.ItemColor{
    .default, .red, .green, .blue, .orange, .purple, .cyan, .yellow,
};

fn renderColorPickerOverlay(win: vaxis.Window, app: *const App) void {
    const ow: u16 = 26;
    const oh: u16 = @intCast(color_picker_names.len + 5);
    const inner = makeOverlay(win, ow, oh);

    const title: []const u8 = switch (app.color_picker_panel) {
        .spaces   => " Space Colour",
        .projects => " Project Colour",
        .tasks    => " Colour",
    };
    overlayTitle(inner, title);

    for (color_picker_names, 0..) |name, i| {
        const is_sel = i == app.color_picker_idx;
        const item_col = itemColorToVaxis(color_picker_values[i]);
        const bg = if (is_sel) col_selected_bg else vaxis.Color.default;
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = if (is_sel) " > " else "   ", .style = .{ .fg = col_selected_fg, .bg = bg } },
            .{ .text = "* ",   .style = .{ .fg = item_col, .bg = bg } },
            .{ .text = name,   .style = .{ .fg = if (is_sel) col_selected_fg else col_normal_fg,
                                           .bg = bg, .bold = is_sel } },
        }, .{ .row_offset = @intCast(2 + i), .col_offset = 0, .wrap = .none });
    }

    overlayHints(inner, oh -| 2, &[_]vaxis.Segment{
        .{ .text = "↑↓/jk",  .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " nav  ",  .style = .{ .fg = col_hint_text } },
        .{ .text = "enter",   .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " pick  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc",     .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " cancel", .style = .{ .fg = col_hint_text } },
    });
}

fn renderOnboardingOverlay(win: vaxis.Window, app: *const App) void {
    const ow: u16 = 56;
    const oh: u16 = 12;
    const inner = makeOverlay(win, ow, oh);

    switch (app.ob_step) {
        0 => {
            overlayTitle(inner, " Welcome to todo!");
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " Organise your work as  Space › Project › Task.", .style = .{ .fg = col_normal_fg } },
            }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " Spaces  group related projects  (e.g. work, personal).", .style = .{ .fg = col_hint_text } },
            }, .{ .row_offset = 3, .col_offset = 0, .wrap = .none });
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " Projects hold tasks  (e.g. api, website, reading-list).", .style = .{ .fg = col_hint_text } },
            }, .{ .row_offset = 4, .col_offset = 0, .wrap = .none });
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " Let's create your first space and project now.", .style = .{ .fg = col_normal_fg } },
            }, .{ .row_offset = 6, .col_offset = 0, .wrap = .none });
            overlayHints(inner, oh -| 2, &[_]vaxis.Segment{
                .{ .text = "enter",  .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " get started  ", .style = .{ .fg = col_hint_text } },
                .{ .text = "esc",    .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " skip",  .style = .{ .fg = col_hint_text } },
            });
        },
        1 => {
            overlayTitle(inner, " Create your first Space");
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " A space groups related projects.", .style = .{ .fg = col_normal_fg } },
            }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " e.g. work  personal  side-projects", .style = .{ .fg = col_hint_text, .italic = true } },
            }, .{ .row_offset = 3, .col_offset = 0, .wrap = .none });
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " Space name: ", .style = .{ .fg = col_input_prompt, .bold = true } },
                .{ .text = app.ob_space_buf[0..app.ob_space_len], .style = .{ .fg = col_normal_fg } },
                .{ .text = "|", .style = .{ .fg = col_input_prompt } },
            }, .{ .row_offset = 5, .col_offset = 0, .wrap = .none });
            overlayHints(inner, oh -| 2, &[_]vaxis.Segment{
                .{ .text = "enter",  .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " confirm  ", .style = .{ .fg = col_hint_text } },
                .{ .text = "esc",    .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " skip",  .style = .{ .fg = col_hint_text } },
            });
        },
        2 => {
            overlayTitle(inner, " Create your first Project");
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " A project lives inside a space and holds tasks.", .style = .{ .fg = col_normal_fg } },
            }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " e.g. api  website  q1-goals  groceries", .style = .{ .fg = col_hint_text, .italic = true } },
            }, .{ .row_offset = 3, .col_offset = 0, .wrap = .none });
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " Project in '",                     .style = .{ .fg = col_input_prompt, .bold = true } },
                .{ .text = app.ob_space_buf[0..app.ob_space_len], .style = .{ .fg = col_input_prompt, .bold = true } },
                .{ .text = "': ",                               .style = .{ .fg = col_input_prompt, .bold = true } },
                .{ .text = app.ob_proj_buf[0..app.ob_proj_len], .style = .{ .fg = col_normal_fg } },
                .{ .text = "|",                                 .style = .{ .fg = col_input_prompt } },
            }, .{ .row_offset = 5, .col_offset = 0, .wrap = .none });
            overlayHints(inner, oh -| 2, &[_]vaxis.Segment{
                .{ .text = "enter",  .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " confirm  ", .style = .{ .fg = col_hint_text } },
                .{ .text = "esc",    .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " skip",  .style = .{ .fg = col_hint_text } },
            });
        },
        3 => {
            overlayTitle(inner, " You're all set!");
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " \xe2\x9c\x93  Space '",             .style = .{ .fg = col_low, .bold = true } },
                .{ .text = app.ob_space_buf[0..app.ob_space_len], .style = .{ .fg = col_low, .bold = true } },
                .{ .text = "' and project '",                    .style = .{ .fg = col_low, .bold = true } },
                .{ .text = app.ob_proj_buf[0..app.ob_proj_len],  .style = .{ .fg = col_low, .bold = true } },
                .{ .text = "' created.",                         .style = .{ .fg = col_low, .bold = true } },
            }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " Switch to the Tasks panel and press [a] to add your first task.", .style = .{ .fg = col_hint_text } },
            }, .{ .row_offset = 4, .col_offset = 0, .wrap = .none });
            overlayHints(inner, oh -| 2, &[_]vaxis.Segment{
                .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " start", .style = .{ .fg = col_hint_text } },
            });
        },
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn run(allocator: std.mem.Allocator) !void {
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();
    const ttywriter = tty.writer();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, ttywriter);

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(ttywriter);
    try vx.queryTerminal(ttywriter, 1 * std.time.ns_per_ms);

    const initial_ws = try vaxis.Tty.getWinsize(tty.fd);
    try vx.resize(allocator, ttywriter, initial_ws);

    var app = try App.init(allocator);
    defer app.deinit();

    while (true) {
        // If device_waiting but no thread running yet, kick off the device flow
        if (app.mode == .auth_overlay and
            app.auth_mode == .device_waiting and
            app.oauth_poll_thread == null)
        {
            app.startDeviceFlow(&loop);
        }

        const event = loop.nextEvent();
        switch (event) {
            .key_press    => |key| { if (handleKey(&app, key)) break; },
            .winsize      => |ws|  { try vx.resize(allocator, ttywriter, ws); },
            .oauth_result => |ev|  { handleOAuthResult(&app, ev); },
        }
        if (app.is_refresh_needed) {
            app.is_refresh_needed = false;
            vx.refresh = true;
        }
        const win = vx.window();
        render(&app, win);
        try vx.render(ttywriter);
    }
}
