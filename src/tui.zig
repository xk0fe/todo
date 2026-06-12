const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const model = @import("model.zig");
const paths = @import("storage/paths.zig");
const space_store = @import("storage/space_store.zig");
const project_store = @import("storage/project_store.zig");
const task_store = @import("storage/task_store.zig");
const config_store = @import("storage/config_store.zig");
const ext_config = @import("storage/ext_config.zig");
const toml = @import("storage/toml.zig");
const ext_registry = @import("extensions/registry.zig");
const ext_runner = @import("extensions/runner.zig");
const ext_protocol = @import("extensions/protocol.zig");
const ext_engine = @import("extensions/engine.zig");

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

const col_active_border = vaxis.Color{ .rgb = [3]u8{ 99, 179, 237 } };
const col_inactive_border = vaxis.Color{ .rgb = [3]u8{ 70, 70, 70 } };
const col_selected_fg = vaxis.Color{ .rgb = [3]u8{ 255, 215, 0 } };
const col_selected_bg = vaxis.Color{ .rgb = [3]u8{ 35, 38, 55 } };
const col_normal_fg = vaxis.Color{ .rgb = [3]u8{ 200, 200, 200 } };
const col_dim_fg = vaxis.Color{ .rgb = [3]u8{ 85, 85, 85 } };
const col_hint_key = vaxis.Color{ .rgb = [3]u8{ 99, 179, 237 } };
const col_hint_text = vaxis.Color{ .rgb = [3]u8{ 120, 120, 120 } };
const col_input_prompt = vaxis.Color{ .rgb = [3]u8{ 99, 179, 237 } };
const col_todo_fg = vaxis.Color{ .rgb = [3]u8{ 200, 200, 200 } };
const col_in_progress_fg = vaxis.Color{ .rgb = [3]u8{ 255, 200, 60 } };
const col_in_review_fg = vaxis.Color{ .rgb = [3]u8{ 180, 120, 240 } };
const col_done_fg = vaxis.Color{ .rgb = [3]u8{ 75, 75, 75 } };
const col_progress_fill = vaxis.Color{ .rgb = [3]u8{ 60, 140, 60 } };
const col_progress_bg = vaxis.Color{ .rgb = [3]u8{ 40, 40, 40 } };
const col_low = vaxis.Color{ .rgb = [3]u8{ 90, 200, 110 } };
const col_medium = vaxis.Color{ .rgb = [3]u8{ 255, 175, 50 } };
const col_high = vaxis.Color{ .rgb = [3]u8{ 240, 90, 90 } };
const col_urgent = vaxis.Color{ .rgb = [3]u8{ 220, 30, 80 } };
const col_overlay_bg = vaxis.Color{ .rgb = [3]u8{ 16, 18, 28 } };
const col_section_header = vaxis.Color{ .rgb = [3]u8{ 130, 130, 130 } };
const col_todo_badge = vaxis.Color{ .rgb = [3]u8{ 100, 100, 170 } };
const col_warning = vaxis.Color{ .rgb = [3]u8{ 240, 90, 90 } };

fn itemColorToVaxis(c: model.ItemColor) vaxis.Color {
    return switch (c) {
        .default => col_normal_fg,
        .red => vaxis.Color{ .rgb = [3]u8{ 220, 70, 70 } },
        .green => vaxis.Color{ .rgb = [3]u8{ 70, 190, 90 } },
        .blue => vaxis.Color{ .rgb = [3]u8{ 99, 179, 237 } },
        .orange => vaxis.Color{ .rgb = [3]u8{ 255, 150, 50 } },
        .purple => vaxis.Color{ .rgb = [3]u8{ 180, 120, 240 } },
        .cyan => vaxis.Color{ .rgb = [3]u8{ 70, 200, 200 } },
        .yellow => vaxis.Color{ .rgb = [3]u8{ 240, 200, 50 } },
    };
}

// ── Event ─────────────────────────────────────────────────────────────────────

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

// ── App modes ─────────────────────────────────────────────────────────────────

const Mode = enum {
    normal,
    input, // adding a space / project / task (or subtask/description)
    settings, // settings overlay open
    settings_confirm, // hard-reset confirmation dialog
    ext_overlay, // extension config overlay
    onboarding, // first-launch wizard
    task_detail, // task detail overlay
    task_confirm_delete, // confirm before deleting a space/project/task
    color_picker, // colour picker overlay for spaces/projects
};

const Panel = enum { spaces, projects, tasks };
const InputTarget = enum { space, project, task, subtask, description, task_title };

// ── Settings entries ──────────────────────────────────────────────────────────

const EntryKind = enum {
    section, // non-navigable heading
    action, // executable item
    toggle, // boolean toggle (uses app state)
};

const SettingsId = enum { hard_reset, show_progress, alt_priority, task_color_grading, compact_mode, task_sort, hide_done };

const SettingsEntry = struct {
    kind: EntryKind,
    id: SettingsId = .hard_reset, // only meaningful for action/toggle
    label: []const u8,
    sub: []const u8 = "",
};

const settings_entries = [_]SettingsEntry{
    .{ .kind = .section, .label = "General" },
    .{ .kind = .action, .id = .hard_reset, .label = "Hard Reset", .sub = "permanently delete all spaces, projects and tasks" },
    .{ .kind = .section, .label = "Display" },
    .{ .kind = .toggle, .id = .show_progress, .label = "Show project progress", .sub = "display completion % next to each project" },
    .{ .kind = .toggle, .id = .alt_priority, .label = "Alternative priority style", .sub = "show ^ ^^ ^^^ ^^^^ instead of [L][M][H][U]" },
    .{ .kind = .toggle, .id = .task_color_grading, .label = "Task colour grading", .sub = "tint task row by priority level" },
    .{ .kind = .toggle, .id = .compact_mode, .label = "Compact mode", .sub = "expand the active panel to fill the terminal width" },
    .{ .kind = .section, .label = "Tasks" },
    .{ .kind = .toggle, .id = .hide_done, .label = "Hide completed tasks", .sub = "only show todo / in-progress / in-review tasks" },
    .{ .kind = .action, .id = .task_sort, .label = "Sort order", .sub = "cycle: Default / Priority / Status" },
};

const settings_tab_labels = [_][]const u8{ "General", "Display", "Tasks", "Extensions" };
const settings_tab_count: usize = settings_tab_labels.len;
/// The Extensions tab lists discovered extension executables instead of
/// static settings entries.
const ext_tab_index: usize = 3;

/// Returns the non-section entries belonging to tab index `tab`.
fn tabEntries(tab: usize) []const SettingsEntry {
    var section_idx: usize = 0;
    var start: usize = 0;
    for (settings_entries, 0..) |e, i| {
        if (e.kind == .section) {
            if (section_idx == tab) {
                start = i + 1;
            } else if (section_idx == tab + 1) {
                return settings_entries[start..i];
            }
            section_idx += 1;
        }
    }
    if (section_idx > tab) return settings_entries[start..];
    return &.{};
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
    root_dir: std.fs.Dir,

    // main panel state
    active: Panel = .spaces,
    spaces: [][]const u8 = &.{},
    space_idx: usize = 0,
    projects: [][]const u8 = &.{},
    project_idx: usize = 0,
    tasks: []model.Task = &.{},
    task_idx: usize = 0,

    // project progress cache (parallel to projects slice)
    project_progress: []u32 = &.{},

    // input (add mode in main panels)
    mode: Mode = .normal,
    input_target: InputTarget = .space,
    input_buf: [256]u8 = undefined,
    input_len: usize = 0,
    is_refresh_needed: bool = false, // force full redraw on next frame

    // settings overlay
    settings_tab: usize = 0,
    settings_idx: usize = 0,
    show_progress: bool = true,
    alt_priority: bool = false,
    task_color_grading: bool = false,
    compact_mode: bool = false,
    hide_done: bool = false,
    task_sort: TaskSort = .by_id,

    // color arrays
    space_colors: []model.ItemColor = &.{},
    project_colors: []model.ItemColor = &.{},

    // task detail overlay
    detail_subtask_idx: usize = 0,

    // colour picker overlay
    color_picker_idx: usize = 0,
    color_picker_panel: Panel = .spaces,

    // delete confirmation
    confirm_delete_panel: Panel = .tasks,

    // onboarding wizard
    ob_step: u2 = 0,
    ob_space_buf: [64]u8 = undefined,
    ob_space_len: usize = 0,
    ob_proj_buf: [64]u8 = undefined,
    ob_proj_len: usize = 0,

    // extensions tab + config overlay
    extensions: []ext_registry.ExtRef = &.{},
    ext_idx: usize = 0,
    ext_manifest: ?ext_protocol.Manifest = null,
    ext_cfg_values: [][]u8 = &.{}, // parallel to ext_manifest.config_keys
    ext_cfg_idx: usize = 0,
    ext_editing: bool = false,
    ext_input_buf: [256]u8 = undefined,
    ext_input_len: usize = 0,

    // notification bar (shown at bottom until next keypress)
    notify_buf: [128]u8 = undefined,
    notify_len: usize = 0,

    // ── lifecycle ─────────────────────────────────────────────────────────────

    fn init(allocator: std.mem.Allocator) !App {
        var app = App{
            .allocator = allocator,
            .root_dir = try paths.openOrCreateTodoRoot(allocator),
        };
        const cfg = config_store.loadGlobalConfig(allocator, app.root_dir) catch null;
        if (cfg) |c| {
            defer c.deinit(allocator);
            app.compact_mode = c.compact_mode;
        }
        app.reloadSpaces();
        if (app.spaces.len == 0) {
            app.mode = .onboarding;
            app.ob_step = 0;
        }
        return app;
    }

    fn deinit(self: *App) void {
        self.closeExtOverlay();
        self.freeExtensions();
        self.freeSpaces();
        self.freeProjects();
        self.freeTasks();
        self.freeSpaceColors();
        self.freeProjectColors();
        self.root_dir.close();
    }

    fn freeExtensions(self: *App) void {
        ext_registry.freeList(self.allocator, self.extensions);
        self.extensions = &.{};
    }

    fn loadExtensions(self: *App) void {
        self.freeExtensions();
        self.extensions = ext_registry.list(self.allocator, self.root_dir) catch &.{};
        if (self.extensions.len > 0 and self.ext_idx >= self.extensions.len)
            self.ext_idx = self.extensions.len - 1;
    }

    /// Free the open extension overlay's manifest and config values.
    fn closeExtOverlay(self: *App) void {
        if (self.ext_manifest) |m| m.deinit(self.allocator);
        self.ext_manifest = null;
        for (self.ext_cfg_values) |v| self.allocator.free(v);
        if (self.ext_cfg_values.len > 0) self.allocator.free(self.ext_cfg_values);
        self.ext_cfg_values = &.{};
        self.ext_cfg_idx = 0;
        self.ext_editing = false;
        self.ext_input_len = 0;
    }

    /// Fetch the selected extension's manifest + current config and open the overlay.
    fn openExtOverlay(self: *App) void {
        if (self.extensions.len == 0) return;
        const ref = self.extensions[self.ext_idx];

        const out = ext_runner.run(self.allocator, ref.path, "manifest", null) catch {
            self.setNotify("Could not run extension '{s}'", .{ref.name});
            return;
        };
        defer out.deinit(self.allocator);
        if (!out.ok()) {
            self.setNotify("'{s} manifest' failed (exit {d})", .{ ref.name, out.exit_code });
            return;
        }
        const manifest = ext_protocol.parseManifest(self.allocator, out.stdout) catch {
            self.setNotify("'{s}' returned an invalid manifest", .{ref.name});
            return;
        };

        var map = ext_config.loadGlobal(self.allocator, self.root_dir, ref.name) catch toml.Map.empty;
        defer toml.freeMap(self.allocator, &map);

        self.closeExtOverlay();
        self.ext_manifest = manifest;
        self.ext_cfg_values = self.allocator.alloc([]u8, manifest.config_keys.len) catch &.{};
        for (manifest.config_keys, 0..) |ck, i| {
            if (i >= self.ext_cfg_values.len) break;
            self.ext_cfg_values[i] = self.allocator.dupe(u8, map.get(ck.key) orelse "") catch @constCast(&[_]u8{});
        }
        self.mode = .ext_overlay;
        self.requestRefresh();
    }

    /// Import the current project via its linked extension.
    fn runImport(self: *App) void {
        const sp = self.currentSpace() orelse return;
        const pj = self.currentProject() orelse return;
        const outcome = ext_engine.importProject(self.allocator, self.root_dir, sp, pj) catch |err| {
            self.setNotify("Import failed: {s}", .{@errorName(err)});
            return;
        };
        defer outcome.deinit(self.allocator);
        switch (outcome) {
            .ok => |r| self.setNotify("Import: {d} created, {d} updated, {d} errors", .{ r.created, r.updated, r.errors }),
            .fail => |msg| self.setNotify("{s}", .{msg[0..@min(msg.len, self.notify_buf.len - 1)]}),
        }
        self.reloadTasks();
        self.recalcProgress();
        self.requestRefresh();
    }

    /// Export the current project via its linked extension.
    fn runExport(self: *App) void {
        const sp = self.currentSpace() orelse return;
        const pj = self.currentProject() orelse return;
        const outcome = ext_engine.exportProject(self.allocator, self.root_dir, sp, pj) catch |err| {
            self.setNotify("Export failed: {s}", .{@errorName(err)});
            return;
        };
        defer outcome.deinit(self.allocator);
        switch (outcome) {
            .ok => |r| self.setNotify("Export: {d} exported, {d} skipped", .{ r.exported, r.skipped }),
            .fail => |msg| self.setNotify("{s}", .{msg[0..@min(msg.len, self.notify_buf.len - 1)]}),
        }
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
        if (self.spaces.len == 0) {
            self.reloadTasks();
            return;
        }
        self.projects = project_store.list(
            self.allocator,
            self.root_dir,
            self.spaces[self.space_idx],
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
                self.allocator,
                self.root_dir,
                sp,
                pj,
            );
        }
    }
    fn reloadTasks(self: *App) void {
        self.freeTasks();
        if (self.spaces.len == 0 or self.projects.len == 0) return;
        self.tasks = task_store.list(
            self.allocator,
            self.root_dir,
            self.spaces[self.space_idx],
            self.projects[self.project_idx],
            if (self.hide_done) .active else .all,
        ) catch &.{};
        switch (self.task_sort) {
            .by_id => {},
            .by_priority_desc => std.mem.sort(model.Task, self.tasks, {}, taskLessThanPriority),
            .by_status => std.mem.sort(model.Task, self.tasks, {}, taskLessThanStatus),
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
                    if (std.mem.eql(u8, s, text)) {
                        self.space_idx = i;
                        break;
                    }
                }
            },
            .project => if (self.currentSpace()) |sp| {
                project_store.add(self.allocator, self.root_dir, sp, text) catch {};
                self.reloadProjects();
                for (self.projects, 0..) |p, i| {
                    if (std.mem.eql(u8, p, text)) {
                        self.project_idx = i;
                        break;
                    }
                }
            },
            .task => if (self.currentSpace() != null and self.currentProject() != null) {
                _ = task_store.add(
                    self.allocator,
                    self.root_dir,
                    self.currentSpace().?,
                    self.currentProject().?,
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
                        self.mode = return_mode;
                        self.input_len = 0;
                        self.requestRefresh();
                        return;
                    };
                    defer self.allocator.free(new_subs);
                    for (task.subtasks, 0..) |st, i| new_subs[i] = st;
                    const new_title = self.allocator.dupe(u8, text) catch {
                        self.mode = return_mode;
                        self.input_len = 0;
                        self.requestRefresh();
                        return;
                    };
                    defer self.allocator.free(new_title);
                    new_subs[task.subtasks.len] = .{ .title = new_title, .done = false };
                    task_store.update(
                        self.allocator,
                        self.root_dir,
                        self.currentSpace().?,
                        self.currentProject().?,
                        task.id,
                        .{ .subtasks = new_subs },
                    ) catch {};
                    self.reloadTasks();
                    self.detail_subtask_idx = if (self.currentTask()) |t| t.subtasks.len -| 1 else 0;
                }
            },
            .description => if (self.currentTask()) |task| {
                if (self.currentSpace() != null and self.currentProject() != null) {
                    task_store.update(
                        self.allocator,
                        self.root_dir,
                        self.currentSpace().?,
                        self.currentProject().?,
                        task.id,
                        .{ .description = text },
                    ) catch {};
                    self.reloadTasks();
                }
            },
            .task_title => if (self.currentTask()) |task| {
                if (self.currentSpace() != null and self.currentProject() != null) {
                    task_store.update(
                        self.allocator,
                        self.root_dir,
                        self.currentSpace().?,
                        self.currentProject().?,
                        task.id,
                        .{ .title = text },
                    ) catch {};
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
            self.notify_len = 0;
            return;
        };
        self.notify_len = s.len;
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

        self.mode = .onboarding;
        self.ob_step = 0;
        self.ob_space_len = 0;
        self.ob_proj_len = 0;
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
        .input => return handleInputKey(app, key),
        .settings => return handleSettingsKey(app, key),
        .settings_confirm => return handleSettingsConfirmKey(app, key),
        .ext_overlay => return handleExtOverlayKey(app, key),
        .onboarding => return handleOnboardingKey(app, key),
        .task_detail => return handleTaskDetailKey(app, key),
        .task_confirm_delete => return handleConfirmDeleteKey(app, key),
        .color_picker => return handleColorPickerKey(app, key),
        .normal => {},
    }

    // quit
    if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return true;

    // open settings
    if (key.matches('s', .{})) {
        app.mode = .settings;
        app.settings_tab = 0;
        app.settings_idx = 0;
        app.requestRefresh();
        return false;
    }

    // switch panels: tab / shift+tab, h/l, ←/→
    if (key.matches(vaxis.Key.tab, .{}) or key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        app.active = switch (app.active) {
            .spaces => .projects,
            .projects => .tasks,
            .tasks => .tasks,
        };
    }
    if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        app.active = switch (app.active) {
            .spaces => .spaces,
            .projects => .spaces,
            .tasks => .projects,
        };
    }

    // navigate up
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        switch (app.active) {
            .spaces => if (app.space_idx > 0) {
                app.space_idx -= 1;
                app.reloadProjects();
            },
            .projects => if (app.project_idx > 0) {
                app.project_idx -= 1;
                app.reloadTasks();
            },
            .tasks => if (app.task_idx > 0) {
                app.task_idx -= 1;
            },
        }
    }

    // navigate down
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        switch (app.active) {
            .spaces => if (app.space_idx + 1 < app.spaces.len) {
                app.space_idx += 1;
                app.reloadProjects();
            },
            .projects => if (app.project_idx + 1 < app.projects.len) {
                app.project_idx += 1;
                app.reloadTasks();
            },
            .tasks => if (app.task_idx + 1 < app.tasks.len) {
                app.task_idx += 1;
            },
        }
    }

    // add item
    if (key.matches('a', .{})) {
        app.mode = .input;
        app.input_target = switch (app.active) {
            .spaces => .space,
            .projects => .project,
            .tasks => .task,
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
                .spaces => app.currentSpace() != null,
                .projects => app.currentProject() != null,
                .tasks => app.tasks.len > 0,
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
                    app.space_colors[app.space_idx]
                else
                    .default;
                app.color_picker_idx = @intFromEnum(cur);
                app.color_picker_panel = .spaces;
                app.mode = .color_picker;
                app.requestRefresh();
            },
            .projects => if (app.projects.len > 0) {
                const cur: model.ItemColor = if (app.project_idx < app.project_colors.len)
                    app.project_colors[app.project_idx]
                else
                    .default;
                app.color_picker_idx = @intFromEnum(cur);
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

    // import / export the current project via its linked extension
    if (key.matches('i', .{})) {
        app.runImport();
    }
    if (key.matches('I', .{ .shift = true })) {
        app.runExport();
    }

    // status / priority shortcuts work directly in tasks panel too
    if (app.active == .tasks and app.tasks.len > 0) {
        if (app.currentSpace()) |sp| if (app.currentProject()) |pj| {
            const task = &app.tasks[app.task_idx];
            if (key.matches(']', .{})) {
                applyStatusChange(app, sp, pj, task, task.status.next());
            }
            if (key.matches('[', .{})) {
                applyStatusChange(app, sp, pj, task, task.status.prev());
            }
            if (key.matches('}', .{})) {
                applyPriorityChange(app, sp, pj, task, task.priority.next());
            }
            if (key.matches('{', .{})) {
                applyPriorityChange(app, sp, pj, task, task.priority.prev());
            }
            if (key.matches('X', .{ .shift = true })) {
                applyStatusChange(app, sp, pj, task, .done);
            }
            if (key.matches('o', .{})) {
                openTaskUrl(app.allocator, task);
            }
        };
    }

    return false;
}

fn openTaskUrl(allocator: std.mem.Allocator, task: *const model.Task) void {
    if (task.url.len == 0) return;
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "open", task.url }
    else if (builtin.os.tag == .windows)
        &.{ "cmd", "/c", "start", task.url }
    else
        &.{ "xdg-open", task.url };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {};
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
    if (key.matches(vaxis.Key.enter, .{})) {
        app.commitInput();
        return false;
    }
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
    if (key.matches(vaxis.Key.escape, .{})) {
        app.mode = .normal;
        app.requestRefresh();
        return false;
    }

    // Tab switching with h/l or left/right
    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        if (app.settings_tab > 0) {
            app.settings_tab -= 1;
            const te = tabEntries(app.settings_tab);
            if (app.settings_idx >= te.len) app.settings_idx = if (te.len > 0) te.len - 1 else 0;
        }
        app.requestRefresh();
        return false;
    }
    if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        if (app.settings_tab + 1 < settings_tab_count) {
            app.settings_tab += 1;
            if (app.settings_tab == ext_tab_index) {
                app.loadExtensions();
            } else {
                const te = tabEntries(app.settings_tab);
                if (app.settings_idx >= te.len) app.settings_idx = if (te.len > 0) te.len - 1 else 0;
            }
        }
        app.requestRefresh();
        return false;
    }

    // Entry navigation within the current tab
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (app.settings_tab == ext_tab_index) {
            if (app.ext_idx > 0) app.ext_idx -= 1;
        } else if (app.settings_idx > 0) app.settings_idx -= 1;
        app.requestRefresh();
        return false;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (app.settings_tab == ext_tab_index) {
            if (app.extensions.len > 0 and app.ext_idx + 1 < app.extensions.len) app.ext_idx += 1;
        } else {
            const te = tabEntries(app.settings_tab);
            if (app.settings_idx + 1 < te.len) app.settings_idx += 1;
        }
        app.requestRefresh();
        return false;
    }

    if (key.matches(vaxis.Key.enter, .{})) {
        if (app.settings_tab == ext_tab_index) {
            app.openExtOverlay();
            return false;
        }
        const te = tabEntries(app.settings_tab);
        if (app.settings_idx >= te.len) {
            app.requestRefresh();
            return false;
        }
        const entry = te[app.settings_idx];
        switch (entry.kind) {
            .toggle => {
                switch (entry.id) {
                    .show_progress => app.show_progress = !app.show_progress,
                    .alt_priority => app.alt_priority = !app.alt_priority,
                    .task_color_grading => app.task_color_grading = !app.task_color_grading,
                    .hide_done => {
                        app.hide_done = !app.hide_done;
                        app.reloadTasks();
                    },
                    .compact_mode => {
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
                .task_sort => {
                    app.task_sort = switch (app.task_sort) {
                        .by_id => .by_priority_desc,
                        .by_priority_desc => .by_status,
                        .by_status => .by_id,
                    };
                    app.reloadTasks();
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

fn handleExtOverlayKey(app: *App, key: vaxis.Key) bool {
    const manifest = app.ext_manifest orelse {
        app.mode = .settings;
        app.requestRefresh();
        return false;
    };

    if (app.ext_editing) {
        if (key.matches(vaxis.Key.escape, .{})) {
            app.ext_editing = false;
            app.ext_input_len = 0;
            app.requestRefresh();
            return false;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            // Persist the edited value for the selected config key.
            if (app.ext_cfg_idx < manifest.config_keys.len and app.ext_cfg_idx < app.ext_cfg_values.len) {
                const ck = manifest.config_keys[app.ext_cfg_idx];
                const value = app.ext_input_buf[0..app.ext_input_len];
                const ext_name = app.extensions[app.ext_idx].name;
                ext_config.setGlobalValue(app.allocator, app.root_dir, ext_name, ck.key, value) catch {
                    app.setNotify("Could not save config", .{});
                };
                if (app.allocator.dupe(u8, value)) |copy| {
                    app.allocator.free(app.ext_cfg_values[app.ext_cfg_idx]);
                    app.ext_cfg_values[app.ext_cfg_idx] = copy;
                } else |_| {}
            }
            app.ext_editing = false;
            app.ext_input_len = 0;
            app.requestRefresh();
            return false;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (app.ext_input_len > 0) app.ext_input_len -= 1;
            app.requestRefresh();
            return false;
        }
        if (key.text) |t| {
            if (app.ext_input_len + t.len <= app.ext_input_buf.len) {
                @memcpy(app.ext_input_buf[app.ext_input_len..][0..t.len], t);
                app.ext_input_len += t.len;
            }
            app.requestRefresh();
        }
        return false;
    }

    if (key.matches(vaxis.Key.escape, .{})) {
        app.closeExtOverlay();
        app.mode = .settings;
        app.requestRefresh();
        return false;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (app.ext_cfg_idx > 0) app.ext_cfg_idx -= 1;
        app.requestRefresh();
        return false;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (manifest.config_keys.len > 0 and app.ext_cfg_idx + 1 < manifest.config_keys.len)
            app.ext_cfg_idx += 1;
        app.requestRefresh();
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (app.ext_cfg_idx < app.ext_cfg_values.len) {
            const current = app.ext_cfg_values[app.ext_cfg_idx];
            const copy_len = @min(current.len, app.ext_input_buf.len);
            @memcpy(app.ext_input_buf[0..copy_len], current[0..copy_len]);
            app.ext_input_len = copy_len;
            app.ext_editing = true;
            app.requestRefresh();
        }
        return false;
    }
    return false;
}

fn handleSettingsConfirmKey(app: *App, key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.escape, .{})) {
        app.mode = .settings;
        app.requestRefresh();
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        app.hardReset();
        app.requestRefresh();
        return false;
    }
    return false;
}

fn handleConfirmDeleteKey(app: *App, key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.escape, .{})) {
        app.mode = .normal;
        app.requestRefresh();
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        deleteCurrentItem(app); // already calls requestRefresh()
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
    if (key.matches(vaxis.Key.escape, .{})) {
        app.mode = .normal;
        app.requestRefresh();
        return false;
    }

    const task = app.currentTask() orelse {
        app.mode = .normal;
        app.requestRefresh();
        return false;
    };
    const sp = app.currentSpace() orelse {
        app.mode = .normal;
        app.requestRefresh();
        return false;
    };
    const pj = app.currentProject() orelse {
        app.mode = .normal;
        app.requestRefresh();
        return false;
    };

    // ] = next status, [ = prev status
    if (key.matches(']', .{})) {
        applyStatusChange(app, sp, pj, task, task.status.next());
        return false;
    }
    if (key.matches('[', .{})) {
        applyStatusChange(app, sp, pj, task, task.status.prev());
        return false;
    }
    // } = next priority (lower), { = prev priority (higher) — shift+]/[
    if (key.matches('}', .{})) {
        applyPriorityChange(app, sp, pj, task, task.priority.next());
        return false;
    }
    if (key.matches('{', .{})) {
        applyPriorityChange(app, sp, pj, task, task.priority.prev());
        return false;
    }
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
        task_store.update(app.allocator, app.root_dir, sp, pj, task.id, .{ .subtasks = new_subs }) catch {};
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
            if (key.matches(vaxis.Key.escape, .{})) {
                app.mode = .normal;
                return false;
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                app.ob_step = 1;
                return false;
            }
        },
        1 => { // enter space name
            if (key.matches(vaxis.Key.escape, .{})) {
                app.mode = .normal;
                return false;
            }
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
                        if (std.mem.eql(u8, s, name)) {
                            app.space_idx = i;
                            break;
                        }
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
            if (key.matches(vaxis.Key.escape, .{})) {
                app.mode = .normal;
                return false;
            }
            if (key.matches(vaxis.Key.backspace, .{})) {
                if (app.ob_proj_len > 0) app.ob_proj_len -= 1;
                return false;
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                if (app.ob_proj_len > 0) {
                    const sp = app.ob_space_buf[0..app.ob_space_len];
                    const name = app.ob_proj_buf[0..app.ob_proj_len];
                    project_store.add(app.allocator, app.root_dir, sp, name) catch {};
                    app.reloadProjects();
                    for (app.projects, 0..) |p, i| {
                        if (std.mem.eql(u8, p, name)) {
                            app.project_idx = i;
                            break;
                        }
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
    const spaces_w: u16 = if (app.compact_mode) (if (app.active == .spaces) win.width else 0) else @max(16, win.width * 18 / 100);
    const projects_w: u16 = if (app.compact_mode) (if (app.active == .projects) win.width else 0) else @max(18, win.width * 23 / 100);
    const tasks_w: u16 = if (app.compact_mode) (if (app.active == .tasks) win.width else 0) else win.width -| spaces_w -| projects_w;

    // compute accent colors
    const space_accent = col_active_border;
    const proj_accent: vaxis.Color = if (app.spaces.len > 0 and app.space_idx < app.space_colors.len and app.space_colors[app.space_idx] != .default)
        itemColorToVaxis(app.space_colors[app.space_idx])
    else
        col_active_border;
    const tasks_accent: vaxis.Color = if (app.projects.len > 0 and app.project_idx < app.project_colors.len and app.project_colors[app.project_idx] != .default)
        itemColorToVaxis(app.project_colors[app.project_idx])
    else if (app.spaces.len > 0 and app.space_idx < app.space_colors.len and app.space_colors[app.space_idx] != .default)
        itemColorToVaxis(app.space_colors[app.space_idx])
    else
        col_active_border;

    // panels (always rendered — overlay draws on top afterwards)
    if (!app.compact_mode or app.active == .spaces) {
        const spaces_inner = renderPanel(win, 0, 0, spaces_w, panel_h, " Spaces ", app.active == .spaces, space_accent);
        renderStringList(spaces_inner, app.spaces, app.space_colors, app.space_idx, app.active == .spaces);
    }

    if (!app.compact_mode or app.active == .projects) {
        const proj_x: i17 = if (app.compact_mode) 0 else @intCast(spaces_w);
        const projects_inner = renderPanel(win, proj_x, 0, projects_w, panel_h, " Projects ", app.active == .projects, proj_accent);
        if (app.compact_mode and app.spaces.len > 0 and app.space_idx < app.spaces.len) {
            _ = win.print(&[_]vaxis.Segment{
                .{ .text = "- ", .style = .{ .fg = proj_accent, .bold = true } },
                .{ .text = app.spaces[app.space_idx], .style = .{ .fg = proj_accent, .bold = true } },
                .{ .text = " ", .style = .{ .fg = proj_accent, .bold = true } },
            }, .{ .row_offset = 0, .col_offset = @intCast(proj_x + 2 + @as(i17, " Projects ".len)), .wrap = .none });
        }
        renderProjectList(projects_inner, app.projects, app.project_progress, app.project_colors, app.project_idx, app.active == .projects, app.show_progress);
    }

    if (!app.compact_mode or app.active == .tasks) {
        const tasks_x: i17 = if (app.compact_mode) 0 else @intCast(spaces_w + projects_w);
        const tasks_inner = renderPanel(win, tasks_x, 0, tasks_w, panel_h, " Tasks ", app.active == .tasks, tasks_accent);
        if (app.compact_mode and app.projects.len > 0 and app.project_idx < app.projects.len) {
            _ = win.print(&[_]vaxis.Segment{
                .{ .text = "- ", .style = .{ .fg = tasks_accent, .bold = true } },
                .{ .text = app.projects[app.project_idx], .style = .{ .fg = tasks_accent, .bold = true } },
                .{ .text = " ", .style = .{ .fg = tasks_accent, .bold = true } },
            }, .{ .row_offset = 0, .col_offset = @intCast(tasks_x + 2 + @as(i17, " Tasks ".len)), .wrap = .none });
        }
        renderTasks(tasks_inner, app.tasks, app.task_idx, app.active == .tasks, app.alt_priority, app.task_color_grading);
    }

    renderBottom(win, app, panel_h);

    // overlays — drawn last so they sit on top
    switch (app.mode) {
        .settings, .settings_confirm => renderSettingsOverlay(win, app),
        .ext_overlay => renderExtOverlay(win, app),
        .onboarding => renderOnboardingOverlay(win, app),
        .task_detail => renderTaskDetailOverlay(win, app),
        .task_confirm_delete => renderConfirmDeleteDialog(win, app),
        .color_picker => renderColorPickerOverlay(win, app),
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
                .char = .{ .grapheme = " ", .width = 1 },
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
        .x_off = x,
        .y_off = y,
        .width = w,
        .height = h,
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
    const scroll: usize = if (sel >= visible) sel - visible + 1 else 0;
    for (items[scroll..], 0..) |item, vi| {
        if (vi >= visible) break;
        const idx = scroll + vi;
        const is_sel = idx == sel;
        const item_color = if (idx < colors.len) colors[idx] else model.ItemColor.default;
        const base_fg = if (item_color != .default) itemColorToVaxis(item_color) else col_normal_fg;
        const fg = base_fg;
        const bg = if (is_sel and active) col_selected_bg else vaxis.Color.default;
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
    const scroll: usize = if (sel >= visible) sel - visible + 1 else 0;
    for (items[scroll..], 0..) |item, vi| {
        if (vi >= visible) break;
        const idx = scroll + vi;
        const is_sel = idx == sel;
        const item_color = if (idx < project_colors.len) project_colors[idx] else model.ItemColor.default;
        const base_fg = if (item_color != .default) itemColorToVaxis(item_color) else col_normal_fg;
        const fg = base_fg;
        const bg = if (is_sel and active) col_selected_bg else vaxis.Color.default;
        if (show_progress and idx < progress.len) {
            const pct = @min(progress[idx], 100);
            const pct_str = pct_strs[pct];
            _ = win.print(&[_]vaxis.Segment{
                .{ .text = if (is_sel) " > " else "   ", .style = .{ .fg = fg, .bg = bg } },
                .{ .text = item, .style = .{ .fg = fg, .bg = bg, .bold = is_sel and active } },
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
    const scroll: usize = if (sel >= visible) sel - visible + 1 else 0;
    for (tasks[scroll..], 0..) |task, vi| {
        if (vi >= visible) break;
        const idx = scroll + vi;
        const is_sel = idx == sel;
        const bg = if (is_sel and active) col_selected_bg else vaxis.Color.default;
        const icon: []const u8 = switch (task.status) {
            .todo => "[ ]",
            .in_progress => "[~]",
            .in_review => "[?]",
            .done => "[x]",
        };
        const st_fg: vaxis.Color = switch (task.status) {
            .todo => col_todo_fg,
            .in_progress => col_in_progress_fg,
            .in_review => col_in_review_fg,
            .done => col_done_fg,
        };
        const pr_fg: vaxis.Color = switch (task.priority) {
            .low => col_low,
            .medium => col_medium,
            .high => col_high,
            .urgent => col_urgent,
        };
        const pr_badge: []const u8 = if (alt_priority) switch (task.priority) {
            .low => " ^  ",
            .medium => " ^^ ",
            .high => " ^^^",
            .urgent => " !!!",
        } else switch (task.priority) {
            .low => " [L]",
            .medium => " [M]",
            .high => " [H]",
            .urgent => " [U]",
        };
        const title_fg: vaxis.Color = if (task.status == .done)
            col_done_fg
        else if (task_color_grading)
            pr_fg
        else
            col_normal_fg;
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = if (is_sel) " > " else "   ", .style = .{ .fg = st_fg, .bg = bg } },
            .{ .text = icon, .style = .{ .fg = st_fg, .bg = bg } },
            .{ .text = pr_badge, .style = .{ .fg = pr_fg, .bg = bg } },
            .{ .text = " ", .style = .{ .bg = bg } },
            .{ .text = task.title, .style = .{ .fg = title_fg, .bg = bg, .strikethrough = task.status == .done } },
        }, .{ .row_offset = @intCast(vi), .col_offset = 0, .wrap = .none });
    }
}

fn renderBottom(win: vaxis.Window, app: *const App, panel_h: u16) void {
    // separator
    var i: u16 = 0;
    while (i < win.width) : (i += 1) {
        win.writeCell(i, panel_h, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = col_inactive_border },
        });
    }
    // hints
    _ = win.print(&[_]vaxis.Segment{
        .{ .text = " tab", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " panel  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "↑↓/jk", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " nav  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "a", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " add  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "d", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " delete  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " open  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "[/]", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " status  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "{/}", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " priority  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "i/I", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " import/export  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "s", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " settings  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "q", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " quit", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = panel_h + 1, .col_offset = 0, .wrap = .none });
    // context / input
    const ctx_y = panel_h + 2;
    if (app.mode == .input) {
        const prompt: []const u8 = switch (app.input_target) {
            .space => " New space name: ",
            .project => " New project name: ",
            .task => " New task title: ",
            .subtask => " New subtask: ",
            .description => " Description: ",
            .task_title => " Rename task: ",
        };
        _ = win.print(&[_]vaxis.Segment{
            .{ .text = prompt, .style = .{ .fg = col_input_prompt, .bold = true } },
            .{ .text = app.inputSlice(), .style = .{ .fg = col_normal_fg } },
            .{ .text = "|", .style = .{ .fg = col_input_prompt } },
        }, .{ .row_offset = ctx_y, .col_offset = 0, .wrap = .none });
    } else {
        if (app.currentSpace()) |sp| {
            if (app.currentProject()) |pj| {
                _ = win.print(&[_]vaxis.Segment{
                    .{ .text = " ", .style = .{ .fg = col_hint_text } },
                    .{ .text = sp, .style = .{ .fg = col_hint_text } },
                    .{ .text = " / ", .style = .{ .fg = col_hint_text } },
                    .{ .text = pj, .style = .{ .fg = col_hint_text } },
                }, .{ .row_offset = ctx_y, .col_offset = 0, .wrap = .none });
            }
        }
    }
}

// ── Overlay helpers ───────────────────────────────────────────────────────────

/// Fills an area with the overlay background, draws a border, returns the inner window.
fn makeOverlay(win: vaxis.Window, ow: u16, oh: u16) vaxis.Window {
    const x: u16 = (win.width -| ow) / 2;
    const y: u16 = (win.height -| oh) / 2;
    // flood-fill the footprint so panel content doesn't show through
    var row: u16 = 0;
    while (row < oh) : (row += 1) {
        var col: u16 = 0;
        while (col < ow) : (col += 1) {
            win.writeCell(x + col, y + row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = col_overlay_bg },
            });
        }
    }
    return win.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = ow,
        .height = oh,
        .border = .{ .where = .all, .style = .{ .fg = col_active_border, .bg = col_overlay_bg }, .glyphs = .single_rounded },
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

fn countTextRows(text: []const u8, max_rows: u16) u16 {
    if (text.len == 0) return 1;

    var rows: u16 = 1;
    for (text) |ch| {
        if (ch == '\n') {
            if (rows == max_rows) return max_rows;
            rows += 1;
        }
    }
    return rows;
}

fn renderIndentedMultiline(inner: vaxis.Window, start_row: u16, text: []const u8, style: vaxis.Style, max_rows: u16) u16 {
    var rows: u16 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (rows < max_rows) : (rows += 1) {
        const line = lines.next() orelse break;
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  ", .style = .{} },
            .{ .text = line, .style = style },
        }, .{ .row_offset = start_row + rows, .col_offset = 0, .wrap = .none });
    }
    return @max(rows, 1);
}

fn lastVisibleLine(text: []const u8, max_rows: u16) []const u8 {
    var line: []const u8 = "";
    var rows: u16 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (rows < max_rows) : (rows += 1) {
        line = lines.next() orelse break;
    }
    return line;
}

// ── Extension overlay ─────────────────────────────────────────────────────────

fn renderExtOverlay(win: vaxis.Window, app: *const App) void {
    const manifest = app.ext_manifest orelse return;
    const ext_name = if (app.extensions.len > 0) app.extensions[app.ext_idx].name else manifest.name;

    const ow: u16 = 64;
    const cfg_rows: u16 = @intCast(@max(manifest.config_keys.len, 1) * 2);
    const oh: u16 = 11 + cfg_rows;
    const inner = makeOverlay(win, ow, oh);

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = " Extension: ", .style = .{ .fg = col_active_border, .bold = true } },
        .{ .text = ext_name, .style = .{ .fg = col_selected_fg, .bold = true } },
    }, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });

    if (manifest.description.len > 0) {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = manifest.description, .style = .{ .fg = col_hint_text } },
        }, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });
    }

    // Capabilities summary
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "capabilities: ", .style = .{ .fg = col_dim_fg } },
        .{ .text = if (manifest.can_import) "import " else "", .style = .{ .fg = col_low } },
        .{ .text = if (manifest.can_export) "export " else "", .style = .{ .fg = col_low } },
        .{ .text = if (manifest.can_setup) "setup" else "", .style = .{ .fg = col_low } },
    }, .{ .row_offset = 3, .col_offset = 2, .wrap = .none });

    // Config entries
    var row: u16 = 5;
    if (manifest.config_keys.len == 0) {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  (this extension has no config keys)", .style = .{ .fg = col_dim_fg, .italic = true } },
        }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
        row += 2;
    }
    for (manifest.config_keys, 0..) |ck, i| {
        const is_sel = i == app.ext_cfg_idx;
        const is_editing = is_sel and app.ext_editing;
        const fg = if (is_sel) col_selected_fg else col_normal_fg;
        const bg = if (is_sel) col_selected_bg else vaxis.Color.default;

        // Value: editing shows the live input; secrets are masked otherwise
        var mask_buf: [24]u8 = undefined;
        const stored: []const u8 = if (i < app.ext_cfg_values.len) app.ext_cfg_values[i] else "";
        const value: []const u8 = blk: {
            if (is_editing) break :blk app.ext_input_buf[0..app.ext_input_len];
            if (stored.len == 0) break :blk "(not set)";
            if (ck.secret) {
                const tail = @min(4, stored.len);
                const stars = @min(@as(usize, 8), mask_buf.len -| tail);
                @memset(mask_buf[0..stars], '*');
                std.mem.copyForwards(u8, mask_buf[stars .. stars + tail], stored[stored.len - tail ..]);
                break :blk mask_buf[0 .. stars + tail];
            }
            break :blk stored;
        };

        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = if (is_sel) " >  " else "    ", .style = .{ .fg = fg, .bg = bg } },
            .{ .text = ck.label, .style = .{ .fg = fg, .bg = bg, .bold = is_sel } },
            .{ .text = ":  ", .style = .{ .fg = fg, .bg = bg } },
            .{ .text = value, .style = .{ .fg = if (stored.len > 0 or is_editing) col_normal_fg else col_dim_fg, .bg = bg, .italic = stored.len == 0 and !is_editing } },
            .{ .text = if (is_editing) "|" else "", .style = .{ .fg = col_input_prompt, .bg = bg } },
        }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
        row += 2;
    }

    // CLI hints for linking / setup
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "link a project:  todo ext link <space> <project> ", .style = .{ .fg = col_dim_fg } },
        .{ .text = ext_name, .style = .{ .fg = col_dim_fg } },
    }, .{ .row_offset = row + 1, .col_offset = 2, .wrap = .none });
    if (manifest.can_setup) {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "browser login:   todo ext setup ", .style = .{ .fg = col_dim_fg } },
            .{ .text = ext_name, .style = .{ .fg = col_dim_fg } },
        }, .{ .row_offset = row + 2, .col_offset = 2, .wrap = .none });
    }

    if (app.ext_editing) {
        overlayHints(inner, oh -| 2, &[_]vaxis.Segment{
            .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
            .{ .text = " save  ", .style = .{ .fg = col_hint_text } },
            .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
            .{ .text = " cancel", .style = .{ .fg = col_hint_text } },
        });
    } else {
        overlayHints(inner, oh -| 2, &[_]vaxis.Segment{
            .{ .text = "↑↓/jk", .style = .{ .fg = col_hint_key, .bold = true } },
            .{ .text = " nav  ", .style = .{ .fg = col_hint_text } },
            .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
            .{ .text = " edit  ", .style = .{ .fg = col_hint_text } },
            .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
            .{ .text = " close", .style = .{ .fg = col_hint_text } },
        });
    }
}

// ── Settings overlay ──────────────────────────────────────────────────────────

fn renderSettingsOverlay(win: vaxis.Window, app: *const App) void {
    const ow: u16 = 60;
    const oh: u16 = 22;
    const inner = makeOverlay(win, ow, oh);
    overlayTitle(inner, " Settings");

    // ── Tab bar (row 2) ──
    var tab_col: u16 = 1;
    for (settings_tab_labels, 0..) |label, ti| {
        const is_active = ti == app.settings_tab;
        const fg = if (is_active) col_selected_fg else col_normal_fg;
        const bg = if (is_active) col_selected_bg else vaxis.Color.default;
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = if (is_active) "[" else " ", .style = .{ .fg = fg, .bg = bg, .bold = is_active } },
            .{ .text = label, .style = .{ .fg = fg, .bg = bg, .bold = is_active } },
            .{ .text = if (is_active) "]" else " ", .style = .{ .fg = fg, .bg = bg, .bold = is_active } },
        }, .{ .row_offset = 2, .col_offset = tab_col, .wrap = .none });
        tab_col += @as(u16, @intCast(label.len)) + 2;
        if (ti + 1 < settings_tab_labels.len) {
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = "  ", .style = .{ .fg = col_inactive_border } },
            }, .{ .row_offset = 2, .col_offset = tab_col, .wrap = .none });
            tab_col += 2;
        }
    }

    // Separator below tab bar (row 3)
    var sep_col: u16 = 1;
    while (sep_col < ow -| 2) : (sep_col += 1) {
        inner.writeCell(sep_col, 3, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = col_inactive_border },
        });
    }

    // ── Entries for the current tab (starting row 5) ──
    var row: u16 = 5;
    if (app.settings_tab == ext_tab_index) {
        renderExtensionsTab(inner, app, row, oh);
        if (app.mode == .settings_confirm) renderConfirmDialog(win);
        return;
    }
    const te = tabEntries(app.settings_tab);
    for (te, 0..) |entry, ei| {
        switch (entry.kind) {
            .section => {},
            .toggle => {
                const is_sel = ei == app.settings_idx;
                const fg = if (is_sel) col_selected_fg else col_normal_fg;
                const bg = if (is_sel) col_selected_bg else vaxis.Color.default;
                const checked: bool = switch (entry.id) {
                    .show_progress => app.show_progress,
                    .alt_priority => app.alt_priority,
                    .task_color_grading => app.task_color_grading,
                    .compact_mode => app.compact_mode,
                    .hide_done => app.hide_done,
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
                const fg = if (is_sel) col_selected_fg else col_normal_fg;
                const bg = if (is_sel) col_selected_bg else vaxis.Color.default;
                if (entry.id == .task_sort) {
                    const sort_label: []const u8 = switch (app.task_sort) {
                        .by_id => "Sort order: Default",
                        .by_priority_desc => "Sort order: Priority",
                        .by_status => "Sort order: Status",
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
        }
    }

    overlayHints(inner, oh -| 3, &[_]vaxis.Segment{
        .{ .text = "h/l", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " tabs  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "↑↓/jk", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " nav  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " select  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " close", .style = .{ .fg = col_hint_text } },
    });

    if (app.mode == .settings_confirm) renderConfirmDialog(win);
}

/// Renders the dynamic Extensions tab inside the settings overlay:
/// the discovered extension executables, plus its own hint row.
fn renderExtensionsTab(inner: vaxis.Window, app: *const App, start_row: u16, oh: u16) void {
    var row: u16 = start_row;

    if (app.extensions.len == 0) {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "    No extensions installed.", .style = .{ .fg = col_dim_fg, .italic = true } },
        }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "    Drop executables into ~/.todo/extensions", .style = .{ .fg = col_hint_text } },
        }, .{ .row_offset = row + 1, .col_offset = 0, .wrap = .none });
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "    then run:  todo ext list", .style = .{ .fg = col_hint_text } },
        }, .{ .row_offset = row + 2, .col_offset = 0, .wrap = .none });
    } else {
        for (app.extensions, 0..) |ref, i| {
            const is_sel = i == app.ext_idx;
            const fg = if (is_sel) col_selected_fg else col_normal_fg;
            const bg = if (is_sel) col_selected_bg else vaxis.Color.default;
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = if (is_sel) " >  " else "    ", .style = .{ .fg = fg, .bg = bg } },
                .{ .text = ref.name, .style = .{ .fg = fg, .bg = bg, .bold = is_sel } },
            }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
            row += 2;
            if (row >= oh -| 5) break;
        }
    }

    overlayHints(inner, oh -| 3, &[_]vaxis.Segment{
        .{ .text = "h/l", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " tabs  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "↑↓/jk", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " nav  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " configure  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " close", .style = .{ .fg = col_hint_text } },
    });
}

fn renderConfirmDialog(win: vaxis.Window) void {
    const cw: u16 = 48;
    const ch: u16 = 7;
    const inner = makeOverlay(win, cw, ch);
    overlayTitle(inner, " Hard Reset");

    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = " ⚠  This will permanently delete ALL your data.", .style = .{ .fg = col_warning, .bold = true } },
    }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "    Spaces, projects and tasks cannot be recovered.", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = 3, .col_offset = 0, .wrap = .none });

    overlayHints(inner, ch -| 2, &[_]vaxis.Segment{
        .{ .text = "enter", .style = .{ .fg = col_warning, .bold = true } },
        .{ .text = " confirm  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " cancel", .style = .{ .fg = col_hint_text } },
    });
}

// ── Onboarding overlay ────────────────────────────────────────────────────────

fn renderConfirmDeleteDialog(win: vaxis.Window, app: *const App) void {
    const cw: u16 = 52;
    const ch: u16 = 7;
    const inner = makeOverlay(win, cw, ch);
    const label: []const u8 = switch (app.confirm_delete_panel) {
        .spaces => "Delete this space and ALL its contents?",
        .projects => "Delete this project and ALL its tasks?",
        .tasks => "Delete this task?",
    };
    overlayTitle(inner, " Confirm Delete");
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = " ⚠  ", .style = .{ .fg = col_warning } },
        .{ .text = label, .style = .{ .fg = col_warning, .bold = true } },
    }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "    This action cannot be undone.", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = 3, .col_offset = 0, .wrap = .none });
    overlayHints(inner, ch -| 2, &[_]vaxis.Segment{
        .{ .text = "enter", .style = .{ .fg = col_warning, .bold = true } },
        .{ .text = " confirm  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " cancel", .style = .{ .fg = col_hint_text } },
    });
}

fn renderTaskDetailOverlay(win: vaxis.Window, app: *const App) void {
    const task = app.currentTask() orelse return;

    const ow: u16 = @min(win.width -| 4, 70);
    const max_description_rows: u16 = 5;
    const is_editing_desc = app.mode == .input and app.input_target == .description;
    const description_text = if (is_editing_desc) app.inputSlice() else task.description;
    const description_rows = countTextRows(description_text, max_description_rows);
    // Height: title(1) + gap(1) + status+priority(1) + [integration(1) + gap(1) if linked] +
    //         gap(1) + desc_label(1) + desc rows + gap(1) + subtask_label(1) + subtasks(up to 6) + hints(3)
    const has_integration = task.external_id.len > 0;
    const integration_rows: u16 = if (has_integration) 2 else 0; // row + extra gap
    const subtask_rows: u16 = @intCast(@min(task.subtasks.len + 1, 8));
    const oh: u16 = 13 + subtask_rows + integration_rows + (description_rows -| 1);

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
            .{ .text = " ", .style = .{ .fg = col_active_border, .bold = true } },
            .{ .text = task.title, .style = .{ .fg = col_active_border, .bold = true } },
        }, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    }

    // Status + Priority row
    const status_icon: []const u8 = switch (task.status) {
        .todo => "[ ]",
        .in_progress => "[~]",
        .in_review => "[?]",
        .done => "[x]",
    };
    const status_label: []const u8 = switch (task.status) {
        .todo => "todo",
        .in_progress => "in-progress",
        .in_review => "in-review",
        .done => "done",
    };
    const st_fg: vaxis.Color = switch (task.status) {
        .todo => col_todo_fg,
        .in_progress => col_in_progress_fg,
        .in_review => col_in_review_fg,
        .done => col_done_fg,
    };
    const pr_fg: vaxis.Color = switch (task.priority) {
        .low => col_low,
        .medium => col_medium,
        .high => col_high,
        .urgent => col_urgent,
    };
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "  Status  ", .style = .{ .fg = col_hint_text } },
        .{ .text = status_icon, .style = .{ .fg = st_fg } },
        .{ .text = " ", .style = .{} },
        .{ .text = status_label, .style = .{ .fg = st_fg, .bold = true } },
        .{ .text = "    Priority  ", .style = .{ .fg = col_hint_text } },
        .{ .text = task.priority.toString(), .style = .{ .fg = pr_fg, .bold = true } },
    }, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });

    // Extension row (only when task is linked to an external item)
    var detail_row: u16 = 4;
    if (has_integration) {
        const synced_label = if (task.synced_at.len > 0) task.synced_at else "never";
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  Extension  ", .style = .{ .fg = col_hint_text } },
            .{ .text = task.source, .style = .{ .fg = col_hint_key, .bold = true } },
            .{ .text = "  ", .style = .{} },
            .{ .text = task.external_id, .style = .{ .fg = col_normal_fg } },
            .{ .text = "  synced ", .style = .{ .fg = col_dim_fg } },
            .{ .text = synced_label, .style = .{ .fg = col_dim_fg } },
        }, .{ .row_offset = 3, .col_offset = 0, .wrap = .none });
        detail_row = 6; // shift subsequent rows down by 2
    }

    // Description
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "  Description ", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = detail_row, .col_offset = 0, .wrap = .none });

    if (is_editing_desc) {
        _ = renderIndentedMultiline(
            inner,
            detail_row + 1,
            app.inputSlice(),
            .{ .fg = col_normal_fg },
            max_description_rows,
        );
        const cursor_line = lastVisibleLine(app.inputSlice(), max_description_rows);
        const cursor_col: u16 = @intCast(@min(cursor_line.len + 2, @as(usize, ow -| 3)));
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "|", .style = .{ .fg = col_input_prompt } },
        }, .{ .row_offset = detail_row + description_rows, .col_offset = cursor_col, .wrap = .none });
    } else if (task.description.len > 0) {
        _ = renderIndentedMultiline(
            inner,
            detail_row + 1,
            task.description,
            .{ .fg = col_normal_fg },
            max_description_rows,
        );
    } else {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  (none — press e to add)", .style = .{ .fg = col_dim_fg, .italic = true } },
        }, .{ .row_offset = detail_row + 1, .col_offset = 0, .wrap = .none });
    }

    // Subtasks
    const subtask_label_row = detail_row + description_rows + 2;
    _ = inner.print(&[_]vaxis.Segment{
        .{ .text = "  Subtasks ", .style = .{ .fg = col_hint_text } },
    }, .{ .row_offset = subtask_label_row, .col_offset = 0, .wrap = .none });

    const subtask_base_row = subtask_label_row + 1;
    const is_adding_sub = app.mode == .input and app.input_target == .subtask;
    if (task.subtasks.len == 0 and !is_adding_sub) {
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = "  (none — press a to add)", .style = .{ .fg = col_dim_fg, .italic = true } },
        }, .{ .row_offset = subtask_base_row, .col_offset = 0, .wrap = .none });
    } else {
        const max_show: usize = 6;
        const show = @min(task.subtasks.len, max_show);
        const scroll: usize = if (app.detail_subtask_idx >= max_show)
            app.detail_subtask_idx - max_show + 1
        else
            0;
        for (task.subtasks[scroll..][0..@min(show, task.subtasks.len -| scroll)], 0..) |st, vi| {
            const idx = scroll + vi;
            const is_sel = idx == app.detail_subtask_idx;
            const bg = if (is_sel) col_selected_bg else vaxis.Color.default;
            const fg = if (is_sel) col_selected_fg else col_normal_fg;
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = if (is_sel) "  > " else "    ", .style = .{ .fg = fg, .bg = bg } },
                .{ .text = if (st.done) "[x] " else "[ ] ", .style = .{ .fg = if (st.done) col_low else col_normal_fg, .bg = bg } },
                .{ .text = st.title, .style = .{ .fg = if (st.done) col_done_fg else fg, .bg = bg, .strikethrough = st.done } },
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
        .{ .text = "[/]", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " status  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "{/}", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " priority  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "X", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " done  ", .style = .{ .fg = col_hint_text } },
    });
    overlayHints(inner, hint_row + 1, &[_]vaxis.Segment{
        .{ .text = "r", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " rename  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "e", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " desc  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "a", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " subtask  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "d", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " del sub  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " close", .style = .{ .fg = col_hint_text } },
    });
}

// ── Colour picker overlay ─────────────────────────────────────────────────────

const color_picker_names = [_][]const u8{
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
        .spaces => " Space Colour",
        .projects => " Project Colour",
        .tasks => " Colour",
    };
    overlayTitle(inner, title);

    for (color_picker_names, 0..) |name, i| {
        const is_sel = i == app.color_picker_idx;
        const item_col = itemColorToVaxis(color_picker_values[i]);
        const bg = if (is_sel) col_selected_bg else vaxis.Color.default;
        _ = inner.print(&[_]vaxis.Segment{
            .{ .text = if (is_sel) " > " else "   ", .style = .{ .fg = col_selected_fg, .bg = bg } },
            .{ .text = "* ", .style = .{ .fg = item_col, .bg = bg } },
            .{ .text = name, .style = .{ .fg = if (is_sel) col_selected_fg else col_normal_fg, .bg = bg, .bold = is_sel } },
        }, .{ .row_offset = @intCast(2 + i), .col_offset = 0, .wrap = .none });
    }

    overlayHints(inner, oh -| 2, &[_]vaxis.Segment{
        .{ .text = "↑↓/jk", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " nav  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
        .{ .text = " pick  ", .style = .{ .fg = col_hint_text } },
        .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
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
                .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " get started  ", .style = .{ .fg = col_hint_text } },
                .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " skip", .style = .{ .fg = col_hint_text } },
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
                .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " confirm  ", .style = .{ .fg = col_hint_text } },
                .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " skip", .style = .{ .fg = col_hint_text } },
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
                .{ .text = " Project in '", .style = .{ .fg = col_input_prompt, .bold = true } },
                .{ .text = app.ob_space_buf[0..app.ob_space_len], .style = .{ .fg = col_input_prompt, .bold = true } },
                .{ .text = "': ", .style = .{ .fg = col_input_prompt, .bold = true } },
                .{ .text = app.ob_proj_buf[0..app.ob_proj_len], .style = .{ .fg = col_normal_fg } },
                .{ .text = "|", .style = .{ .fg = col_input_prompt } },
            }, .{ .row_offset = 5, .col_offset = 0, .wrap = .none });
            overlayHints(inner, oh -| 2, &[_]vaxis.Segment{
                .{ .text = "enter", .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " confirm  ", .style = .{ .fg = col_hint_text } },
                .{ .text = "esc", .style = .{ .fg = col_hint_key, .bold = true } },
                .{ .text = " skip", .style = .{ .fg = col_hint_text } },
            });
        },
        3 => {
            overlayTitle(inner, " You're all set!");
            _ = inner.print(&[_]vaxis.Segment{
                .{ .text = " \xe2\x9c\x93  Space '", .style = .{ .fg = col_low, .bold = true } },
                .{ .text = app.ob_space_buf[0..app.ob_space_len], .style = .{ .fg = col_low, .bold = true } },
                .{ .text = "' and project '", .style = .{ .fg = col_low, .bold = true } },
                .{ .text = app.ob_proj_buf[0..app.ob_proj_len], .style = .{ .fg = col_low, .bold = true } },
                .{ .text = "' created.", .style = .{ .fg = col_low, .bold = true } },
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
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (handleKey(&app, key)) break;
            },
            .winsize => |ws| {
                try vx.resize(allocator, ttywriter, ws);
            },
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
