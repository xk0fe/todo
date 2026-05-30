const std = @import("std");
const model = @import("../model.zig");
const task_store = @import("../storage/task_store.zig");
const args_util = @import("args.zig");
const spec = @import("spec.zig");

fn parseFilter(s: []const u8) !task_store.TaskFilter {
    if (args_util.eql(s, spec.task_filter_all)) return .all;
    const status = model.Status.fromString(s) catch return error.InvalidArgument;
    return switch (status) {
        .todo => .todo,
        .in_progress => .in_progress,
        .in_review => .in_review,
        .done => .done,
    };
}

test "parseFilter maps public status strings" {
    try std.testing.expectEqual(task_store.TaskFilter.all, try parseFilter("all"));
    try std.testing.expectEqual(task_store.TaskFilter.todo, try parseFilter("todo"));
    try std.testing.expectEqual(task_store.TaskFilter.in_progress, try parseFilter("in-progress"));
    try std.testing.expectEqual(task_store.TaskFilter.in_review, try parseFilter("in-review"));
    try std.testing.expectEqual(task_store.TaskFilter.done, try parseFilter("done"));
    try std.testing.expectError(error.InvalidArgument, parseFilter("blocked"));
}

pub fn cmdAdd(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    // todo task add <space> <project> <title> [--priority X] [--due DATE] [--description TEXT]
    if (args.len < 3) return error.MissingArgument;
    const space = args[0];
    const project = args[1];
    const title = args[2];

    const priority = if (args_util.getFlag(args, spec.Flag.priority)) |p|
        try model.Priority.fromString(p)
    else
        model.Priority.medium;

    const due = args_util.getFlag(args, spec.Flag.due) orelse "";
    const description = args_util.getFlag(args, spec.Flag.description) orelse args_util.getFlag(args, spec.Flag.notes) orelse "";

    const id = try task_store.add(allocator, root_dir, space, project, .{
        .title = title,
        .priority = priority,
        .due = due,
        .description = description,
    });
    try writer.print("Task #{d} created: {s}\n", .{ id, title });
}

pub fn cmdList(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    // todo task list <space> <project> [--status todo|in-progress|in-review|done|all]
    if (args.len < 2) return error.MissingArgument;
    const space = args[0];
    const project = args[1];

    const filter: task_store.TaskFilter = if (args_util.getFlag(args, spec.Flag.status)) |s|
        try parseFilter(s)
    else
        .active;

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
            .todo => "[ ]",
            .in_progress => "[~]",
            .in_review => "[?]",
            .done => "[x]",
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
    const space = args[0];
    const project = args[1];
    const id = std.fmt.parseInt(u32, args[2], 10) catch return error.InvalidArgument;
    try task_store.markDone(allocator, root_dir, space, project, id);
    try writer.print("Task #{d} marked as done.\n", .{id});
}

pub fn cmdRemove(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    _ = allocator;
    if (args.len < 3) return error.MissingArgument;
    const space = args[0];
    const project = args[1];
    const id = std.fmt.parseInt(u32, args[2], 10) catch return error.InvalidArgument;
    try task_store.remove(root_dir, space, project, id);
    try writer.print("Task #{d} removed.\n", .{id});
}

pub fn cmdEdit(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    // todo task edit <space> <project> <id> [--title X] [--priority X] [--status X] [--due X] [--description X]
    if (args.len < 3) return error.MissingArgument;
    const space = args[0];
    const project = args[1];
    const id = std.fmt.parseInt(u32, args[2], 10) catch return error.InvalidArgument;

    const opts = task_store.UpdateOptions{
        .title = args_util.getFlag(args, spec.Flag.title),
        .status = if (args_util.getFlag(args, spec.Flag.status)) |s| try model.Status.fromString(s) else null,
        .priority = if (args_util.getFlag(args, spec.Flag.priority)) |p| try model.Priority.fromString(p) else null,
        .due = args_util.getFlag(args, spec.Flag.due),
        .description = args_util.getFlag(args, spec.Flag.description) orelse args_util.getFlag(args, spec.Flag.notes),
    };

    try task_store.update(allocator, root_dir, space, project, id, opts);
    try writer.print("Task #{d} updated.\n", .{id});
}
