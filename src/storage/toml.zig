/// Minimal TOML-subset parser/serialiser.
/// Only handles flat key = "value" files — no arrays, no tables, no multiline.
const std = @import("std");

pub const Map = std.StringHashMapUnmanaged([]const u8);

/// Parse a key = "value" file into a Map.
/// The caller owns all memory; call freeMap() when done.
/// Values may contain escape sequences: \n, \", \\.
/// Malformed lines are silently skipped so that a single bad entry
/// does not prevent the rest of the file from loading.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Map {
    var map: Map = .empty;
    errdefer freeMap(allocator, &map);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key_raw = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const val_raw = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

        if (key_raw.len == 0) continue;
        if (val_raw.len < 2 or val_raw[0] != '"' or val_raw[val_raw.len - 1] != '"') continue;
        const escaped = val_raw[1 .. val_raw.len - 1];

        // Unescape \n, \", \\ sequences
        const val = try unescape(allocator, escaped);
        errdefer allocator.free(val);

        const key = try allocator.dupe(u8, key_raw);
        errdefer allocator.free(key);

        try map.put(allocator, key, val);
    }
    return map;
}

fn unescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'n'  => { try out.append(allocator, '\n'); i += 2; },
                '"'  => { try out.append(allocator, '"');  i += 2; },
                '\\' => { try out.append(allocator, '\\'); i += 2; },
                else => { try out.append(allocator, s[i]); i += 1; },
            }
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Free all keys, values, and the map itself.
pub fn freeMap(allocator: std.mem.Allocator, map: *Map) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit(allocator);
}

pub const KV = struct { key: []const u8, value: []const u8 };

/// Serialize an ordered list of KV pairs into a `key = "value"\n` string.
/// Special characters in values (\, ", newline) are escaped.
/// Caller owns the returned slice.
pub fn serialize(allocator: std.mem.Allocator, pairs: []const KV) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (pairs) |kv| {
        try out.appendSlice(allocator, kv.key);
        try out.appendSlice(allocator, " = \"");
        for (kv.value) |ch| {
            switch (ch) {
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '"'  => try out.appendSlice(allocator, "\\\""),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => {}, // strip carriage returns
                else => try out.append(allocator, ch),
            }
        }
        try out.appendSlice(allocator, "\"\n");
    }
    return out.toOwnedSlice(allocator);
}

// --- tests ---

test "parse: simple key-value pair" {
    const content = "title = \"Fix login bug\"\nstatus = \"todo\"\n";
    var map = try parse(std.testing.allocator, content);
    defer freeMap(std.testing.allocator, &map);
    try std.testing.expectEqualStrings("Fix login bug", map.get("title").?);
    try std.testing.expectEqualStrings("todo", map.get("status").?);
}

test "parse: empty value" {
    var map = try parse(std.testing.allocator, "due = \"\"\n");
    defer freeMap(std.testing.allocator, &map);
    try std.testing.expectEqualStrings("", map.get("due").?);
}

test "parse: value with spaces" {
    var map = try parse(std.testing.allocator, "notes = \"check the logs carefully\"\n");
    defer freeMap(std.testing.allocator, &map);
    try std.testing.expectEqualStrings("check the logs carefully", map.get("notes").?);
}

test "parse: skips blank lines and comments" {
    const content = "\n# a comment\ntitle = \"hello\"\n\n";
    var map = try parse(std.testing.allocator, content);
    defer freeMap(std.testing.allocator, &map);
    try std.testing.expectEqualStrings("hello", map.get("title").?);
    try std.testing.expectEqual(@as(usize, 1), map.count());
}

test "parse: missing equals is silently skipped" {
    var map = try parse(std.testing.allocator, "noequalssign\n");
    defer freeMap(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "parse: unquoted value is silently skipped" {
    var map = try parse(std.testing.allocator, "key = unquoted\n");
    defer freeMap(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "serialize and parse roundtrip" {
    const pairs = [_]KV{
        .{ .key = "title", .value = "My task" },
        .{ .key = "status", .value = "todo" },
        .{ .key = "priority", .value = "high" },
        .{ .key = "due", .value = "" },
    };
    const serialized = try serialize(std.testing.allocator, &pairs);
    defer std.testing.allocator.free(serialized);

    var map = try parse(std.testing.allocator, serialized);
    defer freeMap(std.testing.allocator, &map);

    try std.testing.expectEqualStrings("My task", map.get("title").?);
    try std.testing.expectEqualStrings("todo", map.get("status").?);
    try std.testing.expectEqualStrings("high", map.get("priority").?);
    try std.testing.expectEqualStrings("", map.get("due").?);
}
