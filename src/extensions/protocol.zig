/// Extension protocol — JSON messages exchanged with extension executables.
///
/// An extension is any executable in <root>/extensions/. It is invoked as
/// `<ext> <command>` where command is one of: manifest, import, export, setup.
///
///   manifest  no stdin; stdout = manifest JSON (name, description,
///             capabilities, config key declarations).
///   import    stdin = request JSON {config, space, project};
///             stdout = {"tasks":[{external_id,title,description,status,
///             priority,due,url}, ...]} or {"error":"..."}.
///   export    stdin = request JSON {config, space, project, tasks:[...]};
///             stdout = {"exported":N,"skipped":M} or {"error":"..."}.
///   setup     interactive (stderr/stdin are the user's terminal); existing
///             config is passed via the TODO_EXT_CONFIG env var; stdout =
///             {"config":{key:value,...}} which the app saves.
const std = @import("std");
const model = @import("../model.zig");
const types = @import("types.zig");

pub const KV = struct { key: []const u8, value: []const u8 };

pub const ConfigKey = struct {
    key:    []u8,
    label:  []u8,
    secret: bool,
};

pub const Manifest = struct {
    name:        []u8,
    version:     []u8,
    description: []u8,
    can_import:  bool,
    can_export:  bool,
    can_setup:   bool,
    config_keys: []ConfigKey,

    pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        for (self.config_keys) |ck| {
            allocator.free(ck.key);
            allocator.free(ck.label);
        }
        allocator.free(self.config_keys);
    }
};

fn parseJson(allocator: std.mem.Allocator, src: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, src, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

fn getString(obj: std.json.Value, key: []const u8) []const u8 {
    const map = switch (obj) {
        .object => |m| m,
        else => return "",
    };
    const v = map.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn getBool(obj: std.json.Value, key: []const u8) bool {
    const map = switch (obj) {
        .object => |m| m,
        else => return false,
    };
    const v = map.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn getArray(obj: std.json.Value, key: []const u8) []const std.json.Value {
    const map = switch (obj) {
        .object => |m| m,
        else => return &.{},
    };
    const v = map.get(key) orelse return &.{};
    return switch (v) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn getInt(obj: std.json.Value, key: []const u8) i64 {
    const map = switch (obj) {
        .object => |m| m,
        else => return 0,
    };
    const v = map.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        else => 0,
    };
}

/// Parse a manifest JSON document. Caller must call manifest.deinit().
pub fn parseManifest(allocator: std.mem.Allocator, json: []const u8) !Manifest {
    const parsed = try parseJson(allocator, json);
    defer parsed.deinit();
    const v = parsed.value;

    const name = getString(v, "name");
    if (name.len == 0) return error.InvalidManifest;

    var caps_import = false;
    var caps_export = false;
    var caps_setup = false;
    for (getArray(v, "capabilities")) |cap| {
        const s = switch (cap) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, s, "import")) caps_import = true;
        if (std.mem.eql(u8, s, "export")) caps_export = true;
        if (std.mem.eql(u8, s, "setup")) caps_setup = true;
    }

    var keys = std.ArrayListUnmanaged(ConfigKey){};
    errdefer {
        for (keys.items) |ck| {
            allocator.free(ck.key);
            allocator.free(ck.label);
        }
        keys.deinit(allocator);
    }
    for (getArray(v, "config")) |entry| {
        const key = getString(entry, "key");
        if (key.len == 0) continue;
        const label = getString(entry, "label");
        try keys.append(allocator, .{
            .key    = try allocator.dupe(u8, key),
            .label  = try allocator.dupe(u8, if (label.len > 0) label else key),
            .secret = getBool(entry, "secret"),
        });
    }

    return Manifest{
        .name        = try allocator.dupe(u8, name),
        .version     = try allocator.dupe(u8, getString(v, "version")),
        .description = try allocator.dupe(u8, getString(v, "description")),
        .can_import  = caps_import,
        .can_export  = caps_export,
        .can_setup   = caps_setup,
        .config_keys = try keys.toOwnedSlice(allocator),
    };
}

fn writeJsonString(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"'  => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    var buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                    try out.appendSlice(allocator, esc);
                } else {
                    try out.append(allocator, ch);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

/// Build the JSON config object {"key":"value",...} alone — used for the
/// TODO_EXT_CONFIG env var passed to `setup`.
pub fn buildConfigObject(allocator: std.mem.Allocator, config: []const KV) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    for (config, 0..) |kv, i| {
        if (i > 0) try out.append(allocator, ',');
        try writeJsonString(&out, allocator, kv.key);
        try out.append(allocator, ':');
        try writeJsonString(&out, allocator, kv.value);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// Build the request JSON sent to an extension on stdin.
/// `tasks` is included only for export.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    config: []const KV,
    space: []const u8,
    project: []const u8,
    tasks: ?[]const model.Task,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"config\":");
    const cfg = try buildConfigObject(allocator, config);
    defer allocator.free(cfg);
    try out.appendSlice(allocator, cfg);

    try out.appendSlice(allocator, ",\"space\":");
    try writeJsonString(&out, allocator, space);
    try out.appendSlice(allocator, ",\"project\":");
    try writeJsonString(&out, allocator, project);

    if (tasks) |ts| {
        try out.appendSlice(allocator, ",\"tasks\":[");
        for (ts, 0..) |t, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, "{\"id\":");
            var id_buf: [12]u8 = undefined;
            try out.appendSlice(allocator, std.fmt.bufPrint(&id_buf, "{d}", .{t.id}) catch unreachable);
            try out.appendSlice(allocator, ",\"external_id\":");
            try writeJsonString(&out, allocator, t.external_id);
            try out.appendSlice(allocator, ",\"source\":");
            try writeJsonString(&out, allocator, t.source);
            try out.appendSlice(allocator, ",\"title\":");
            try writeJsonString(&out, allocator, t.title);
            try out.appendSlice(allocator, ",\"description\":");
            try writeJsonString(&out, allocator, t.description);
            try out.appendSlice(allocator, ",\"status\":");
            try writeJsonString(&out, allocator, t.status.toString());
            try out.appendSlice(allocator, ",\"priority\":");
            try writeJsonString(&out, allocator, t.priority.toString());
            try out.appendSlice(allocator, ",\"due\":");
            try writeJsonString(&out, allocator, t.due);
            try out.appendSlice(allocator, ",\"url\":");
            try writeJsonString(&out, allocator, t.url);
            try out.append(allocator, '}');
        }
        try out.append(allocator, ']');
    }

    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub const ImportPayload = struct {
    tasks:   []types.RemoteTask,
    err_msg: ?[]u8, // non-null → extension reported an error

    pub fn deinit(self: ImportPayload, allocator: std.mem.Allocator) void {
        for (self.tasks) |t| types.deinitRemoteTask(t, allocator);
        allocator.free(self.tasks);
        if (self.err_msg) |m| allocator.free(m);
    }
};

/// Parse an import response. Unknown status/priority strings fall back to
/// todo/medium so one bad task does not abort the import.
pub fn parseImportResponse(allocator: std.mem.Allocator, json: []const u8) !ImportPayload {
    const parsed = try parseJson(allocator, json);
    defer parsed.deinit();
    const v = parsed.value;

    const err = getString(v, "error");
    if (err.len > 0) {
        return ImportPayload{ .tasks = &.{}, .err_msg = try allocator.dupe(u8, err) };
    }

    var result = std.ArrayListUnmanaged(types.RemoteTask){};
    errdefer {
        for (result.items) |t| types.deinitRemoteTask(t, allocator);
        result.deinit(allocator);
    }

    for (getArray(v, "tasks")) |item| {
        const external_id = getString(item, "external_id");
        const title = getString(item, "title");
        if (external_id.len == 0 or title.len == 0) continue;

        const status = model.Status.fromString(getString(item, "status")) catch .todo;
        const priority = model.Priority.fromString(getString(item, "priority")) catch .medium;

        try result.append(allocator, .{
            .external_id = try allocator.dupe(u8, external_id),
            .title       = try allocator.dupe(u8, title),
            .description = try allocator.dupe(u8, getString(item, "description")),
            .status      = status,
            .priority    = priority,
            .due         = try allocator.dupe(u8, getString(item, "due")),
            .url         = try allocator.dupe(u8, getString(item, "url")),
        });
    }

    return ImportPayload{
        .tasks   = try result.toOwnedSlice(allocator),
        .err_msg = null,
    };
}

pub const ExportPayload = struct {
    exported: u32,
    skipped:  u32,
    err_msg:  ?[]u8,

    pub fn deinit(self: ExportPayload, allocator: std.mem.Allocator) void {
        if (self.err_msg) |m| allocator.free(m);
    }
};

pub fn parseExportResponse(allocator: std.mem.Allocator, json: []const u8) !ExportPayload {
    const parsed = try parseJson(allocator, json);
    defer parsed.deinit();
    const v = parsed.value;

    const err = getString(v, "error");
    if (err.len > 0) {
        return ExportPayload{ .exported = 0, .skipped = 0, .err_msg = try allocator.dupe(u8, err) };
    }
    return ExportPayload{
        .exported = @intCast(@max(0, getInt(v, "exported"))),
        .skipped  = @intCast(@max(0, getInt(v, "skipped"))),
        .err_msg  = null,
    };
}

/// Parse a setup response: {"config":{key:value,...}}.
/// Returns an owned list of owned KV pairs.
pub const SetupPayload = struct {
    pairs:   []KV,
    err_msg: ?[]u8,

    pub fn deinit(self: SetupPayload, allocator: std.mem.Allocator) void {
        for (self.pairs) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(self.pairs);
        if (self.err_msg) |m| allocator.free(m);
    }
};

pub fn parseSetupResponse(allocator: std.mem.Allocator, json: []const u8) !SetupPayload {
    const parsed = try parseJson(allocator, json);
    defer parsed.deinit();
    const v = parsed.value;

    const err = getString(v, "error");
    if (err.len > 0) {
        return SetupPayload{ .pairs = &.{}, .err_msg = try allocator.dupe(u8, err) };
    }

    var pairs = std.ArrayListUnmanaged(KV){};
    errdefer {
        for (pairs.items) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        pairs.deinit(allocator);
    }

    const cfg = switch (v) {
        .object => |m| m.get("config") orelse std.json.Value{ .null = {} },
        else => std.json.Value{ .null = {} },
    };
    switch (cfg) {
        .object => |m| {
            var it = m.iterator();
            while (it.next()) |entry| {
                const val = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                try pairs.append(allocator, .{
                    .key   = try allocator.dupe(u8, entry.key_ptr.*),
                    .value = try allocator.dupe(u8, val),
                });
            }
        },
        else => {},
    }

    return SetupPayload{ .pairs = try pairs.toOwnedSlice(allocator), .err_msg = null };
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "parseManifest: full manifest" {
    const json =
        \\{"name":"linear","version":"1.0.0","description":"Sync with Linear",
        \\ "capabilities":["import","export"],
        \\ "config":[{"key":"api_key","label":"Linear API key","secret":true},
        \\           {"key":"team_id","label":"Team ID"}]}
    ;
    const m = try parseManifest(std.testing.allocator, json);
    defer m.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("linear", m.name);
    try std.testing.expectEqualStrings("1.0.0", m.version);
    try std.testing.expect(m.can_import);
    try std.testing.expect(m.can_export);
    try std.testing.expect(!m.can_setup);
    try std.testing.expectEqual(@as(usize, 2), m.config_keys.len);
    try std.testing.expectEqualStrings("api_key", m.config_keys[0].key);
    try std.testing.expectEqualStrings("Linear API key", m.config_keys[0].label);
    try std.testing.expect(m.config_keys[0].secret);
    try std.testing.expect(!m.config_keys[1].secret);
}

test "parseManifest: missing name is invalid" {
    try std.testing.expectError(
        error.InvalidManifest,
        parseManifest(std.testing.allocator, "{\"description\":\"x\"}"),
    );
}

test "parseManifest: label defaults to key" {
    const m = try parseManifest(std.testing.allocator, "{\"name\":\"x\",\"config\":[{\"key\":\"token\"}]}");
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("token", m.config_keys[0].label);
}

test "buildRequest: import request with escaping" {
    const cfg = [_]KV{.{ .key = "api_key", .value = "se\"cret" }};
    const req = try buildRequest(std.testing.allocator, &cfg, "wo\\rk", "api", null);
    defer std.testing.allocator.free(req);
    try std.testing.expectEqualStrings(
        "{\"config\":{\"api_key\":\"se\\\"cret\"},\"space\":\"wo\\\\rk\",\"project\":\"api\"}",
        req,
    );
}

test "buildRequest: export request includes tasks" {
    const task = model.Task{
        .id          = 7,
        .title       = "Fix \"it\"",
        .status      = .in_progress,
        .priority    = .high,
        .description = "line1\nline2",
        .created     = "2026-01-01",
        .due         = "",
        .subtasks    = &.{},
        .external_id = "abc",
        .source      = "linear",
        .synced_at   = "",
        .url         = "https://example.com",
    };
    const req = try buildRequest(std.testing.allocator, &.{}, "work", "api", &.{task});
    defer std.testing.allocator.free(req);

    // The request must be valid JSON containing the task fields
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, req, .{});
    defer parsed.deinit();
    const tasks = getArray(parsed.value, "tasks");
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expectEqualStrings("Fix \"it\"", getString(tasks[0], "title"));
    try std.testing.expectEqualStrings("in-progress", getString(tasks[0], "status"));
    try std.testing.expectEqualStrings("abc", getString(tasks[0], "external_id"));
    try std.testing.expectEqualStrings("linear", getString(tasks[0], "source"));
    try std.testing.expectEqual(@as(i64, 7), getInt(tasks[0], "id"));
}

test "parseImportResponse: tasks parsed with fallbacks" {
    const json =
        \\{"tasks":[
        \\  {"external_id":"e1","title":"A","status":"in-progress","priority":"high","due":"2026-06-01","url":"u"},
        \\  {"external_id":"e2","title":"B","status":"bogus","priority":"bogus"},
        \\  {"external_id":"","title":"skipped"},
        \\  {"external_id":"e3","title":""}
        \\]}
    ;
    const payload = try parseImportResponse(std.testing.allocator, json);
    defer payload.deinit(std.testing.allocator);

    try std.testing.expect(payload.err_msg == null);
    try std.testing.expectEqual(@as(usize, 2), payload.tasks.len);
    try std.testing.expectEqual(model.Status.in_progress, payload.tasks[0].status);
    try std.testing.expectEqual(model.Status.todo, payload.tasks[1].status);
    try std.testing.expectEqual(model.Priority.medium, payload.tasks[1].priority);
}

test "parseImportResponse: error payload" {
    const payload = try parseImportResponse(std.testing.allocator, "{\"error\":\"bad token\"}");
    defer payload.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bad token", payload.err_msg.?);
    try std.testing.expectEqual(@as(usize, 0), payload.tasks.len);
}

test "parseExportResponse: counts and error" {
    const ok = try parseExportResponse(std.testing.allocator, "{\"exported\":3,\"skipped\":1}");
    defer ok.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), ok.exported);
    try std.testing.expectEqual(@as(u32, 1), ok.skipped);

    const fail = try parseExportResponse(std.testing.allocator, "{\"error\":\"nope\"}");
    defer fail.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("nope", fail.err_msg.?);
}

test "parseSetupResponse: config pairs" {
    const payload = try parseSetupResponse(std.testing.allocator, "{\"config\":{\"token\":\"ghp_x\"}}");
    defer payload.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), payload.pairs.len);
    try std.testing.expectEqualStrings("token", payload.pairs[0].key);
    try std.testing.expectEqualStrings("ghp_x", payload.pairs[0].value);
}
