const std = @import("std");

pub fn eql(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

pub fn matchesAny(actual: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        if (eql(actual, name)) return true;
    }
    return false;
}

pub fn getFlag(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (eql(args[i], flag)) return args[i + 1];
    }
    return null;
}

test "getFlag returns value after matching flag" {
    const argv = &.{ "task", "--priority", "high", "--due", "2026-06-01" };
    try std.testing.expectEqualStrings("high", getFlag(argv, "--priority").?);
    try std.testing.expectEqualStrings("2026-06-01", getFlag(argv, "--due").?);
    try std.testing.expectEqual(@as(?[]const u8, null), getFlag(argv, "--missing"));
}

test "matchesAny accepts aliases" {
    try std.testing.expect(matchesAny("rm", &.{ "rm", "remove" }));
    try std.testing.expect(!matchesAny("delete", &.{ "rm", "remove" }));
}
