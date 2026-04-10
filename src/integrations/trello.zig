/// Trello REST API integration adapter.
const std = @import("std");
const model = @import("../model.zig");
const http = @import("http.zig");
const json_util = @import("json_util.zig");
const types = @import("types.zig");

pub const RemoteTask = types.RemoteTask;

pub const TrelloListMap = struct {
    todo:        []const u8,
    in_progress: []const u8,
    in_review:   []const u8,
    done:        []const u8,
};

fn mapTrelloList(id_list: []const u8, list_map: TrelloListMap) model.Status {
    if (std.mem.eql(u8, id_list, list_map.done))        return .done;
    if (std.mem.eql(u8, id_list, list_map.in_review))   return .in_review;
    if (std.mem.eql(u8, id_list, list_map.in_progress)) return .in_progress;
    if (std.mem.eql(u8, id_list, list_map.todo))        return .todo;
    return .todo; // unknown list -> safe default
}

fn mapTrelloPriority(labels: std.json.Value) model.Priority {
    const items = switch (labels) {
        .array => |a| a.items,
        else => return .medium,
    };
    for (items) |label| {
        const name = json_util.getString(label, "name");
        var lower_buf: [64]u8 = undefined;
        const lower = std.ascii.lowerString(lower_buf[0..@min(name.len, 63)], name[0..@min(name.len, 63)]);
        if (std.mem.eql(u8, lower, "priority: urgent") or std.mem.eql(u8, lower, "p0")) return .urgent;
        if (std.mem.eql(u8, lower, "priority: high")   or std.mem.eql(u8, lower, "p1")) return .high;
        if (std.mem.eql(u8, lower, "priority: medium") or std.mem.eql(u8, lower, "p2")) return .medium;
        if (std.mem.eql(u8, lower, "priority: low")    or std.mem.eql(u8, lower, "p3")) return .low;
    }
    return .medium;
}

/// Parse Trello board cards response into a slice of RemoteTask.
/// Caller owns the returned slice and must call types.deinitRemoteTask on each element.
pub fn parseCards(allocator: std.mem.Allocator, body: []const u8, list_map: TrelloListMap) ![]RemoteTask {
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
        const id      = json_util.getString(item, "id");
        const name    = json_util.getString(item, "name");
        const desc    = json_util.getString(item, "desc");
        const id_list = json_util.getString(item, "idList");
        const url     = json_util.getString(item, "shortUrl");
        const due_raw = json_util.getString(item, "due");

        const labels = switch (item) {
            .object => |m| m.get("labels") orelse std.json.Value{ .array = std.json.Array.init(allocator) },
            else => std.json.Value{ .array = std.json.Array.init(allocator) },
        };

        // Truncate ISO timestamp to YYYY-MM-DD (first 10 chars)
        const due = if (due_raw.len >= 10) due_raw[0..10] else due_raw;

        const task = RemoteTask{
            .external_id = try allocator.dupe(u8, id),
            .title       = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, desc),
            .status      = mapTrelloList(id_list, list_map),
            .priority    = mapTrelloPriority(labels),
            .due         = try allocator.dupe(u8, due),
            .url         = try allocator.dupe(u8, url),
        };
        try result.append(allocator, task);
    }

    return result.toOwnedSlice(allocator);
}

/// Fetch all cards from a Trello board. Delegates to parseCards.
pub fn fetchCards(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    token: []const u8,
    board_id: []const u8,
    list_map: TrelloListMap,
) ![]RemoteTask {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://api.trello.com/1/boards/{s}/cards?key={s}&token={s}&fields=id,name,desc,idList,due,shortUrl,labels",
        .{ board_id, api_key, token },
    ) catch return error.PathTooLong;

    const resp = try http.request(allocator, .GET, url, &.{}, null);
    defer resp.deinit(allocator);
    return parseCards(allocator, resp.body, list_map);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const test_list_map = TrelloListMap{
    .todo        = "list-todo",
    .in_progress = "list-inprog",
    .in_review   = "list-review",
    .done        = "list-done",
};

const fixture_response =
    \\[
    \\  {"id":"card1","name":"Task A","desc":"do it","idList":"list-todo","due":"2026-05-01T00:00:00.000Z","shortUrl":"https://trello.com/c/abc","labels":[{"name":"priority: high"}]},
    \\  {"id":"card2","name":"Task B","desc":"","idList":"list-inprog","due":null,"shortUrl":"https://trello.com/c/def","labels":[]},
    \\  {"id":"card3","name":"Task C","desc":"done thing","idList":"list-done","due":null,"shortUrl":"https://trello.com/c/ghi","labels":[{"name":"P0"}]},
    \\  {"id":"card4","name":"Task D","desc":"","idList":"list-review","due":null,"shortUrl":"https://trello.com/c/jkl","labels":[{"name":"priority: low"}]},
    \\  {"id":"card5","name":"Task E","desc":"","idList":"list-unknown","due":null,"shortUrl":"https://trello.com/c/mno","labels":[]}
    \\]
;

test "parseCards: parses all cards" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(@as(usize, 5), tasks.len);
}

test "parseCards: external_id is card id" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("card1", tasks[0].external_id);
    try std.testing.expectEqualStrings("card2", tasks[1].external_id);
}

test "parseCards: title and description" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("Task A", tasks[0].title);
    try std.testing.expectEqualStrings("do it",  tasks[0].description);
}

test "parseCards: list_map.todo -> todo status" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.todo, tasks[0].status);
}

test "parseCards: list_map.in_progress -> in_progress status" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.in_progress, tasks[1].status);
}

test "parseCards: list_map.done -> done status" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.done, tasks[2].status);
}

test "parseCards: list_map.in_review -> in_review status" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.in_review, tasks[3].status);
}

test "parseCards: unknown list -> todo (safe default)" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Status.todo, tasks[4].status);
}

test "parseCards: due ISO timestamp truncated to YYYY-MM-DD" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("2026-05-01", tasks[0].due);
}

test "parseCards: null due -> empty string" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("", tasks[1].due);
}

test "parseCards: priority label - priority: high" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.high, tasks[0].priority);
}

test "parseCards: priority label - P0 -> urgent" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.urgent, tasks[2].priority);
}

test "parseCards: priority label - priority: low" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.low, tasks[3].priority);
}

test "parseCards: no labels -> medium default" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqual(model.Priority.medium, tasks[1].priority);
}

test "parseCards: url is shortUrl" {
    const tasks = try parseCards(std.testing.allocator, fixture_response, test_list_map);
    defer {
        for (tasks) |t| types.deinitRemoteTask(t, std.testing.allocator);
        std.testing.allocator.free(tasks);
    }
    try std.testing.expectEqualStrings("https://trello.com/c/abc", tasks[0].url);
}

test "parseCards: empty array" {
    const tasks = try parseCards(std.testing.allocator, "[]", test_list_map);
    defer std.testing.allocator.free(tasks);
    try std.testing.expectEqual(@as(usize, 0), tasks.len);
}
