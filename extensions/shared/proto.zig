/// Extension-side protocol helpers: parse the request the todo app sends on
/// stdin and write protocol responses to stdout.
const std = @import("std");
const task = @import("task.zig");
const json_util = @import("json_util.zig");

/// A parsed request: {config, space, project, tasks?}.
pub const Request = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: Request) void {
        self.parsed.deinit();
    }

    pub fn configGet(self: Request, key: []const u8) []const u8 {
        const cfg = switch (self.parsed.value) {
            .object => |m| m.get("config") orelse return "",
            else => return "",
        };
        return json_util.getString(cfg, key);
    }

    pub fn space(self: Request) []const u8 {
        return json_util.getString(self.parsed.value, "space");
    }

    pub fn project(self: Request) []const u8 {
        return json_util.getString(self.parsed.value, "project");
    }

    /// Tasks included in an export request (raw JSON values).
    pub fn tasks(self: Request) []const std.json.Value {
        const v = switch (self.parsed.value) {
            .object => |m| m.get("tasks") orelse return &.{},
            else => return &.{},
        };
        return switch (v) {
            .array => |a| a.items,
            else => &.{},
        };
    }
};

pub fn parseRequest(allocator: std.mem.Allocator, src: []const u8) !Request {
    return Request{ .parsed = try json_util.parseObject(allocator, src) };
}

/// Read all of stdin (the request document).
pub fn readStdin(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.File.stdin().readToEndAlloc(allocator, 16 * 1024 * 1024);
}

pub fn writeJsonString(w: *std.io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// {"tasks":[...]} — the import response.
pub fn writeTasksResponse(w: *std.io.Writer, items: []const task.RemoteTask) !void {
    try w.writeAll("{\"tasks\":[");
    for (items, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"external_id\":");
        try writeJsonString(w, t.external_id);
        try w.writeAll(",\"title\":");
        try writeJsonString(w, t.title);
        try w.writeAll(",\"description\":");
        try writeJsonString(w, t.description);
        try w.writeAll(",\"status\":");
        try writeJsonString(w, t.status.toString());
        try w.writeAll(",\"priority\":");
        try writeJsonString(w, t.priority.toString());
        try w.writeAll(",\"due\":");
        try writeJsonString(w, t.due);
        try w.writeAll(",\"url\":");
        try writeJsonString(w, t.url);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
}

/// {"exported":N,"skipped":M} — the export response.
pub fn writeExportResponse(w: *std.io.Writer, exported: u32, skipped: u32) !void {
    try w.print("{{\"exported\":{d},\"skipped\":{d}}}\n", .{ exported, skipped });
}

/// {"config":{...}} — the setup response.
pub fn writeSetupResponse(w: *std.io.Writer, pairs: []const struct { key: []const u8, value: []const u8 }) !void {
    try w.writeAll("{\"config\":{");
    for (pairs, 0..) |kv, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, kv.key);
        try w.writeByte(':');
        try writeJsonString(w, kv.value);
    }
    try w.writeAll("}}\n");
}

/// {"error":"..."} — failure on any command.
pub fn writeError(w: *std.io.Writer, msg: []const u8) !void {
    try w.writeAll("{\"error\":");
    try writeJsonString(w, msg);
    try w.writeAll("}\n");
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "parseRequest exposes config, space, project and tasks" {
    const src =
        \\{"config":{"api_key":"k1"},"space":"work","project":"api",
        \\ "tasks":[{"external_id":"e1","title":"T","status":"done","source":"linear"}]}
    ;
    const req = try parseRequest(std.testing.allocator, src);
    defer req.deinit();

    try std.testing.expectEqualStrings("k1", req.configGet("api_key"));
    try std.testing.expectEqualStrings("", req.configGet("missing"));
    try std.testing.expectEqualStrings("work", req.space());
    try std.testing.expectEqualStrings("api", req.project());
    try std.testing.expectEqual(@as(usize, 1), req.tasks().len);
    try std.testing.expectEqualStrings("e1", json_util.getString(req.tasks()[0], "external_id"));
}

test "writeTasksResponse emits valid JSON" {
    var buf: [512]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    const items = [_]task.RemoteTask{.{
        .external_id = "e\"1",
        .title = "Line\nbreak",
        .description = "",
        .status = .in_review,
        .priority = .urgent,
        .due = "2026-06-12",
        .url = "https://x",
    }};
    try writeTasksResponse(&w, &items);

    const parsed = try json_util.parseObject(std.testing.allocator, w.buffered());
    defer parsed.deinit();
    const tasks_val = switch (parsed.value) {
        .object => |m| m.get("tasks").?,
        else => unreachable,
    };
    const arr = tasks_val.array.items;
    try std.testing.expectEqualStrings("e\"1", json_util.getString(arr[0], "external_id"));
    try std.testing.expectEqualStrings("Line\nbreak", json_util.getString(arr[0], "title"));
    try std.testing.expectEqualStrings("in-review", json_util.getString(arr[0], "status"));
}

test "writeError escapes the message" {
    var buf: [128]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    try writeError(&w, "bad \"token\"");
    try std.testing.expectEqualStrings("{\"error\":\"bad \\\"token\\\"\"}\n", w.buffered());
}
