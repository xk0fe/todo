/// JSON parsing helpers for remote API responses.
const std = @import("std");

/// Parse a JSON value from `src`. Caller must call `.deinit()` on the result.
pub fn parseObject(allocator: std.mem.Allocator, src: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, src, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

/// Return the string value at `key` in a JSON object, or "" if missing / not a string.
pub fn getString(obj: std.json.Value, key: []const u8) []const u8 {
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

/// Return the integer value at `key` in a JSON object, or 0 if missing / not an integer.
pub fn getInt(obj: std.json.Value, key: []const u8) i64 {
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

// ── tests ─────────────────────────────────────────────────────────────────────

test "getString returns value for present string key" {
    const parsed = try parseObject(std.testing.allocator, "{\"name\":\"hello\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello", getString(parsed.value, "name"));
    try std.testing.expectEqualStrings("", getString(parsed.value, "missing"));
}

test "getInt returns value for present integer key" {
    const parsed = try parseObject(std.testing.allocator, "{\"count\":42}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), getInt(parsed.value, "count"));
    try std.testing.expectEqual(@as(i64, 0), getInt(parsed.value, "missing"));
}
