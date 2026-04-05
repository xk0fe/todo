const std = @import("std");
const model = @import("../model.zig");
const task_store = @import("../storage/task_store.zig");

fn getFlag(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

pub fn cmdAdd(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    // todo task add <space> <project> <title> [--priority X] [--due DATE] [--description TEXT]
    if (args.len < 3) return error.MissingArgument;
    const space   = args[0];
    const project = args[1];
    const title   = args[2];

    const priority = if (getFlag(args, "--priority")) |p|
        try model.Priority.fromString(p)
    else
        model.Priority.medium;

    const due         = getFlag(args, "--due") orelse "";
    const description = getFlag(args, "--description") orelse getFlag(args, "--notes") orelse "";

    const id = try task_store.add(allocator, root_dir, space, project, .{
        .title       = title,
        .priority    = priority,
        .due         = due,
        .description = description,
    });
    try writer.print("Task #{d} created: {s}\n", .{ id, title });
}

pub fn cmdList(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    // todo task list <space> <project> [--status todo|in-progress|in-review|done|all]
    if (args.len < 2) return error.MissingArgument;
    const space   = args[0];
    const project = args[1];

    const filter: task_store.TaskFilter = if (getFlag(args, "--status")) |s| blk: {
        if (std.mem.eql(u8, s, "all"))         break :blk .all;
        if (std.mem.eql(u8, s, "done"))        break :blk .done;
        if (std.mem.eql(u8, s, "in-progress")) break :blk .in_progress;
        if (std.mem.eql(u8, s, "in-review"))   break :blk .in_review;
        if (std.mem.eql(u8, s, "todo"))        break :blk .todo;
        return error.InvalidArgument;
    } else .active;

    const tasks = try task_store.list(allocator, root_dir, space, project, filter);
    defer {
        for (tasks) |t| t.deinit(allocator);
        allocator.free(tasks);
    }

    if (tasks.len == 0) {
        try writer.print("No tasks found.\n", .{});
        return;
    }

    for (tasks) |t| {
        const status_icon: []const u8 = switch (t.status) {
            .todo        => "[ ]",
            .in_progress => "[~]",
            .in_review   => "[?]",
            .done        => "[x]",
        };
        const due_str = if (t.due.len > 0) t.due else "-";
        try writer.print("  {s} #{d:0>4}  [{s}]  {s}  due: {s}\n", .{
            status_icon, t.id, t.priority.toString(), t.title, due_str,
        });
        if (t.description.len > 0) {
            try writer.print("          {s}\n", .{t.description});
        }
        for (t.subtasks, 0..) |st, i| {
            const check: []const u8 = if (st.done) "[x]" else "[ ]";
            try writer.print("          {s} {d}. {s}\n", .{ check, i + 1, st.title });
        }
    }
}

pub fn cmdDone(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len < 3) return error.MissingArgument;
    const space   = args[0];
    const project = args[1];
    const id = std.fmt.parseInt(u32, args[2], 10) catch return error.InvalidArgument;
    try task_store.markDone(allocator, root_dir, space, project, id);
    try writer.print("Task #{d} marked as done.\n", .{id});
}

pub fn cmdRemove(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    _ = allocator;
    if (args.len < 3) return error.MissingArgument;
    const space   = args[0];
    const project = args[1];
    const id = std.fmt.parseInt(u32, args[2], 10) catch return error.InvalidArgument;
    try task_store.remove(root_dir, space, project, id);
    try writer.print("Task #{d} removed.\n", .{id});
}

pub fn cmdEdit(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    // todo task edit <space> <project> <id> [--title X] [--priority X] [--status X] [--due X] [--description X]
    if (args.len < 3) return error.MissingArgument;
    const space   = args[0];
    const project = args[1];
    const id = std.fmt.parseInt(u32, args[2], 10) catch return error.InvalidArgument;

    const opts = task_store.UpdateOptions{
        .title       = getFlag(args, "--title"),
        .status      = if (getFlag(args, "--status"))   |s| try model.Status.fromString(s)   else null,
        .priority    = if (getFlag(args, "--priority")) |p| try model.Priority.fromString(p) else null,
        .due         = getFlag(args, "--due"),
        .description = getFlag(args, "--description") orelse getFlag(args, "--notes"),
    };

    try task_store.update(allocator, root_dir, space, project, id, opts);
    try writer.print("Task #{d} updated.\n", .{id});
}
