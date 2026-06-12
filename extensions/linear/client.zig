/// Linear GraphQL API client.
const std = @import("std");
const shared = @import("shared");
const model = shared.task;
const http = shared.http;
const json_util = shared.json_util;
const types = shared.task;

pub const RemoteTask = types.RemoteTask;

fn mapLinearState(state_type: []const u8, state_name: []const u8) model.Status {
    if (std.mem.eql(u8, state_type, "completed") or std.mem.eql(u8, state_type, "cancelled"))
        return .done;
    if (std.mem.eql(u8, state_type, "started")) {
        // Check if the state name contains "review" (case-insensitive)
        var lower_buf: [64]u8 = undefined;
        const lower = std.ascii.lowerString(lower_buf[0..@min(state_name.len, 63)], state_name[0..@min(state_name.len, 63)]);
        if (std.mem.indexOf(u8, lower, "review") != null) return .in_review;
        return .in_progress;
    }
    return .todo; // triage, backlog, unstarted, unknown
}

fn mapLinearPriority(priority: i64) model.Priority {
    return switch (priority) {
        1 => .urgent,
        2 => .high,
        3 => .medium,
        else => .low, // 0 (no priority), 4 (low), unknown
    };
}

/// Parse Linear GraphQL issues response into a slice of RemoteTask.
/// Caller owns the returned slice and must call types.deinitRemoteTask on each element.
pub fn parseIssues(allocator: std.mem.Allocator, body: []const u8) ![]RemoteTask {
    const parsed = try json_util.parseObject(allocator, body);
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |m| m,
        else => return &.{},
    };
    // A response with GraphQL errors and no usable data means the request
    // failed (bad API key, malformed query) — distinguish from "no issues".
    const data = root.get("data") orelse std.json.Value{ .null = {} };
    if (data != .object and root.get("errors") != null) return error.LinearApiError;
    const issues = switch (data) {
        .object => |m| m.get("issues") orelse return &.{},
        else => return &.{},
    };
    const nodes_val = switch (issues) {
        .object => |m| m.get("nodes") orelse return &.{},
        else => return &.{},
    };
    const nodes = switch (nodes_val) {
        .array => |a| a.items,
        else => return &.{},
    };

    var result = std.ArrayListUnmanaged(RemoteTask){};
    errdefer {
        for (result.items) |t| types.deinitRemoteTask(t, allocator);
        result.deinit(allocator);
    }

    for (nodes) |node| {
        const id  = json_util.getString(node, "id");
        const title = json_util.getString(node, "title");
        const desc_raw = json_util.getString(node, "description");
        const due_raw  = json_util.getString(node, "dueDate");
        const url  = json_util.getString(node, "url");
        const prio = json_util.getInt(node, "priority");

        // state is nested object
        const state_obj = switch (node) {
            .object => |m| m.get("state") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        };
        const state_type = json_util.getString(state_obj, "type");
        const state_name = json_util.getString(state_obj, "name");

        const task = RemoteTask{
            .external_id = try allocator.dupe(u8, id),
            .title       = try allocator.dupe(u8, title),
            .description = try allocator.dupe(u8, desc_raw),
            .status      = mapLinearState(state_type, state_name),
            .priority    = mapLinearPriority(prio),
            .due         = try allocator.dupe(u8, due_raw),
            .url         = try allocator.dupe(u8, url),
        };
        try result.append(allocator, task);
    }

    return result.toOwnedSlice(allocator);
}

const GRAPHQL_QUERY =
    \\{"query":"{issues(filter:{assignee:{isMe:{eq:true}}},first:100){nodes{id title description dueDate url priority state{name type}team{id name}}}}"}
;

/// Fetch issues from Linear API for a specific team/project. Delegates to parseIssues.
pub fn fetchIssues(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    team_id: []const u8,
    project_id: []const u8,
) ![]RemoteTask {
    _ = team_id;
    _ = project_id;

    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = api_key },
    };
    const resp = try http.request(allocator, .POST, "https://api.linear.app/graphql", &headers, GRAPHQL_QUERY);
    defer resp.deinit(allocator);
    return parseIssues(allocator, resp.body);
}

/// Issue bundled with the Linear team it belongs to.
pub const IssueWithTeam = struct {
    team_id:   []const u8,
    team_name: []const u8,
    task:      RemoteTask,

    pub fn deinit(self: IssueWithTeam, allocator: std.mem.Allocator) void {
        allocator.free(self.team_id);
        allocator.free(self.team_name);
        types.deinitRemoteTask(self.task, allocator);
    }
};

/// Fetch all issues assigned to the current user (isMe) across all teams.
pub fn fetchAllAssigned(allocator: std.mem.Allocator, api_key: []const u8) ![]IssueWithTeam {
    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = api_key },
    };
    const resp = try http.request(allocator, .POST, "https://api.linear.app/graphql", &headers, GRAPHQL_QUERY);
    defer resp.deinit(allocator);

    const parsed = try json_util.parseObject(allocator, resp.body);
    defer parsed.deinit();

    const data = switch (parsed.value) {
        .object => |m| m.get("data") orelse return &.{},
        else => return &.{},
    };
    const issues = switch (data) {
        .object => |m| m.get("issues") orelse return &.{},
        else => return &.{},
    };
    const nodes_val = switch (issues) {
        .object => |m| m.get("nodes") orelse return &.{},
        else => return &.{},
    };
    const nodes = switch (nodes_val) {
        .array => |a| a.items,
        else => return &.{},
    };

    var result = std.ArrayListUnmanaged(IssueWithTeam){};
    errdefer {
        for (result.items) |iwt| iwt.deinit(allocator);
        result.deinit(allocator);
    }

    for (nodes) |node| {
        const id       = json_util.getString(node, "id");
        const title    = json_util.getString(node, "title");
        const desc_raw = json_util.getString(node, "description");
        const due_raw  = json_util.getString(node, "dueDate");
        const url      = json_util.getString(node, "url");
        const prio     = json_util.getInt(node, "priority");

        const state_obj = switch (node) {
            .object => |m| m.get("state") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        };
        const state_type = json_util.getString(state_obj, "type");
        const state_name = json_util.getString(state_obj, "name");

        const team_obj = switch (node) {
            .object => |m| m.get("team") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        };
        const t_id   = json_util.getString(team_obj, "id");
        const t_name = json_util.getString(team_obj, "name");

        const task = RemoteTask{
            .external_id = try allocator.dupe(u8, id),
            .title       = try allocator.dupe(u8, title),
            .description = try allocator.dupe(u8, desc_raw),
            .status      = mapLinearState(state_type, state_name),
            .priority    = mapLinearPriority(prio),
            .due         = try allocator.dupe(u8, due_raw),
            .url         = try allocator.dupe(u8, url),
        };
        try result.append(allocator, IssueWithTeam{
            .team_id   = try allocator.dupe(u8, t_id),
            .team_name = try allocator.dupe(u8, if (t_name.len > 0) t_name else "Linear"),
            .task      = task,
        });
    }

    return result.toOwnedSlice(allocator);
}

/// Push a title update back to Linear via GraphQL mutation.
pub fn pushUpdate(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    issue_id: []const u8,
    new_title: []const u8,
) !void {
    if (new_title.len == 0) return;

    var body_buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&body_buf);
    const bw = fbs.writer();
    try bw.writeAll("{\"query\":\"mutation{issueUpdate(id:\\\"");
    for (issue_id) |ch| {
        if (ch == '"' or ch == '\\') try bw.writeByte('\\');
        try bw.writeByte(ch);
    }
    try bw.writeAll("\\\",input:{title:\\\"");
    for (new_title) |ch| {
        if (ch == '"' or ch == '\\') try bw.writeByte('\\');
        try bw.writeByte(ch);
    }
    try bw.writeAll("\\\"}){success}}\"}");

    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = api_key },
    };
    const resp = try http.request(allocator, .POST, "https://api.linear.app/graphql", &headers, fbs.getWritten());
    resp.deinit(allocator);
}

/// Find the best matching Linear workflow state ID for a local status.
/// Parses the response from `{team(id:"..."){states{nodes{id name type}}}}`.
fn findBestStateId(allocator: std.mem.Allocator, body: []const u8, status: model.Status) ![]u8 {
    const parsed = try json_util.parseObject(allocator, body);
    defer parsed.deinit();

    const data = switch (parsed.value) {
        .object => |m| m.get("data") orelse return allocator.dupe(u8, ""),
        else => return allocator.dupe(u8, ""),
    };
    const team_val = switch (data) {
        .object => |m| m.get("team") orelse return allocator.dupe(u8, ""),
        else => return allocator.dupe(u8, ""),
    };
    const states_val = switch (team_val) {
        .object => |m| m.get("states") orelse return allocator.dupe(u8, ""),
        else => return allocator.dupe(u8, ""),
    };
    const nodes_val = switch (states_val) {
        .object => |m| m.get("nodes") orelse return allocator.dupe(u8, ""),
        else => return allocator.dupe(u8, ""),
    };
    const nodes = switch (nodes_val) {
        .array => |a| a.items,
        else => return allocator.dupe(u8, ""),
    };

    // Map local status to the expected Linear state type
    const target_type: []const u8 = switch (status) {
        .todo        => "unstarted",
        .in_progress => "started",
        .in_review   => "started",
        .done        => "completed",
    };

    var best_id: []const u8 = "";

    for (nodes) |node| {
        const id   = json_util.getString(node, "id");
        const name = json_util.getString(node, "name");
        const typ  = json_util.getString(node, "type");
        if (!std.mem.eql(u8, typ, target_type)) continue;

        if (status == .in_review) {
            // Prefer a state whose name contains "review"
            var lower_buf: [64]u8 = undefined;
            const n = @min(name.len, 63);
            const lower = std.ascii.lowerString(lower_buf[0..n], name[0..n]);
            if (std.mem.indexOf(u8, lower, "review") != null) {
                best_id = id;
                break;
            }
            if (best_id.len == 0) best_id = id; // fallback: first "started" state
        } else {
            best_id = id;
            break;
        }
    }

    return allocator.dupe(u8, best_id);
}

/// Push a status change to Linear by resolving the team's workflow state IDs
/// and calling issueUpdate with the matching stateId.
pub fn pushStatusUpdate(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    team_id: []const u8,
    issue_id: []const u8,
    new_status: model.Status,
) !void {
    if (team_id.len == 0) return;

    // Fetch workflow states for the team
    var query_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&query_buf);
    const qw = fbs.writer();
    try qw.writeAll("{\"query\":\"{team(id:\\\"");
    for (team_id) |ch| {
        if (ch == '"' or ch == '\\') try qw.writeByte('\\');
        try qw.writeByte(ch);
    }
    try qw.writeAll("\\\"){states{nodes{id name type}}}}\"}");

    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = api_key },
    };
    const states_resp = try http.request(allocator, .POST, "https://api.linear.app/graphql", &headers, fbs.getWritten());
    defer states_resp.deinit(allocator);

    const state_id = try findBestStateId(allocator, states_resp.body, new_status);
    defer allocator.free(state_id);
    if (state_id.len == 0) return;

    // Push stateId via issueUpdate mutation
    var body_buf: [1024]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&body_buf);
    const bw = fbs2.writer();
    try bw.writeAll("{\"query\":\"mutation{issueUpdate(id:\\\"");
    for (issue_id) |ch| {
        if (ch == '"' or ch == '\\') try bw.writeByte('\\');
        try bw.writeByte(ch);
    }
    try bw.writeAll("\\\",input:{stateId:\\\"");
    for (state_id) |ch| {
        if (ch == '"' or ch == '\\') try bw.writeByte('\\');
        try bw.writeByte(ch);
    }
    try bw.writeAll("\\\"}){success}}\"}");

    const resp = try http.request(allocator, .POST, "https://api.linear.app/graphql", &headers, fbs2.getWritten());
    resp.deinit(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const fixture_response =
    \\{"data":{"issues":{"nodes":[
    \\  {"id":"abc","title":"Fix bug","description":"details","dueDate":"2026-06-01","url":"https://linear.app/issue/abc","priority":2,"state":{"name":"In Progress","type":"started"}},
    \\  {"id":"def","title":"Review PR","description":"","dueDate":null,"url":"https://linear.app/issue/def","priority":1,"state":{"name":"In Review","type":"started"}},
    \\  {"id":"ghi","title":"Deploy","description":null,"dueDate":null,"url":"","priority":0,"state":{"name":"Done","type":"completed"}},
    \\  {"id":"jkl","title":"Backlog item","description":"","dueDate":null,"url":"","priority":4,"state":{"name":"Backlog","type":"backlog"}},
    \\  {"id":"mno","title":"Triage item","description":"","dueDate":null,"url":"","priority":3,"state":{"name":"Triage","type":"triage"}}
    \\]}}}
;

test "parseIssues: parses all nodes" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(@as(usize, 5), tasks.len);
}

test "parseIssues: external_id and title" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("abc",     tasks[0].external_id);
    try std.testing.expectEqualStrings("Fix bug", tasks[0].title);
    try std.testing.expectEqualStrings("details", tasks[0].description);
}

test "parseIssues: status mapping - started without review -> in_progress" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.in_progress, tasks[0].status);
}

test "parseIssues: status mapping - started with review in name -> in_review" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.in_review, tasks[1].status);
}

test "parseIssues: status mapping - completed -> done" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.done, tasks[2].status);
}

test "parseIssues: status mapping - backlog -> todo" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.todo, tasks[3].status);
}

test "parseIssues: status mapping - triage -> todo" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.todo, tasks[4].status);
}

test "parseIssues: priority mapping - 2 -> high" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.high, tasks[0].priority);
}

test "parseIssues: priority mapping - 1 -> urgent" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.urgent, tasks[1].priority);
}

test "parseIssues: priority mapping - 0 -> low" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.low, tasks[2].priority);
}

test "parseIssues: priority mapping - 4 -> low" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.low, tasks[3].priority);
}

test "parseIssues: priority mapping - 3 -> medium" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.medium, tasks[4].priority);
}

test "parseIssues: null dueDate produces empty due" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("2026-06-01", tasks[0].due);
    try std.testing.expectEqualStrings("", tasks[1].due);
}

test "parseIssues: null description produces empty string" {
    const allocator = std.testing.allocator;
    const tasks = try parseIssues(allocator, fixture_response);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("", tasks[2].description);
}

test "parseIssues: GraphQL errors without data surface as LinearApiError" {
    const body = "{\"errors\":[{\"message\":\"Authentication required\"}],\"data\":null}";
    try std.testing.expectError(error.LinearApiError, parseIssues(std.testing.allocator, body));
}

test "parseIssues: empty nodes array" {
    const allocator = std.testing.allocator;
    const empty = "{\"data\":{\"issues\":{\"nodes\":[]}}}";
    const tasks = try parseIssues(allocator, empty);
    defer allocator.free(tasks);
    try std.testing.expectEqual(@as(usize, 0), tasks.len);
}
