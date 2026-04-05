const std = @import("std");
const space_store = @import("../storage/space_store.zig");

pub fn cmdAdd(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    _ = allocator;
    if (args.len < 1) return error.MissingArgument;
    const name = args[0];
    try space_store.add(root_dir, name);
    try writer.print("Space '{s}' created.\n", .{name});
}

pub fn cmdList(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    _ = args;
    const spaces = try space_store.list(allocator, root_dir);
    defer {
        for (spaces) |s| allocator.free(s);
        allocator.free(spaces);
    }
    if (spaces.len == 0) {
        try writer.print("No spaces yet. Create one with: todo space add <name>\n", .{});
        return;
    }
    for (spaces) |s| {
        try writer.print("  {s}\n", .{s});
    }
}

pub fn cmdRemove(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    _ = allocator;
    if (args.len < 1) return error.MissingArgument;
    const name = args[0];
    try space_store.remove(root_dir, name);
    try writer.print("Space '{s}' removed.\n", .{name});
}
