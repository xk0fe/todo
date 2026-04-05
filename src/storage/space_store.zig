/// Space persistence — spaces are subdirectories of the todo root.
const std = @import("std");
const model = @import("../model.zig");

/// Returns all space names (directory entries) under root_dir.
/// Caller owns the returned slice and each string in it.
pub fn list(allocator: std.mem.Allocator, root_dir: std.fs.Dir) ![][]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var iter = root_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    // Sort alphabetically for stable output
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return names.toOwnedSlice(allocator);
}

/// Creates a new space directory. Returns error.AlreadyExists if it exists.
pub fn add(root_dir: std.fs.Dir, name: []const u8) !void {
    root_dir.makeDir(name) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AlreadyExists,
        else => return err,
    };
}

/// Removes a space and all its contents. Returns error.NotFound if it doesn't exist.
pub fn remove(root_dir: std.fs.Dir, name: []const u8) !void {
    // deleteTree doesn't surface FileNotFound, so check existence first
    var check = root_dir.openDir(name, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
    check.close();
    try root_dir.deleteTree(name);
}

/// Returns true if the space directory exists.
pub fn exists(root_dir: std.fs.Dir, name: []const u8) bool {
    var dir = root_dir.openDir(name, .{}) catch return false;
    dir.close();
    return true;
}

pub fn getColor(root_dir: std.fs.Dir, space: []const u8) model.ItemColor {
    var path_buf: [300]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.color", .{space}) catch return .default;
    const file = root_dir.openFile(path, .{}) catch return .default;
    defer file.close();
    var buf: [32]u8 = undefined;
    const n = file.read(&buf) catch return .default;
    return model.ItemColor.fromString(std.mem.trim(u8, buf[0..n], " \t\r\n"));
}

pub fn setColor(root_dir: std.fs.Dir, space: []const u8, color: model.ItemColor) !void {
    var path_buf: [300]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.color", .{space}) catch return error.PathTooLong;
    const file = try root_dir.createFile(path, .{});
    defer file.close();
    try file.writeAll(color.toString());
}

// --- tests ---

test "list: empty root returns empty slice" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const spaces = try list(std.testing.allocator, tmp.dir);
    defer {
        for (spaces) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(spaces);
    }
    try std.testing.expectEqual(@as(usize, 0), spaces.len);
}

test "add and list" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try add(tmp.dir, "work");
    try add(tmp.dir, "personal");

    const spaces = try list(std.testing.allocator, tmp.dir);
    defer {
        for (spaces) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(spaces);
    }
    try std.testing.expectEqual(@as(usize, 2), spaces.len);
    try std.testing.expectEqualStrings("personal", spaces[0]);
    try std.testing.expectEqualStrings("work", spaces[1]);
}

test "add duplicate returns AlreadyExists" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try add(tmp.dir, "work");
    try std.testing.expectError(error.AlreadyExists, add(tmp.dir, "work"));
}

test "remove existing space" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try add(tmp.dir, "work");
    try remove(tmp.dir, "work");
    try std.testing.expect(!exists(tmp.dir, "work"));
}

test "remove nonexistent returns NotFound" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try std.testing.expectError(error.NotFound, remove(tmp.dir, "ghost"));
}

test "exists" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.testing.expect(!exists(tmp.dir, "work"));
    try add(tmp.dir, "work");
    try std.testing.expect(exists(tmp.dir, "work"));
}
