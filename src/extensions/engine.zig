/// Extension engine — runs extension executables for import/export and
/// merges imported tasks into local storage.
const std = @import("std");
const model = @import("../model.zig");
const task_store = @import("../storage/task_store.zig");
const ext_config = @import("../storage/ext_config.zig");
const toml = @import("../storage/toml.zig");
const registry = @import("registry.zig");
const runner = @import("runner.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

pub const ImportResult = struct {
    created: u32,
    updated: u32,
    errors:  u32,
};

pub const ImportOutcome = union(enum) {
    ok:   ImportResult,
    fail: []u8, // owned message; caller frees

    pub fn deinit(self: ImportOutcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .fail => |m| allocator.free(m),
            .ok => {},
        }
    }
};

pub const ExportResult = struct {
    exported: u32,
    skipped:  u32,
};

pub const ExportOutcome = union(enum) {
    ok:   ExportResult,
    fail: []u8,

    pub fn deinit(self: ExportOutcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .fail => |m| allocator.free(m),
            .ok => {},
        }
    }
};

/// Merge imported tasks into local storage. Remote wins on title/status/
/// priority; the local description is kept when substantially longer.
/// Tasks are matched by (source, external_id).
pub fn mergeTasks(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
    remote_tasks: []const types.RemoteTask,
    source: []const u8,
) !ImportResult {
    var result = ImportResult{ .created = 0, .updated = 0, .errors = 0 };
    if (remote_tasks.len == 0) return result;

    const local_tasks = try task_store.list(allocator, root_dir, space, project, .all);
    defer {
        for (local_tasks) |t| t.deinit(allocator);
        allocator.free(local_tasks);
    }

    var date_buf: [10]u8 = undefined;
    const today = currentDate(&date_buf);

    for (remote_tasks) |remote| {
        var found_local: ?model.Task = null;
        for (local_tasks) |local| {
            if (std.mem.eql(u8, local.source, source) and
                std.mem.eql(u8, local.external_id, remote.external_id))
            {
                found_local = local;
                break;
            }
        }

        if (found_local) |local| {
            const desc = mergeDescription(local.description, remote.description);
            const changed = !std.mem.eql(u8, local.title, remote.title) or
                local.status != remote.status or
                local.priority != remote.priority or
                !std.mem.eql(u8, local.description, desc) or
                !std.mem.eql(u8, local.due, remote.due);

            if (changed) {
                if (task_store.update(allocator, root_dir, space, project, local.id, .{
                    .title       = remote.title,
                    .status      = remote.status,
                    .priority    = remote.priority,
                    .description = desc,
                    .due         = if (remote.due.len > 0) remote.due else null,
                    .synced_at   = today,
                    .url         = if (remote.url.len > 0) remote.url else null,
                })) {
                    result.updated += 1;
                } else |_| {
                    result.errors += 1;
                }
            }
        } else {
            // Create new local task; add() always sets status=.todo so we update after
            const add_result = task_store.add(allocator, root_dir, space, project, .{
                .title       = remote.title,
                .priority    = remote.priority,
                .description = remote.description,
                .due         = remote.due,
                .external_id = remote.external_id,
                .source      = source,
                .synced_at   = today,
                .url         = remote.url,
            });
            if (add_result) |new_id| {
                if (remote.status != .todo) {
                    task_store.update(allocator, root_dir, space, project, new_id, .{
                        .status = remote.status,
                    }) catch {};
                }
                result.created += 1;
            } else |_| {
                result.errors += 1;
            }
        }
    }

    return result;
}

fn mergeDescription(local: []const u8, remote: []const u8) []const u8 {
    if (local.len > remote.len + 20) return local;
    return remote;
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

fn failMsg(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

/// Trim an extension's stderr down to a single displayable line.
fn firstLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    return std.mem.trimRight(u8, trimmed[0..nl], "\r");
}

const ResolvedExt = struct {
    ref:    registry.ExtRef,
    config: ext_config.MergedConfig,
    kvs:    []protocol.KV,

    fn deinit(self: ResolvedExt, allocator: std.mem.Allocator) void {
        allocator.free(self.kvs);
        self.config.deinit(allocator);
        self.ref.deinit(allocator);
    }
};

/// Resolve the extension linked to a project, plus its merged config.
/// Returns null and sets `fail_out` when the project is unlinked or the
/// extension executable is missing.
fn resolveLinked(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
    fail_out: *?[]u8,
) !?ResolvedExt {
    var link = try ext_config.loadProjectLink(allocator, root_dir, space, project) orelse {
        fail_out.* = try failMsg(allocator, "project not linked — run: todo ext link {s} {s} <extension>", .{ space, project });
        return null;
    };
    defer link.deinit(allocator);

    const ref = try registry.find(allocator, root_dir, link.extension) orelse {
        fail_out.* = try failMsg(allocator, "extension '{s}' not found in ~/.todo/extensions", .{link.extension});
        return null;
    };
    errdefer ref.deinit(allocator);

    const config = try ext_config.mergedConfig(allocator, root_dir, link.extension, space, project);
    errdefer config.deinit(allocator);

    const kvs = try allocator.alloc(protocol.KV, config.pairs.len);
    for (config.pairs, 0..) |kv, i| kvs[i] = .{ .key = kv.key, .value = kv.value };

    return ResolvedExt{ .ref = ref, .config = config, .kvs = kvs };
}

/// Import: run the linked extension and merge its tasks into the project.
pub fn importProject(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
) !ImportOutcome {
    var fail: ?[]u8 = null;
    const resolved = try resolveLinked(allocator, root_dir, space, project, &fail) orelse
        return ImportOutcome{ .fail = fail.? };
    defer resolved.deinit(allocator);

    const request = try protocol.buildRequest(allocator, resolved.kvs, space, project, null);
    defer allocator.free(request);

    const out = runner.run(allocator, resolved.ref.path, "import", request) catch |err| {
        return ImportOutcome{ .fail = try failMsg(allocator, "could not run extension '{s}': {s}", .{ resolved.ref.name, @errorName(err) }) };
    };
    defer out.deinit(allocator);

    // Prefer the extension's structured {"error":...} over raw stderr.
    const payload = protocol.parseImportResponse(allocator, out.stdout) catch {
        if (!out.ok()) {
            return ImportOutcome{ .fail = try failMsg(allocator, "{s} import failed: {s}", .{ resolved.ref.name, firstLine(out.stderr) }) };
        }
        return ImportOutcome{ .fail = try failMsg(allocator, "{s} returned invalid JSON", .{resolved.ref.name}) };
    };
    defer payload.deinit(allocator);

    if (payload.err_msg) |msg| {
        return ImportOutcome{ .fail = try allocator.dupe(u8, msg) };
    }
    if (!out.ok()) {
        return ImportOutcome{ .fail = try failMsg(allocator, "{s} import failed: {s}", .{ resolved.ref.name, firstLine(out.stderr) }) };
    }

    const result = try mergeTasks(allocator, root_dir, space, project, payload.tasks, resolved.ref.name);
    return ImportOutcome{ .ok = result };
}

/// Export: send the project's current tasks to the linked extension.
/// Extensions update remote items linked via external_id and report counts.
pub fn exportProject(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
) !ExportOutcome {
    var fail: ?[]u8 = null;
    const resolved = try resolveLinked(allocator, root_dir, space, project, &fail) orelse
        return ExportOutcome{ .fail = fail.? };
    defer resolved.deinit(allocator);

    const tasks = try task_store.list(allocator, root_dir, space, project, .all);
    defer {
        for (tasks) |t| t.deinit(allocator);
        allocator.free(tasks);
    }

    const request = try protocol.buildRequest(allocator, resolved.kvs, space, project, tasks);
    defer allocator.free(request);

    const out = runner.run(allocator, resolved.ref.path, "export", request) catch |err| {
        return ExportOutcome{ .fail = try failMsg(allocator, "could not run extension '{s}': {s}", .{ resolved.ref.name, @errorName(err) }) };
    };
    defer out.deinit(allocator);

    // Prefer the extension's structured {"error":...} over raw stderr.
    const payload = protocol.parseExportResponse(allocator, out.stdout) catch {
        if (!out.ok()) {
            return ExportOutcome{ .fail = try failMsg(allocator, "{s} export failed: {s}", .{ resolved.ref.name, firstLine(out.stderr) }) };
        }
        return ExportOutcome{ .fail = try failMsg(allocator, "{s} returned invalid JSON", .{resolved.ref.name}) };
    };
    defer payload.deinit(allocator);

    if (payload.err_msg) |msg| {
        return ExportOutcome{ .fail = try allocator.dupe(u8, msg) };
    }
    if (!out.ok()) {
        return ExportOutcome{ .fail = try failMsg(allocator, "{s} export failed: {s}", .{ resolved.ref.name, firstLine(out.stderr) }) };
    }

    return ExportOutcome{ .ok = .{ .exported = payload.exported, .skipped = payload.skipped } };
}

// ── test helpers ──────────────────────────────────────────────────────────────

fn makeProject(root_dir: std.fs.Dir, space: []const u8, project: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ space, project });
    try root_dir.makePath(path);
}

fn makeRemoteTask(
    allocator: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    status: model.Status,
    priority: model.Priority,
) !types.RemoteTask {
    return types.RemoteTask{
        .external_id = try allocator.dupe(u8, id),
        .title       = try allocator.dupe(u8, title),
        .description = try allocator.dupe(u8, ""),
        .status      = status,
        .priority    = priority,
        .due         = try allocator.dupe(u8, ""),
        .url         = try allocator.dupe(u8, ""),
    };
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "mergeTasks: creates new task when not present locally" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    const remote = [_]types.RemoteTask{
        try makeRemoteTask(std.testing.allocator, "ext1", "Remote task", .todo, .medium),
    };
    defer for (remote) |t| types.deinitRemoteTask(t, std.testing.allocator);

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, "linear");
    try std.testing.expectEqual(@as(u32, 1), result.created);
    try std.testing.expectEqual(@as(u32, 0), result.updated);

    const tasks = try task_store.list(std.testing.allocator, tmp.dir, "work", "api", .all);
    defer {
        for (tasks) |t| t.deinit(std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expectEqualStrings("ext1", tasks[0].external_id);
    try std.testing.expectEqualStrings("linear", tasks[0].source);
}

test "mergeTasks: updates existing task when fields differ" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title       = "Old title",
        .external_id = "ext1",
        .source      = "linear",
        .synced_at   = "2026-01-01",
    });

    const remote = [_]types.RemoteTask{
        try makeRemoteTask(std.testing.allocator, "ext1", "New title", .in_progress, .high),
    };
    defer for (remote) |t| types.deinitRemoteTask(t, std.testing.allocator);

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, "linear");
    try std.testing.expectEqual(@as(u32, 0), result.created);
    try std.testing.expectEqual(@as(u32, 1), result.updated);

    const task = try task_store.get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("New title", task.title);
    try std.testing.expectEqual(model.Status.in_progress, task.status);
    try std.testing.expectEqual(model.Priority.high, task.priority);
}

test "mergeTasks: no change when remote matches local" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title       = "Same title",
        .external_id = "ext1",
        .source      = "github",
        .synced_at   = "2026-04-01",
    });

    const remote = [_]types.RemoteTask{
        try makeRemoteTask(std.testing.allocator, "ext1", "Same title", .todo, .medium),
    };
    defer for (remote) |t| types.deinitRemoteTask(t, std.testing.allocator);

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, "github");
    try std.testing.expectEqual(@as(u32, 0), result.created);
    try std.testing.expectEqual(@as(u32, 0), result.updated);
}

test "mergeTasks: local description preserved when substantially longer" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title       = "Task",
        .description = "This is my detailed local notes that are much longer than the remote description.",
        .external_id = "ext1",
        .source      = "linear",
    });

    var remote_task = try makeRemoteTask(std.testing.allocator, "ext1", "Task", .todo, .medium);
    remote_task.description = try std.testing.allocator.dupe(u8, "Short remote desc.");
    defer types.deinitRemoteTask(remote_task, std.testing.allocator);

    _ = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &.{remote_task}, "linear");

    const task = try task_store.get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, task.description, "This is my detailed"));
}

test "mergeTasks: remote description wins when local is shorter" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title       = "Task",
        .description = "Short.",
        .external_id = "ext1",
        .source      = "linear",
    });

    var remote_task = try makeRemoteTask(std.testing.allocator, "ext1", "Task", .todo, .medium);
    remote_task.description = try std.testing.allocator.dupe(u8, "This is the full remote description with more content.");
    defer types.deinitRemoteTask(remote_task, std.testing.allocator);

    _ = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &.{remote_task}, "linear");

    const task = try task_store.get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, task.description, "This is the full"));
}

test "mergeTasks: handles mix of new and existing tasks" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title       = "Existing",
        .external_id = "ext1",
        .source      = "github",
    });

    const remote = [_]types.RemoteTask{
        try makeRemoteTask(std.testing.allocator, "ext1", "Updated existing", .in_progress, .medium),
        try makeRemoteTask(std.testing.allocator, "ext2", "Brand new",        .todo,        .low),
        try makeRemoteTask(std.testing.allocator, "ext3", "Also new",         .done,        .high),
    };
    defer for (remote) |t| types.deinitRemoteTask(t, std.testing.allocator);

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, "github");
    try std.testing.expectEqual(@as(u32, 2), result.created);
    try std.testing.expectEqual(@as(u32, 1), result.updated);
}

test "mergeTasks: empty remote produces no changes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Local only" });

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &.{}, "linear");
    try std.testing.expectEqual(@as(u32, 0), result.created);
    try std.testing.expectEqual(@as(u32, 0), result.updated);
}

test "mergeTasks: does not match tasks from a different extension" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title       = "GitHub task",
        .external_id = "ext1",
        .source      = "github",
    });

    const remote = [_]types.RemoteTask{
        try makeRemoteTask(std.testing.allocator, "ext1", "Linear task", .todo, .medium),
    };
    defer for (remote) |t| types.deinitRemoteTask(t, std.testing.allocator);

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, "linear");
    try std.testing.expectEqual(@as(u32, 1), result.created);
    try std.testing.expectEqual(@as(u32, 0), result.updated);
}

test "importProject: unlinked project fails with guidance" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    const outcome = try importProject(std.testing.allocator, tmp.dir, "work", "api");
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .fail);
    try std.testing.expect(std.mem.indexOf(u8, outcome.fail, "not linked") != null);
}

test "importProject: missing extension executable fails" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");
    try ext_config.saveProjectLink(std.testing.allocator, tmp.dir, "work", "api", "ghost", &.{});

    const outcome = try importProject(std.testing.allocator, tmp.dir, "work", "api");
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .fail);
    try std.testing.expect(std.mem.indexOf(u8, outcome.fail, "ghost") != null);
}

test "importProject: end-to-end with a script extension" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");
    try tmp.dir.makePath(registry.EXT_DIR);

    // A fake extension that returns one task regardless of input
    const script =
        \\#!/bin/sh
        \\case "$1" in
        \\  import) cat > /dev/null; echo '{"tasks":[{"external_id":"X1","title":"From ext","status":"in-progress","priority":"high","due":"","url":"http://x"}]}' ;;
        \\  *) echo '{"error":"unsupported"}'; exit 1 ;;
        \\esac
        \\
    ;
    {
        const f = try tmp.dir.createFile(registry.EXT_DIR ++ "/fake", .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll(script);
    }
    try ext_config.saveProjectLink(std.testing.allocator, tmp.dir, "work", "api", "fake", &.{});

    const outcome = try importProject(std.testing.allocator, tmp.dir, "work", "api");
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .ok);
    try std.testing.expectEqual(@as(u32, 1), outcome.ok.created);

    const task = try task_store.get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("From ext", task.title);
    try std.testing.expectEqualStrings("fake", task.source);
    try std.testing.expectEqual(model.Status.in_progress, task.status);
}

test "exportProject: end-to-end with a script extension" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");
    try tmp.dir.makePath(registry.EXT_DIR);

    const script =
        \\#!/bin/sh
        \\case "$1" in
        \\  export) cat > /dev/null; echo '{"exported":2,"skipped":1}' ;;
        \\  *) exit 1 ;;
        \\esac
        \\
    ;
    {
        const f = try tmp.dir.createFile(registry.EXT_DIR ++ "/fake", .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll(script);
    }
    try ext_config.saveProjectLink(std.testing.allocator, tmp.dir, "work", "api", "fake", &.{});
    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "T" });

    const outcome = try exportProject(std.testing.allocator, tmp.dir, "work", "api");
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .ok);
    try std.testing.expectEqual(@as(u32, 2), outcome.ok.exported);
    try std.testing.expectEqual(@as(u32, 1), outcome.ok.skipped);
}
