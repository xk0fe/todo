/// Minimal TOML-subset parser/serialiser.
/// Only handles flat key = "value" files — no arrays, no tables, no multiline.
const std = @import("std");

pub const Map = std.StringHashMapUnmanaged([]const u8);

/// Parse a key = "value" file into a Map.
/// The caller owns all memory; call freeMap() when done.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Map {
    var map: Map = .empty;
    errdefer freeMap(allocator, &map);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.InvalidToml;
        const key_raw = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const val_raw = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

        if (key_raw.len == 0) return error.InvalidToml;
        if (val_raw.len < 2 or val_raw[0] != '"' or val_raw[val_raw.len - 1] != '"') {
            return error.InvalidToml;
        }
        const value = val_raw[1 .. val_raw.len - 1];

        const key = try allocator.dupe(u8, key_raw);
        errdefer allocator.free(key);
        const val = try allocator.dupe(u8, value);
        errdefer allocator.free(val);

        try map.put(allocator, key, val);
    }
    return map;
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
/// Caller owns the returned slice.
pub fn serialize(allocator: std.mem.Allocator, pairs: []const KV) ![]u8 {
    // Pre-calculate exact size: key + ' = "' + value + '"\n' = key.len + value.len + 6
    var total: usize = 0;
    for (pairs) |kv| total += kv.key.len + kv.value.len + 6;

    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    var pos: usize = 0;
    for (pairs) |kv| {
        const written = std.fmt.bufPrint(buf[pos..], "{s} = \"{s}\"\n", .{ kv.key, kv.value }) catch unreachable;
        pos += written.len;
    }
    return buf;
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

test "parse: missing equals returns error" {
    try std.testing.expectError(error.InvalidToml, parse(std.testing.allocator, "noequalssign\n"));
}

test "parse: unquoted value returns error" {
    try std.testing.expectError(error.InvalidToml, parse(std.testing.allocator, "key = unquoted\n"));
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
