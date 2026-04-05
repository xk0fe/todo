/// Project persistence — projects are subdirectories of a space, with a project.toml metadata file.
const std = @import("std");
const toml = @import("toml.zig");
const model = @import("../model.zig");

/// Returns all project names under root_dir/<space>.
/// Caller owns the returned slice and each string in it.
pub fn list(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8) ![][]const u8 {
    var space_dir = root_dir.openDir(space, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SpaceNotFound,
        else => return err,
    };
    defer space_dir.close();

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var iter = space_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return names.toOwnedSlice(allocator);
}

/// Creates a project directory and writes an initial project.toml.
pub fn add(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, name: []const u8) !void {
    var space_dir = root_dir.openDir(space, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SpaceNotFound,
        else => return err,
    };
    defer space_dir.close();

    space_dir.makeDir(name) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AlreadyExists,
        else => return err,
    };

    var proj_dir = try space_dir.openDir(name, .{});
    defer proj_dir.close();

    // Write project.toml
    const pairs = [_]toml.KV{
        .{ .key = "name",        .value = name },
        .{ .key = "description", .value = "" },
        .{ .key = "color",       .value = "default" },
    };
    const content = try toml.serialize(allocator, &pairs);
    defer allocator.free(content);

    const file = try proj_dir.createFile("project.toml", .{});
    defer file.close();
    try file.writeAll(content);
}

/// Removes a project and all its contents.
pub fn remove(root_dir: std.fs.Dir, space: []const u8, name: []const u8) !void {
    var space_dir = root_dir.openDir(space, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SpaceNotFound,
        else => return err,
    };
    defer space_dir.close();

    // deleteTree doesn't surface FileNotFound, so check existence first
    var check = space_dir.openDir(name, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
    check.close();
    try space_dir.deleteTree(name);
}

/// Returns true if the project directory exists.
pub fn exists(root_dir: std.fs.Dir, space: []const u8, name: []const u8) bool {
    var space_dir = root_dir.openDir(space, .{}) catch return false;
    defer space_dir.close();
    var dir = space_dir.openDir(name, .{}) catch return false;
    dir.close();
    return true;
}

pub fn getColor(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8) model.ItemColor {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/project.toml", .{ space, project }) catch return .default;
    const file = root_dir.openFile(path, .{}) catch return .default;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 4096) catch return .default;
    defer allocator.free(content);
    var map = toml.parse(allocator, content) catch return .default;
    defer toml.freeMap(allocator, &map);
    return model.ItemColor.fromString(map.get("color") orelse "default");
}

pub fn setColor(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8, color: model.ItemColor) !void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/project.toml", .{ space, project }) catch return error.PathTooLong;
    {
        const rf = try root_dir.openFile(path, .{});
        const content = try rf.readToEndAlloc(allocator, 4096);
        rf.close();
        defer allocator.free(content);
        var map = try toml.parse(allocator, content);
        defer toml.freeMap(allocator, &map);
        const pairs = [_]toml.KV{
            .{ .key = "name",        .value = map.get("name")        orelse project },
            .{ .key = "description", .value = map.get("description") orelse "" },
            .{ .key = "color",       .value = color.toString() },
        };
        const new_content = try toml.serialize(allocator, &pairs);
        defer allocator.free(new_content);
        const wf = try root_dir.createFile(path, .{});
        defer wf.close();
        try wf.writeAll(new_content);
    }
}

// --- tests ---

test "list: missing space returns SpaceNotFound" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try std.testing.expectError(error.SpaceNotFound, list(std.testing.allocator, tmp.dir, "ghost"));
}

test "add and list" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makeDir("work");
    try add(std.testing.allocator, tmp.dir, "work", "api");
    try add(std.testing.allocator, tmp.dir, "work", "web");

    const projects = try list(std.testing.allocator, tmp.dir, "work");
    defer {
        for (projects) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(projects);
    }
    try std.testing.expectEqual(@as(usize, 2), projects.len);
    try std.testing.expectEqualStrings("api", projects[0]);
    try std.testing.expectEqualStrings("web", projects[1]);
}

test "add creates project.toml" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makeDir("work");
    try add(std.testing.allocator, tmp.dir, "work", "api");

    var proj_dir = try tmp.dir.openDir("work/api", .{});
    defer proj_dir.close();
    const file = try proj_dir.openFile("project.toml", .{});
    file.close();
}

test "add duplicate returns AlreadyExists" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makeDir("work");
    try add(std.testing.allocator, tmp.dir, "work", "api");
    try std.testing.expectError(error.AlreadyExists, add(std.testing.allocator, tmp.dir, "work", "api"));
}

test "remove project" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makeDir("work");
    try add(std.testing.allocator, tmp.dir, "work", "api");
    try remove(tmp.dir, "work", "api");
    try std.testing.expect(!exists(tmp.dir, "work", "api"));
}
