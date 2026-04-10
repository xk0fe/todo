/// Sync engine — merges remote tasks from integration adapters into local task storage.
const std = @import("std");
const model = @import("../model.zig");
const task_store = @import("../storage/task_store.zig");
const space_store = @import("../storage/space_store.zig");
const project_store = @import("../storage/project_store.zig");
const config_store = @import("../storage/config_store.zig");
const push_queue = @import("../storage/push_queue.zig");
const linear = @import("linear.zig");
const github = @import("github.zig");
const trello = @import("trello.zig");
const types = @import("types.zig");

pub const SyncResult = struct {
    created: u32,
    updated: u32,
    errors:  u32,
};

/// Merge remote tasks into local storage. Remote wins on title/status/priority.
/// Local description is kept when it is substantially longer than the remote's.
pub fn mergeTasks(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
    remote_tasks: []const types.RemoteTask,
    source: model.IntegrationSource,
) !SyncResult {
    var result = SyncResult{ .created = 0, .updated = 0, .errors = 0 };
    if (remote_tasks.len == 0) return result;

    const local_tasks = try task_store.list(allocator, root_dir, space, project, .all);
    defer {
        for (local_tasks) |t| t.deinit(allocator);
        allocator.free(local_tasks);
    }

    // Get today's date for synced_at
    var date_buf: [10]u8 = undefined;
    const today = currentDate(&date_buf);

    for (remote_tasks) |remote| {
        // Find local task with matching external_id AND same source
        var found_local: ?model.Task = null;
        for (local_tasks) |local| {
            if (local.integration_source == source and
                std.mem.eql(u8, local.external_id, remote.external_id))
            {
                found_local = local;
                break;
            }
        }

        if (found_local) |local| {
            // Check if anything changed
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
                })) {
                    result.updated += 1;
                } else |_| {
                    result.errors += 1;
                }
            }
        } else {
            // Create new local task; add() always sets status=.todo so we update after
            const add_result = task_store.add(allocator, root_dir, space, project, .{
                .title              = remote.title,
                .priority           = remote.priority,
                .description        = remote.description,
                .due                = remote.due,
                .external_id        = remote.external_id,
                .integration_source = source,
                .synced_at          = today,
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

pub fn syncLinear(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
    cfg: config_store.GlobalConfig,
    pi: config_store.ProjectIntegration,
) !SyncResult {
    const remote = try linear.fetchIssues(allocator, cfg.linear_api_key, pi.linear_team_id, pi.linear_project_id);
    defer {
        for (remote) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(remote);
    }
    return mergeTasks(allocator, root_dir, space, project, remote, .linear);
}

pub fn syncGitHub(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
    cfg: config_store.GlobalConfig,
    pi: config_store.ProjectIntegration,
) !SyncResult {
    const remote = try github.fetchIssues(allocator, cfg.github_token, pi.github_owner, pi.github_repo);
    defer {
        for (remote) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(remote);
    }
    return mergeTasks(allocator, root_dir, space, project, remote, .github);
}

pub fn syncTrello(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
    cfg: config_store.GlobalConfig,
    pi: config_store.ProjectIntegration,
) !SyncResult {
    const list_map = trello.TrelloListMap{
        .todo        = pi.trello_list_id_todo,
        .in_progress = pi.trello_list_id_in_progress,
        .in_review   = pi.trello_list_id_in_review,
        .done        = pi.trello_list_id_done,
    };
    const remote = try trello.fetchCards(allocator, cfg.trello_api_key, cfg.trello_token, pi.trello_board_id, list_map);
    defer {
        for (remote) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(remote);
    }
    return mergeTasks(allocator, root_dir, space, project, remote, .trello);
}

// ── Auto-sync helpers (create spaces/projects from remote, then merge) ────────

/// Ensure a space exists (ignores AlreadyExists).
fn ensureSpace(root_dir: std.fs.Dir, name: []const u8) !void {
    space_store.add(root_dir, name) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
}

/// Ensure a project exists (ignores AlreadyExists / SpaceNotFound treated as error).
fn ensureProject(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8) !void {
    project_store.add(allocator, root_dir, space, project) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
}

/// Sync all GitHub issues assigned to the authenticated user.
/// Groups by repo → creates "GitHub" space and "{owner} - {repo}" projects automatically.
pub fn autoSyncGitHub(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    cfg: config_store.GlobalConfig,
) !SyncResult {
    const all = try github.fetchAllAssigned(allocator, cfg.github_token);
    defer {
        for (all) |iwr| iwr.deinit(allocator);
        allocator.free(all);
    }

    try ensureSpace(root_dir, "GitHub");

    // Group by owner+repo using a map: project_name → []RemoteTask
    var groups = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(types.RemoteTask)){};
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        groups.deinit(allocator);
    }

    // Also store owner/repo for each project name so we can save .integration.toml
    var meta = std.StringHashMapUnmanaged([2][]const u8){};
    defer {
        var it = meta.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr[0]);
            allocator.free(entry.value_ptr[1]);
        }
        meta.deinit(allocator);
    }

    for (all) |iwr| {
        var proj_buf: [256]u8 = undefined;
        const proj = std.fmt.bufPrint(&proj_buf, "{s} - {s}", .{ iwr.owner, iwr.repo }) catch continue;

        const res = try groups.getOrPut(allocator, proj);
        if (!res.found_existing) {
            res.key_ptr.* = try allocator.dupe(u8, proj);
            res.value_ptr.* = .{};
            try meta.put(allocator, res.key_ptr.*, .{
                try allocator.dupe(u8, iwr.owner),
                try allocator.dupe(u8, iwr.repo),
            });
        }
        // Append a copy of the task (ownership: the IssueWithRepo still owns the original)
        const task_copy = types.RemoteTask{
            .external_id = try allocator.dupe(u8, iwr.task.external_id),
            .title       = try allocator.dupe(u8, iwr.task.title),
            .description = try allocator.dupe(u8, iwr.task.description),
            .status      = iwr.task.status,
            .priority    = iwr.task.priority,
            .due         = try allocator.dupe(u8, iwr.task.due),
            .url         = try allocator.dupe(u8, iwr.task.url),
        };
        try res.value_ptr.append(allocator, task_copy);
    }

    var total = SyncResult{ .created = 0, .updated = 0, .errors = 0 };

    var it = groups.iterator();
    while (it.next()) |entry| {
        const proj = entry.key_ptr.*;
        const tasks = entry.value_ptr.items;

        ensureProject(allocator, root_dir, "GitHub", proj) catch { total.errors += 1; continue; };

        // Save .integration.toml so the CLI sync commands work too
        if (meta.get(proj)) |m| {
            var pi = config_store.loadProjectIntegration(allocator, root_dir, "GitHub", proj) catch continue;
            defer pi.deinit(allocator);
            allocator.free(pi.github_owner);
            allocator.free(pi.github_repo);
            pi.github_owner = try allocator.dupe(u8, m[0]);
            pi.github_repo  = try allocator.dupe(u8, m[1]);
            config_store.saveProjectIntegration(allocator, root_dir, "GitHub", proj, pi) catch {};
        }

        const r = mergeTasks(allocator, root_dir, "GitHub", proj, tasks, .github) catch {
            total.errors += 1; continue;
        };
        total.created += r.created;
        total.updated += r.updated;
        total.errors  += r.errors;

        // Free the task copies
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        entry.value_ptr.clearRetainingCapacity();
    }

    return total;
}

/// Sync all Linear issues assigned to the authenticated user.
/// Groups by team → creates "Linear" space and "{team_name}" projects automatically.
pub fn autoSyncLinear(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    cfg: config_store.GlobalConfig,
) !SyncResult {
    const all = try linear.fetchAllAssigned(allocator, cfg.linear_api_key);
    defer {
        for (all) |iwt| iwt.deinit(allocator);
        allocator.free(all);
    }

    try ensureSpace(root_dir, "Linear");

    var groups = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(types.RemoteTask)){};
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        groups.deinit(allocator);
    }

    var team_ids = std.StringHashMapUnmanaged([]const u8){};
    defer {
        var it = team_ids.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        team_ids.deinit(allocator);
    }

    for (all) |iwt| {
        const res = try groups.getOrPut(allocator, iwt.team_name);
        if (!res.found_existing) {
            res.key_ptr.* = try allocator.dupe(u8, iwt.team_name);
            res.value_ptr.* = .{};
            try team_ids.put(allocator, res.key_ptr.*, try allocator.dupe(u8, iwt.team_id));
        }
        const task_copy = types.RemoteTask{
            .external_id = try allocator.dupe(u8, iwt.task.external_id),
            .title       = try allocator.dupe(u8, iwt.task.title),
            .description = try allocator.dupe(u8, iwt.task.description),
            .status      = iwt.task.status,
            .priority    = iwt.task.priority,
            .due         = try allocator.dupe(u8, iwt.task.due),
            .url         = try allocator.dupe(u8, iwt.task.url),
        };
        try res.value_ptr.append(allocator, task_copy);
    }

    var total = SyncResult{ .created = 0, .updated = 0, .errors = 0 };

    var it = groups.iterator();
    while (it.next()) |entry| {
        const team_name = entry.key_ptr.*;
        const tasks = entry.value_ptr.items;

        ensureProject(allocator, root_dir, "Linear", team_name) catch { total.errors += 1; continue; };

        // Save .integration.toml
        if (team_ids.get(team_name)) |tid| {
            var pi = config_store.loadProjectIntegration(allocator, root_dir, "Linear", team_name) catch continue;
            defer pi.deinit(allocator);
            allocator.free(pi.linear_team_id);
            pi.linear_team_id = try allocator.dupe(u8, tid);
            config_store.saveProjectIntegration(allocator, root_dir, "Linear", team_name, pi) catch {};
        }

        const r = mergeTasks(allocator, root_dir, "Linear", team_name, tasks, .linear) catch {
            total.errors += 1; continue;
        };
        total.created += r.created;
        total.updated += r.updated;
        total.errors  += r.errors;

        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        entry.value_ptr.clearRetainingCapacity();
    }

    return total;
}

/// Send all queued local changes to their respective remote services.
/// Clears the queue on completion (even partial — best-effort).
pub fn flushPushQueue(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    cfg: config_store.GlobalConfig,
) void {
    const entries = push_queue.loadAll(allocator, root_dir) catch return;
    defer {
        for (entries) |e| e.deinit(allocator);
        allocator.free(entries);
    }

    if (entries.len == 0) return;

    for (entries) |e| {
        if (std.mem.eql(u8, e.source, "github")) {
            // Map our status string to GitHub state
            const gh_state: []const u8 = blk: {
                if (std.mem.eql(u8, e.new_status, "done")) break :blk "closed";
                if (e.new_status.len > 0) break :blk "open";
                break :blk "";
            };
            github.pushUpdate(
                allocator, cfg.github_token,
                e.owner, e.repo, e.external_id,
                gh_state, e.new_title,
            ) catch {};
        } else if (std.mem.eql(u8, e.source, "linear")) {
            linear.pushUpdate(
                allocator, cfg.linear_api_key,
                e.external_id, e.new_title,
            ) catch {};
        }
    }

    push_queue.clear(root_dir);
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

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, .linear);
    try std.testing.expectEqual(@as(u32, 1), result.created);
    try std.testing.expectEqual(@as(u32, 0), result.updated);

    const tasks = try task_store.list(std.testing.allocator, tmp.dir, "work", "api", .all);
    defer {
        for (tasks) |t| t.deinit(std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expectEqualStrings("ext1", tasks[0].external_id);
    try std.testing.expectEqual(model.IntegrationSource.linear, tasks[0].integration_source);
}

test "mergeTasks: updates existing task when fields differ" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    // Create a local task linked to ext1
    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title              = "Old title",
        .external_id        = "ext1",
        .integration_source = .linear,
        .synced_at          = "2026-01-01",
    });

    const remote = [_]types.RemoteTask{
        try makeRemoteTask(std.testing.allocator, "ext1", "New title", .in_progress, .high),
    };
    defer for (remote) |t| types.deinitRemoteTask(t, std.testing.allocator);

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, .linear);
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
        .title              = "Same title",
        .external_id        = "ext1",
        .integration_source = .github,
        .synced_at          = "2026-04-01",
    });

    const remote = [_]types.RemoteTask{
        try makeRemoteTask(std.testing.allocator, "ext1", "Same title", .todo, .medium),
    };
    defer for (remote) |t| types.deinitRemoteTask(t, std.testing.allocator);

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, .github);
    try std.testing.expectEqual(@as(u32, 0), result.created);
    try std.testing.expectEqual(@as(u32, 0), result.updated);
}

test "mergeTasks: local description preserved when substantially longer" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title              = "Task",
        .description        = "This is my detailed local notes that are much longer than the remote description.",
        .external_id        = "ext1",
        .integration_source = .linear,
    });

    var remote_task = try makeRemoteTask(std.testing.allocator, "ext1", "Task", .todo, .medium);
    remote_task.description = try std.testing.allocator.dupe(u8, "Short remote desc.");
    defer types.deinitRemoteTask(remote_task, std.testing.allocator);

    _ = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &.{remote_task}, .linear);

    const task = try task_store.get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, task.description, "This is my detailed"));
}

test "mergeTasks: remote description wins when local is shorter" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title              = "Task",
        .description        = "Short.",
        .external_id        = "ext1",
        .integration_source = .linear,
    });

    var remote_task = try makeRemoteTask(std.testing.allocator, "ext1", "Task", .todo, .medium);
    remote_task.description = try std.testing.allocator.dupe(u8, "This is the full remote description with more content.");
    defer types.deinitRemoteTask(remote_task, std.testing.allocator);

    _ = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &.{remote_task}, .linear);

    const task = try task_store.get(std.testing.allocator, tmp.dir, "work", "api", 1);
    defer task.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, task.description, "This is the full"));
}

test "mergeTasks: handles mix of new and existing tasks" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    // Create one existing linked task
    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title              = "Existing",
        .external_id        = "ext1",
        .integration_source = .github,
    });

    const remote = [_]types.RemoteTask{
        try makeRemoteTask(std.testing.allocator, "ext1", "Updated existing", .in_progress, .medium),
        try makeRemoteTask(std.testing.allocator, "ext2", "Brand new",        .todo,        .low),
        try makeRemoteTask(std.testing.allocator, "ext3", "Also new",         .done,        .high),
    };
    defer for (remote) |t| types.deinitRemoteTask(t, std.testing.allocator);

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, .github);
    try std.testing.expectEqual(@as(u32, 2), result.created);
    try std.testing.expectEqual(@as(u32, 1), result.updated);
}

test "mergeTasks: empty remote produces no changes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{ .title = "Local only" });

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &.{}, .linear);
    try std.testing.expectEqual(@as(u32, 0), result.created);
    try std.testing.expectEqual(@as(u32, 0), result.updated);

    const tasks = try task_store.list(std.testing.allocator, tmp.dir, "work", "api", .all);
    defer {
        for (tasks) |t| t.deinit(std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
}

test "mergeTasks: does not match tasks from different integration source" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeProject(tmp.dir, "work", "api");

    // Task linked to github ext1
    _ = try task_store.add(std.testing.allocator, tmp.dir, "work", "api", .{
        .title              = "GitHub task",
        .external_id        = "ext1",
        .integration_source = .github,
    });

    // Sync linear with same external_id "ext1" — should NOT match the github task
    const remote = [_]types.RemoteTask{
        try makeRemoteTask(std.testing.allocator, "ext1", "Linear task", .todo, .medium),
    };
    defer for (remote) |t| types.deinitRemoteTask(t, std.testing.allocator);

    const result = try mergeTasks(std.testing.allocator, tmp.dir, "work", "api", &remote, .linear);
    // Should create a new task, not update the github one
    try std.testing.expectEqual(@as(u32, 1), result.created);
    try std.testing.expectEqual(@as(u32, 0), result.updated);
}
