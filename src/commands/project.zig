const std = @import("std");
const project_store = @import("../storage/project_store.zig");

pub fn cmdAdd(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len < 2) return error.MissingArgument;
    const space = args[0];
    const name = args[1];
    try project_store.add(allocator, root_dir, space, name);
    try writer.print("Project '{s}' created in space '{s}'.\n", .{ name, space });
}

pub fn cmdList(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return error.MissingArgument;
    const space = args[0];
    const projects = try project_store.list(allocator, root_dir, space);
    defer {
        for (projects) |p| allocator.free(p);
        allocator.free(projects);
    }
    if (projects.len == 0) {
        try writer.print("No projects in '{s}'. Create one with: todo project add {s} <name>\n", .{ space, space });
        return;
    }
    for (projects) |p| {
        try writer.print("  {s}\n", .{p});
    }
}

pub fn cmdRemove(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    _ = allocator;
    if (args.len < 2) return error.MissingArgument;
    const space = args[0];
    const name = args[1];
    try project_store.remove(root_dir, space, name);
    try writer.print("Project '{s}' removed.\n", .{name});
}
