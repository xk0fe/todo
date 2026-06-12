/// Task persistence — tasks are NNNN.toml files inside <space>/<project>/tasks/.
const std = @import("std");
const model = @import("../model.zig");
const toml  = @import("toml.zig");

pub const TaskFilter = enum { all, todo, in_progress, in_review, done, active };

pub const AddOptions = struct {
    title:       []const u8,
    priority:    model.Priority = .medium,
    description: []const u8 = "",
    due:         []const u8 = "",
    external_id: []const u8 = "",
    source:      []const u8 = "", // owning extension name
    synced_at:   []const u8 = "",
    url:         []const u8 = "",
};

pub const UpdateOptions = struct {
    title:       ?[]const u8 = null,
    status:      ?model.Status = null,
    priority:    ?model.Priority = null,
    description: ?[]const u8 = null,
    due:         ?[]const u8 = null,
    /// When non-null, replaces the entire subtask list.
    subtasks:    ?[]const model.SubTask = null,
    external_id: ?[]const u8 = null,
    source:      ?[]const u8 = null,
    synced_at:   ?[]const u8 = null,
    url:         ?[]const u8 = null,
};

/// Opens (creating if needed) the tasks directory for a given space/project.
fn openTasksDir(root_dir: std.fs.Dir, space: []const u8, project: []const u8) !std.fs.Dir {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/tasks", .{ space, project }) catch
        return error.PathTooLong;
    var proj_path_buf: [512]u8 = undefined;
    const proj_path = std.fmt.bufPrint(&proj_path_buf, "{s}/{s}", .{ space, project }) catch
        return error.PathTooLong;
    {
        var proj_dir = root_dir.openDir(proj_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ProjectNotFound,
            else => return err,
        };
        proj_dir.close();
    }
    return root_dir.makeOpenPath(path, .{ .iterate = true });
}

fn taskFilename(buf: *[9]u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}.toml", .{id}) catch unreachable;
}

fn nextTaskId(tasks_dir: std.fs.Dir) !u32 {
    var max_id: u32 = 0;
    var iter = tasks_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        const stem = entry.name[0 .. entry.name.len - 5];
        const id = std.fmt.parseInt(u32, stem, 10) catch continue;
        if (id > max_id) max_id = id;
    }
    return max_id + 1;
}

fn readTask(allocator: std.mem.Allocator, tasks_dir: std.fs.Dir, id: u32) !model.Task {
    var name_buf: [9]u8 = undefined;
    const filename = taskFilename(&name_buf, id);

    const file = tasks_dir.openFile(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.TaskNotFound,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    var map = try toml.parse(allocator, content);
    defer toml.freeMap(allocator, &map);

    const title = try allocator.dupe(u8, map.get("title") orelse return error.InvalidTaskFile);
    errdefer allocator.free(title);
    const status = try model.Status.fromString(map.get("status") orelse return error.InvalidTaskFile);
    const priority = try model.Priority.fromString(map.get("priority") orelse return error.InvalidTaskFile);
    // Support both "description" and legacy "notes" key
    const description = try allocator.dupe(u8, map.get("description") orelse map.get("notes") orelse "");
    errdefer allocator.free(description);
    const created = try allocator.dupe(u8, map.get("created") orelse return error.InvalidTaskFile);
    errdefer allocator.free(created);
    const due = try allocator.dupe(u8, map.get("due") orelse "");
    errdefer allocator.free(due);

    // Parse subtasks
    const subtask_count_str = map.get("subtask_count") orelse "0";
    const subtask_count = std.fmt.parseInt(usize, subtask_count_str, 10) catch 0;

    var subtasks_list: std.ArrayListUnmanaged(model.SubTask) = .empty;
    errdefer {
        for (subtasks_list.items) |st| st.deinit(allocator);
        subtasks_list.deinit(allocator);
    }
    for (0..subtask_count) |i| {
        var title_key_buf: [32]u8 = undefined;
        var done_key_buf:  [32]u8 = undefined;
        const title_key = std.fmt.bufPrint(&title_key_buf, "subtask_{d}",      .{i}) catch continue;
        const done_key  = std.fmt.bufPrint(&done_key_buf,  "subtask_{d}_done", .{i}) catch continue;
        const st_title = try allocator.dupe(u8, map.get(title_key) orelse "");
        const done_str = map.get(done_key) orelse "false";
        try subtasks_list.append(allocator, .{
            .title = st_title,
            .done  = std.mem.eql(u8, done_str, "true"),
        });
    }
    const subtasks = try subtasks_list.toOwnedSlice(allocator);
    errdefer {
        for (subtasks) |st| st.deinit(allocator);
        allocator.free(subtasks);
    }

    const external_id = try allocator.dupe(u8, map.get("external_id") orelse "");
    errdefer allocator.free(external_id);
    // "integration_source" is the on-disk key; it now holds an extension name.
    const source = try allocator.dupe(u8, map.get("integration_source") orelse "");
    errdefer allocator.free(source);
    const synced_at = try allocator.dupe(u8, map.get("synced_at") orelse "");
    errdefer allocator.free(synced_at);
    const url = try allocator.dupe(u8, map.get("url") orelse "");
    errdefer allocator.free(url);

    return model.Task{
        .id          = id,
        .title       = title,
        .status      = status,
        .priority    = priority,
        .description = description,
        .created     = created,
        .due         = due,
        .subtasks    = subtasks,
        .external_id = external_id,
        .source      = source,
        .synced_at   = synced_at,
        .url         = url,
    };
}

fn writeTask(allocator: std.mem.Allocator, tasks_dir: std.fs.Dir, task: model.Task) !void {
    // Build KV list dynamically to accommodate variable-length subtask entries.
    var kvs:     std.ArrayListUnmanaged(toml.KV) = .empty;
    defer kvs.deinit(allocator);
    var key_bufs: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (key_bufs.items) |kb| allocator.free(kb);
        key_bufs.deinit(allocator);
    }

    try kvs.append(allocator, .{ .key = "title",       .value = task.title });
    try kvs.append(allocator, .{ .key = "status",      .value = task.status.toString() });
    try kvs.append(allocator, .{ .key = "priority",    .value = task.priority.toString() });
    try kvs.append(allocator, .{ .key = "description", .value = task.description });
    try kvs.append(allocator, .{ .key = "created",     .value = task.created });
    try kvs.append(allocator, .{ .key = "due",         .value = task.due });

    var count_buf: [16]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{task.subtasks.len}) catch unreachable;
    try kvs.append(allocator, .{ .key = "subtask_count", .value = count_str });

    for (task.subtasks, 0..) |st, i| {
        const title_key = try std.fmt.allocPrint(allocator, "subtask_{d}",      .{i});
        try key_bufs.append(allocator, title_key);
        try kvs.append(allocator, .{ .key = title_key, .value = st.title });

        const done_key = try std.fmt.allocPrint(allocator, "subtask_{d}_done", .{i});
        try key_bufs.append(allocator, done_key);
        try kvs.append(allocator, .{ .key = done_key, .value = if (st.done) "true" else "false" });
    }

    // Write extension link fields only when task is linked to an external item
    if (task.external_id.len > 0) {
        try kvs.append(allocator, .{ .key = "external_id",        .value = task.external_id });
        try kvs.append(allocator, .{ .key = "integration_source", .value = task.source });
        try kvs.append(allocator, .{ .key = "synced_at",          .value = task.synced_at });
        try kvs.append(allocator, .{ .key = "url",                .value = task.url });
    }

    const content = try toml.serialize(allocator, kvs.items);
    defer allocator.free(content);

    var name_buf: [9]u8 = undefined;
    const filename = taskFilename(&name_buf, task.id);
    const file = try tasks_dir.createFile(filename, .{});
    defer file.close();
    try file.writeAll(content);
}

fn currentDate(buf: *[10]u8) []const u8 {
    const ts: u64 = @intCast(std.time.timestamp());
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day  = epoch_secs.getEpochDay();
    const year_day   = epoch_day.calculateYearDay();
    const month_day  = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch unreachable;
}

pub fn add(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8, opts: AddOptions) !u32 {
    var tasks_dir = try openTasksDir(root_dir, space, project);
    defer tasks_dir.close();

    const id = try nextTaskId(tasks_dir);
    var date_buf: [10]u8 = undefined;
    const task = model.Task{
        .id          = id,
        .title       = opts.title,
        .status      = .todo,
        .priority    = opts.priority,
        .description = opts.description,
        .created     = currentDate(&date_buf),
        .due         = opts.due,
        .subtasks    = &.{},
        .external_id = opts.external_id,
        .source      = opts.source,
        .synced_at   = opts.synced_at,
        .url         = opts.url,
    };
    try writeTask(allocator, tasks_dir, task);
    return id;
}

pub fn list(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8, filter: TaskFilter) ![]model.Task {
    var tasks_dir = try openTasksDir(root_dir, space, project);
    defer tasks_dir.close();

    var result: std.ArrayListUnmanaged(model.Task) = .empty;
    errdefer {
        for (result.items) |t| t.deinit(allocator);
        result.deinit(allocator);
    }

    var ids: std.ArrayListUnmanaged(u32) = .empty;
    defer ids.deinit(allocator);
    var iter = tasks_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        const stem = entry.name[0 .. entry.name.len - 5];
        const id = std.fmt.parseInt(u32, stem, 10) catch continue;
        try ids.append(allocator, id);
    }
    std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));

    for (ids.items) |id| {
        const task = readTask(allocator, tasks_dir, id) catch continue;
        const keep = switch (filter) {
            .all        => true,
            .todo       => task.status == .todo,
            .in_progress=> task.status == .in_progress,
            .in_review  => task.status == .in_review,
            .done       => task.status == .done,
            .active     => task.status == .todo or task.status == .in_progress or task.status == .in_review,
        };
        if (keep) {
            try result.append(allocator, task);
        } else {
            task.deinit(allocator);
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn get(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8, id: u32) !model.Task {
    var tasks_dir = try openTasksDir(root_dir, space, project);
    defer tasks_dir.close();
    return readTask(allocator, tasks_dir, id);
}

pub fn markDone(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8, id: u32) !void {
    try update(allocator, root_dir, space, project, id, .{ .status = .done });
}

pub fn update(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8, id: u32, opts: UpdateOptions) !void {
    var tasks_dir = try openTasksDir(root_dir, space, project);
    defer tasks_dir.close();

    var task = try readTask(allocator, tasks_dir, id);
    defer task.deinit(allocator);

    const new_title = if (opts.title) |t| try allocator.dupe(u8, t) else try allocator.dupe(u8, task.title);
    errdefer allocator.free(new_title);
    const new_description = if (opts.description) |d| try allocator.dupe(u8, d) else try allocator.dupe(u8, task.description);
    errdefer allocator.free(new_description);
    const new_due = if (opts.due) |d| try allocator.dupe(u8, d) else try allocator.dupe(u8, task.due);
    errdefer allocator.free(new_due);
    const new_created = try allocator.dupe(u8, task.created);
    errdefer allocator.free(new_created);
    const new_external_id = if (opts.external_id) |e| try allocator.dupe(u8, e) else try allocator.dupe(u8, task.external_id);
    errdefer allocator.free(new_external_id);
    const new_source = if (opts.source) |s| try allocator.dupe(u8, s) else try allocator.dupe(u8, task.source);
    errdefer allocator.free(new_source);
    const new_synced_at = if (opts.synced_at) |s| try allocator.dupe(u8, s) else try allocator.dupe(u8, task.synced_at);
    errdefer allocator.free(new_synced_at);
    const new_url = if (opts.url) |u| try allocator.dupe(u8, u) else try allocator.dupe(u8, task.url);
    errdefer allocator.free(new_url);

    // Subtasks: replace with opts.subtasks if provided, else copy existing
    var new_subtasks: []model.SubTask = undefined;
    if (opts.subtasks) |subs| {
        new_subtasks = try allocator.alloc(model.SubTask, subs.len);
        errdefer allocator.free(new_subtasks);
        for (subs, 0..) |st, i| {
            new_subtasks[i] = .{ .title = try allocator.dupe(u8, st.title), .done = st.done };
        }
    } else {
        new_subtasks = try allocator.alloc(model.SubTask, task.subtasks.len);
        errdefer allocator.free(new_subtasks);
        for (task.subtasks, 0..) |st, i| {
            new_subtasks[i] = .{ .title = try allocator.dupe(u8, st.title), .done = st.done };
        }
    }
    errdefer {
        for (new_subtasks) |st| st.deinit(allocator);
        allocator.free(new_subtasks);
    }

    const updated = model.Task{
        .id          = task.id,
        .title       = new_title,
        .status      = opts.status   orelse task.status,
        .priority    = opts.priority orelse task.priority,
        .description = new_description,
        .created     = new_created,
        .due         = new_due,
        .subtasks    = new_subtasks,
        .external_id = new_external_id,
        .source      = new_source,
        .synced_at   = new_synced_at,
        .url         = new_url,
    };
    defer updated.deinit(allocator);

    try writeTask(allocator, tasks_dir, updated);
}

pub fn remove(root_dir: std.fs.Dir, space: []const u8, project: []const u8, id: u32) !void {
    var tasks_dir = try openTasksDir(root_dir, space, project);
    defer tasks_dir.close();

    var name_buf: [9]u8 = undefined;
    const filename = taskFilename(&name_buf, id);
    tasks_dir.deleteFile(filename) catch |err| switch (err) {
        error.FileNotFound => return error.TaskNotFound,
        else => return err,
    };
}

/// Calculates the overall progress percentage for a project (0–100).
/// Progress = average of each task's status weight.
pub fn projectProgress(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8) u32 {
    const tasks = list(allocator, root_dir, space, project, .all) catch return 0;
    defer {
        for (tasks) |t| t.deinit(allocator);
        allocator.free(tasks);
    }
    if (tasks.len == 0) return 0;
    var weighted_sum: u32 = 0;
    var weight_total: u32 = 0;
    for (tasks) |t| {
        const pw = t.priority.progressWeight();
        weighted_sum += t.status.weight() * pw;
        weight_total += pw;
    }
    return weighted_sum / weight_total;
}

// ── test helpers ──────────────────────────────────────────────────────────────

fn makeProject(root_dir: std.fs.Dir, space: []const u8, project: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ space, project });
    try root_dir.makePath(path);
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "add creates 0001.toml and returns id 1" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    const id = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "First task" });
    try std.testing.expectEqual(@as(u32, 1), id);

    var tasks_dir = try tmp.dir.openDir("work/api/tasks", .{});
    defer tasks_dir.close();
    const file = try tasks_dir.openFile("0001.toml", .{});
    file.close();
}

test "add sequential IDs" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    const id1 = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task one" });
    const id2 = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task two" });
    const id3 = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task three" });
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);
    try std.testing.expectEqual(@as(u32, 3), id3);
}

test "get returns correct task fields" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title    = "Fix the bug",
        .priority = .high,
        .due      = "2026-12-01",
    });

    const task = try get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), task.id);
    try std.testing.expectEqualStrings("Fix the bug", task.title);
    try std.testing.expectEqual(model.Status.todo, task.status);
    try std.testing.expectEqual(model.Priority.high, task.priority);
    try std.testing.expectEqualStrings("2026-12-01", task.due);
}

test "get nonexistent task returns TaskNotFound" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");
    try std.testing.expectError(error.TaskNotFound, get(std.testing.allocator, tmp.dir, "work", "api", 99));
}

test "list with filter" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task A" });
    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task B" });
    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task C" });

    try markDone(std.testing.allocator, tmp.dir, "work", "api", 2);

    const active = try list(std.testing.allocator, tmp.dir, "work", "api", .active);
    defer { for (active) |t| t.deinit(std.testing.allocator); std.testing.allocator.free(active); }
    try std.testing.expectEqual(@as(usize, 2), active.len);

    const all = try list(std.testing.allocator, tmp.dir, "work", "api", .all);
    defer { for (all) |t| t.deinit(std.testing.allocator); std.testing.allocator.free(all); }
    try std.testing.expectEqual(@as(usize, 3), all.len);
}

test "markDone updates status" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task" });
    try markDone(std.testing.allocator, tmp.dir, "work", "api", 1);

    const task = try get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expectEqual(model.Status.done, task.status);
}

test "update changes only specified fields" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Original title", .priority = .low });
    try update(std.testing.allocator, tmp.dir, "work", "api", 1, .{ .title = "Updated title" });

    const task = try get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Updated title", task.title);
    try std.testing.expectEqual(model.Priority.low, task.priority);
}

test "subtasks round-trip" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task with subs" });

    const subs = [_]model.SubTask{
        .{ .title = "Write tests", .done = false },
        .{ .title = "Deploy",      .done = true  },
    };
    try update(std.testing.allocator, tmp.dir, "work", "api", 1, .{ .subtasks = &subs });

    const task = try get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), task.subtasks.len);
    try std.testing.expectEqualStrings("Write tests", task.subtasks[0].title);
    try std.testing.expectEqual(false, task.subtasks[0].done);
    try std.testing.expectEqualStrings("Deploy", task.subtasks[1].title);
    try std.testing.expectEqual(true, task.subtasks[1].done);
}

test "projectProgress" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "A" }); // todo: 0
    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "B" }); // will be done: 100
    try markDone(std.testing.allocator, tmp.dir, "work", "api", 2);

    const pct = projectProgress(std.testing.allocator, tmp.dir, "work", "api");
    try std.testing.expectEqual(@as(u32, 50), pct); // (0 + 100) / 2 = 50
}

test "remove deletes task file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task" });
    try remove(tmp.dir, "work", "api", 1);
    try std.testing.expectError(error.TaskNotFound, get(std.testing.allocator, tmp.dir, "work", "api", 1));
}

test "remove nonexistent returns TaskNotFound" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");
    try std.testing.expectError(error.TaskNotFound, remove(tmp.dir, "work", "api", 99));
}

// ── extension link field tests ────────────────────────────────────────────────

test "task with empty external_id serializes without integration keys" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Plain task" });

    // Read raw TOML and check integration fields are absent
    const file = try tmp.dir.openFile("work/api/tasks/0001.toml", .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "external_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "integration_source") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "synced_at") == null);
}

test "task with external_id serializes with integration keys" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title       = "Linked task",
        .external_id = "ext-abc-123",
        .source      = "linear",
        .synced_at   = "2026-04-05",
    });

    const file = try tmp.dir.openFile("work/api/tasks/0001.toml", .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "ext-abc-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linear") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "2026-04-05") != null);
}

test "old task TOML without integration fields deserializes with defaults" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    // Write a task file without integration fields (simulates old format)
    const old_toml =
        \\title = "Legacy task"
        \\status = "todo"
        \\priority = "medium"
        \\description = ""
        \\created = "2025-01-01"
        \\due = ""
        \\subtask_count = "0"
        \\
    ;
    const tasks_dir_path = "work/api/tasks";
    try tmp.dir.makePath(tasks_dir_path);
    const f = try tmp.dir.createFile("work/api/tasks/0001.toml", .{});
    defer f.close();
    try f.writeAll(old_toml);

    const task = try get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("", task.external_id);
    try std.testing.expectEqualStrings("", task.source);
    try std.testing.expectEqualStrings("", task.synced_at);
}

test "extension link fields round-trip through add and get" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title       = "GitHub task",
        .external_id = "42",
        .source      = "github",
        .synced_at   = "2026-04-05",
    });

    const task = try get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("42", task.external_id);
    try std.testing.expectEqualStrings("github", task.source);
    try std.testing.expectEqualStrings("2026-04-05", task.synced_at);
}

test "update can set extension link fields" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Task" });

    try update(std.testing.allocator, tmp.dir, "work", "api", 1, .{
        .external_id = "card-xyz",
        .source      = "trello",
        .synced_at   = "2026-04-05",
    });

    const task = try get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("card-xyz", task.external_id);
    try std.testing.expectEqualStrings("trello", task.source);
    try std.testing.expectEqualStrings("2026-04-05", task.synced_at);
}

test "task source string survives arbitrary extension names" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title       = "Custom ext task",
        .external_id = "JIRA-77",
        .source      = "my-jira-ext",
    });

    const task = try get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("my-jira-ext", task.source);
}
