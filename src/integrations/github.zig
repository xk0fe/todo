/// GitHub Issues REST API integration adapter.
const std = @import("std");
const model = @import("../model.zig");
const http = @import("http.zig");
const json_util = @import("json_util.zig");
const types = @import("types.zig");

pub const RemoteTask = types.RemoteTask;

fn labelNames(labels: std.json.Value) []const std.json.Value {
    return switch (labels) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn hasLabel(labels: std.json.Value, needle: []const u8) bool {
    for (labelNames(labels)) |label| {
        const name = json_util.getString(label, "name");
        var lower_buf: [64]u8 = undefined;
        const lower = std.ascii.lowerString(lower_buf[0..@min(name.len, 63)], name[0..@min(name.len, 63)]);
        if (std.mem.eql(u8, lower, needle)) return true;
    }
    return false;
}

fn mapGithubStatus(state: []const u8, labels: std.json.Value) model.Status {
    if (std.mem.eql(u8, state, "closed")) return .done;
    if (hasLabel(labels, "in review")) return .in_review;
    if (hasLabel(labels, "in-progress")) return .in_progress;
    return .todo;
}

fn mapGithubPriority(labels: std.json.Value) model.Priority {
    for (labelNames(labels)) |label| {
        const name = json_util.getString(label, "name");
        var lower_buf: [64]u8 = undefined;
        const lower = std.ascii.lowerString(lower_buf[0..@min(name.len, 63)], name[0..@min(name.len, 63)]);
        if (std.mem.eql(u8, lower, "priority: urgent") or std.mem.eql(u8, lower, "p0")) return .urgent;
        if (std.mem.eql(u8, lower, "priority: high")   or std.mem.eql(u8, lower, "p1")) return .high;
        if (std.mem.eql(u8, lower, "priority: medium") or std.mem.eql(u8, lower, "p2")) return .medium;
        if (std.mem.eql(u8, lower, "priority: low")    or std.mem.eql(u8, lower, "p3")) return .low;
    }
    return .medium; // default
}

/// Parse GitHub REST API issues response into a slice of RemoteTask.
/// Caller owns the returned slice and must call types.deinitRemoteTask on each element.
pub fn parseIssues(allocator: std.mem.Allocator, body: []const u8) ![]RemoteTask {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return &.{},
    };

    var result = std.ArrayListUnmanaged(RemoteTask){};
    errdefer {
        for (result.items) |t| types.deinitRemoteTask(t, allocator);
        result.deinit(allocator);
    }

    for (items) |item| {
        const number = json_util.getInt(item, "number");
        const title  = json_util.getString(item, "title");
        const body_text = json_util.getString(item, "body");
        const state  = json_util.getString(item, "state");
        const url    = json_util.getString(item, "html_url");

        // labels array
        const labels = switch (item) {
            .object => |m| m.get("labels") orelse std.json.Value{ .array = std.json.Array.init(allocator) },
            else => std.json.Value{ .array = std.json.Array.init(allocator) },
        };

        // due from milestone.due_on (first 10 chars = YYYY-MM-DD)
        const milestone = switch (item) {
            .object => |m| m.get("milestone") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        };
        const due_raw = json_util.getString(milestone, "due_on");
        const due = if (due_raw.len >= 10) due_raw[0..10] else due_raw;

        var id_buf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{number}) catch "0";

        const task = RemoteTask{
            .external_id = try allocator.dupe(u8, id_str),
            .title       = try allocator.dupe(u8, title),
            .description = try allocator.dupe(u8, body_text),
            .status      = mapGithubStatus(state, labels),
            .priority    = mapGithubPriority(labels),
            .due         = try allocator.dupe(u8, due),
            .url         = try allocator.dupe(u8, url),
        };
        try result.append(allocator, task);
    }

    return result.toOwnedSlice(allocator);
}

/// Fetch open issues from GitHub. Delegates to parseIssues.
pub fn fetchIssues(
    allocator: std.mem.Allocator,
    token: []const u8,
    owner: []const u8,
    repo: []const u8,
) ![]RemoteTask {
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf,
        "https://api.github.com/repos/{s}/{s}/issues?assignee=@me&state=open&per_page=100",
        .{ owner, repo }) catch return error.PathTooLong;

    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.PathTooLong;

    const headers = [_]http.Header{
        .{ .name = "Authorization",        .value = auth },
        .{ .name = "Accept",               .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    };
    const resp = try http.request(allocator, .GET, url, &headers, null);
    defer resp.deinit(allocator);
    return parseIssues(allocator, resp.body);
}

/// Issue bundled with its source repository (owner + repo).
pub const IssueWithRepo = struct {
    owner: []const u8,
    repo:  []const u8,
    task:  RemoteTask,

    pub fn deinit(self: IssueWithRepo, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.repo);
        types.deinitRemoteTask(self.task, allocator);
    }
};

/// Fetch all issues assigned to the authenticated user across every accessible repo.
/// Uses GET /issues?filter=assigned (GitHub cross-repo endpoint).
/// Each returned item carries the owning repo's owner+name.
pub fn fetchAllAssigned(allocator: std.mem.Allocator, token: []const u8) ![]IssueWithRepo {
    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.PathTooLong;

    const headers = [_]http.Header{
        .{ .name = "Authorization",        .value = auth },
        .{ .name = "Accept",               .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    };
    const resp = try http.request(allocator, .GET,
        "https://api.github.com/issues?filter=assigned&state=open&per_page=100",
        &headers, null);
    defer resp.deinit(allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{
        .allocate = .alloc_always, .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return &.{},
    };

    var result = std.ArrayListUnmanaged(IssueWithRepo){};
    errdefer {
        for (result.items) |iwr| iwr.deinit(allocator);
        result.deinit(allocator);
    }

    for (items) |item| {
        // Extract repository info
        const repo_obj = switch (item) {
            .object => |m| m.get("repository") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        };
        const owner_obj = switch (repo_obj) {
            .object => |m| m.get("owner") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        };
        const owner_login = json_util.getString(owner_obj, "login");
        const repo_name   = json_util.getString(repo_obj, "name");

        if (owner_login.len == 0 or repo_name.len == 0) continue;

        // Re-use existing per-item parsing
        const number = json_util.getInt(item, "number");
        const title  = json_util.getString(item, "title");
        const body_text = json_util.getString(item, "body");
        const state  = json_util.getString(item, "state");
        const url    = json_util.getString(item, "html_url");

        const labels = switch (item) {
            .object => |m| m.get("labels") orelse std.json.Value{ .array = std.json.Array.init(allocator) },
            else => std.json.Value{ .array = std.json.Array.init(allocator) },
        };
        const milestone = switch (item) {
            .object => |m| m.get("milestone") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        };
        const due_raw = json_util.getString(milestone, "due_on");
        const due = if (due_raw.len >= 10) due_raw[0..10] else due_raw;

        var id_buf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{number}) catch "0";

        const task = RemoteTask{
            .external_id = try allocator.dupe(u8, id_str),
            .title       = try allocator.dupe(u8, title),
            .description = try allocator.dupe(u8, body_text),
            .status      = mapGithubStatus(state, labels),
            .priority    = mapGithubPriority(labels),
            .due         = try allocator.dupe(u8, due),
            .url         = try allocator.dupe(u8, url),
        };
        try result.append(allocator, IssueWithRepo{
            .owner = try allocator.dupe(u8, owner_login),
            .repo  = try allocator.dupe(u8, repo_name),
            .task  = task,
        });
    }

    return result.toOwnedSlice(allocator);
}

/// Push a status/title change back to GitHub.
/// Pass new_state = "open" or "closed".  Pass new_title = "" to skip title update.
pub fn pushUpdate(
    allocator: std.mem.Allocator,
    token: []const u8,
    owner: []const u8,
    repo: []const u8,
    issue_number: []const u8, // decimal string
    new_state: []const u8,   // "open" | "closed" | ""
    new_title: []const u8,   // "" = skip
) !void {
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf,
        "https://api.github.com/repos/{s}/{s}/issues/{s}",
        .{ owner, repo, issue_number }) catch return error.PathTooLong;

    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.PathTooLong;

    // Build JSON body
    var body_buf: [512]u8 = undefined;
    var body_fbs = std.io.fixedBufferStream(&body_buf);
    const bw = body_fbs.writer();
    try bw.writeByte('{');
    var first = true;
    if (new_state.len > 0) {
        try bw.print("\"state\":\"{s}\"", .{new_state});
        first = false;
    }
    if (new_title.len > 0) {
        if (!first) try bw.writeByte(',');
        // Escape the title for JSON
        try bw.writeAll("\"title\":\"");
        for (new_title) |ch| {
            if (ch == '"' or ch == '\\') try bw.writeByte('\\');
            try bw.writeByte(ch);
        }
        try bw.writeByte('"');
    }
    try bw.writeByte('}');

    const headers = [_]http.Header{
        .{ .name = "Authorization",        .value = auth },
        .{ .name = "Accept",               .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    };
    const resp = try http.request(allocator, .PATCH, url, &headers, body_fbs.getWritten());
    resp.deinit(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const fixture_response =
    \\[
    \\  {"number":42,"title":"Fix crash","body":"stack overflow","state":"open","html_url":"https://github.com/org/repo/issues/42","labels":[{"name":"priority: high"},{"name":"in-progress"}],"milestone":{"due_on":"2026-07-01T00:00:00Z"}},
    \\  {"number":43,"title":"Add feature","body":"","state":"open","html_url":"https://github.com/org/repo/issues/43","labels":[{"name":"priority: urgent"},{"name":"in review"}],"milestone":null},
    \\  {"number":44,"title":"Old bug","body":"details","state":"closed","html_url":"https://github.com/org/repo/issues/44","labels":[],"milestone":null},
    \\  {"number":45,"title":"Low prio","body":"","state":"open","html_url":"https://github.com/org/repo/issues/45","labels":[{"name":"priority: low"}],"milestone":null},
    \\  {"number":46,"title":"P0 item","body":"","state":"open","html_url":"https://github.com/org/repo/issues/46","labels":[{"name":"P0"}],"milestone":null},
    \\  {"number":47,"title":"No labels","body":"","state":"open","html_url":"https://github.com/org/repo/issues/47","labels":[],"milestone":null}
    \\]
;

test "parseIssues: parses all nodes" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(@as(usize, 6), tasks.len);
}

test "parseIssues: external_id is issue number as string" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("42", tasks[0].external_id);
    try std.testing.expectEqualStrings("43", tasks[1].external_id);
}

test "parseIssues: title and body" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("Fix crash",     tasks[0].title);
    try std.testing.expectEqualStrings("stack overflow", tasks[0].description);
}

test "parseIssues: status - open + in-progress label -> in_progress" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.in_progress, tasks[0].status);
}

test "parseIssues: status - open + in review label -> in_review" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.in_review, tasks[1].status);
}

test "parseIssues: status - closed -> done" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.done, tasks[2].status);
}

test "parseIssues: status - open no special labels -> todo" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.todo, tasks[5].status);
}

test "parseIssues: priority - priority: high label" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.high, tasks[0].priority);
}

test "parseIssues: priority - priority: urgent label" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.urgent, tasks[1].priority);
}

test "parseIssues: priority - priority: low label" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.low, tasks[3].priority);
}

test "parseIssues: priority - P0 label -> urgent" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.urgent, tasks[4].priority);
}

test "parseIssues: priority - no labels -> medium default" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.medium, tasks[5].priority);
}

test "parseIssues: due from milestone.due_on truncated to YYYY-MM-DD" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("2026-07-01", tasks[0].due);
}

test "parseIssues: null milestone -> empty due" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("", tasks[1].due);
}

test "parseIssues: url is html_url" {
    const tasks = try parseIssues(std.testing.allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("https://github.com/org/repo/issues/42", tasks[0].url);
}

test "parseIssues: empty array" {
    const tasks = try parseIssues(std.testing.allocator, "[]");
    defer std.testing.allocator.free(tasks);
    try std.testing.expectEqual(@as(usize, 0), tasks.len);
}
