const std = @import("std");
const paths = @import("storage/paths.zig");
const args_util = @import("commands/args.zig");
const spec = @import("commands/spec.zig");
const cmd_space = @import("commands/space.zig");
const cmd_project = @import("commands/project.zig");
const cmd_task = @import("commands/task.zig");
const cmd_ext = @import("commands/ext.zig");

const Handler = *const fn (std.mem.Allocator, std.fs.Dir, *std.io.Writer, []const []const u8) anyerror!void;

const Route = struct {
    names: []const []const u8,
    handler: Handler,
};

const CommandGroup = struct {
    name: []const u8,
    routes: []const Route,
};

const space_routes = [_]Route{
    .{ .names = &.{spec.Subcommand.add}, .handler = cmd_space.cmdAdd },
    .{ .names = &.{ spec.Subcommand.list, spec.Subcommand.ls }, .handler = cmd_space.cmdList },
    .{ .names = &.{ spec.Subcommand.rm, spec.Subcommand.remove }, .handler = cmd_space.cmdRemove },
};

const project_routes = [_]Route{
    .{ .names = &.{spec.Subcommand.add}, .handler = cmd_project.cmdAdd },
    .{ .names = &.{ spec.Subcommand.list, spec.Subcommand.ls }, .handler = cmd_project.cmdList },
    .{ .names = &.{ spec.Subcommand.rm, spec.Subcommand.remove }, .handler = cmd_project.cmdRemove },
};

const task_routes = [_]Route{
    .{ .names = &.{spec.Subcommand.add}, .handler = cmd_task.cmdAdd },
    .{ .names = &.{ spec.Subcommand.list, spec.Subcommand.ls }, .handler = cmd_task.cmdList },
    .{ .names = &.{spec.Subcommand.done}, .handler = cmd_task.cmdDone },
    .{ .names = &.{ spec.Subcommand.rm, spec.Subcommand.remove }, .handler = cmd_task.cmdRemove },
    .{ .names = &.{spec.Subcommand.edit}, .handler = cmd_task.cmdEdit },
};

const ext_routes = [_]Route{
    .{ .names = &.{ spec.Subcommand.list, spec.Subcommand.ls }, .handler = cmd_ext.cmdList },
    .{ .names = &.{spec.Subcommand.config}, .handler = cmd_ext.cmdConfig },
    .{ .names = &.{spec.Subcommand.setup}, .handler = cmd_ext.cmdSetup },
    .{ .names = &.{spec.Subcommand.link}, .handler = cmd_ext.cmdLink },
    .{ .names = &.{spec.Subcommand.unlink}, .handler = cmd_ext.cmdUnlink },
    .{ .names = &.{spec.Subcommand.import}, .handler = cmd_ext.cmdImport },
    .{ .names = &.{spec.Subcommand.@"export"}, .handler = cmd_ext.cmdExport },
};

const command_groups = [_]CommandGroup{
    .{ .name = spec.Command.space, .routes = &space_routes },
    .{ .name = spec.Command.project, .routes = &project_routes },
    .{ .name = spec.Command.task, .routes = &task_routes },
    .{ .name = spec.Command.ext, .routes = &ext_routes },
};

fn isHelp(arg: []const u8) bool {
    return args_util.matchesAny(arg, &.{ spec.Command.help, spec.HelpFlag.long, spec.HelpFlag.short });
}

test "isHelp accepts help aliases" {
    try std.testing.expect(isHelp(spec.Command.help));
    try std.testing.expect(isHelp(spec.HelpFlag.long));
    try std.testing.expect(isHelp(spec.HelpFlag.short));
    try std.testing.expect(!isHelp(spec.Command.task));
}

fn dispatch(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    writer: *std.io.Writer,
    cmd: []const u8,
    sub: []const u8,
    rest: []const []const u8,
) !void {
    for (command_groups) |group| {
        if (!args_util.eql(cmd, group.name)) continue;
        for (group.routes) |route| {
            if (args_util.matchesAny(sub, route.names)) {
                return route.handler(allocator, root_dir, writer, rest);
            }
        }
        return error.UnknownCommand;
    }
    return error.UnknownCommand;
}

pub fn run(allocator: std.mem.Allocator, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len == 0) {
        try writer.print("{s}", .{spec.usage});
        return;
    }

    const cmd = args[0];

    if (isHelp(cmd)) {
        try writer.print("{s}", .{spec.usage});
        return;
    }

    var root_dir = try paths.openOrCreateTodoRoot(allocator);
    defer root_dir.close();

    const sub = if (args.len > 1) args[1] else "";
    const rest = if (args.len > 2) args[2..] else &[_][]const u8{};

    return dispatch(allocator, root_dir, writer, cmd, sub, rest);
}
