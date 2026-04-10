const std = @import("std");
const paths = @import("storage/paths.zig");
const cmd_space = @import("commands/space.zig");
const cmd_project = @import("commands/project.zig");
const cmd_task = @import("commands/task.zig");
const cmd_sync = @import("commands/sync.zig");

const usage =
    \\Usage: todo <command> [args]
    \\
    \\Space commands:
    \\  todo space add <name>
    \\  todo space list
    \\  todo space rm <name>
    \\
    \\Project commands:
    \\  todo project add <space> <name>
    \\  todo project list <space>
    \\  todo project rm <space> <name>
    \\
    \\Task commands:
    \\  todo task add <space> <project> <title> [--priority high|medium|low] [--due DATE] [--notes TEXT]
    \\  todo task list <space> <project> [--status todo|in-progress|done|all]
    \\  todo task done <space> <project> <id>
    \\  todo task edit <space> <project> <id> [--title X] [--priority X] [--status X] [--due X] [--notes X]
    \\  todo task rm <space> <project> <id>
    \\
    \\Sync commands:
    \\  todo sync config  --linear-key KEY | --github-token TOKEN | --trello-key KEY --trello-token TOKEN
    \\  todo sync link    <space> <project> [--linear-team ID] [--linear-project ID]
    \\                                      [--github-owner O --github-repo R]
    \\                                      [--trello-board ID --trello-list-todo L ...]
    \\  todo sync linear  <space> <project>
    \\  todo sync github  <space> <project>
    \\  todo sync trello  <space> <project>
    \\
;

pub fn run(allocator: std.mem.Allocator, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len == 0) {
        try writer.print("{s}", .{usage});
        return;
    }

    const cmd = args[0];

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try writer.print("{s}", .{usage});
        return;
    }

    var root_dir = try paths.openOrCreateTodoRoot(allocator);
    defer root_dir.close();

    const sub = if (args.len > 1) args[1] else "";
    const rest = if (args.len > 2) args[2..] else &[_][]const u8{};

    if (std.mem.eql(u8, cmd, "space")) {
        if (std.mem.eql(u8, sub, "add")) return cmd_space.cmdAdd(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "ls")) return cmd_space.cmdList(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "remove")) return cmd_space.cmdRemove(allocator, root_dir, writer, rest);
        return error.UnknownCommand;
    }

    if (std.mem.eql(u8, cmd, "project")) {
        if (std.mem.eql(u8, sub, "add")) return cmd_project.cmdAdd(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "ls")) return cmd_project.cmdList(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "remove")) return cmd_project.cmdRemove(allocator, root_dir, writer, rest);
        return error.UnknownCommand;
    }

    if (std.mem.eql(u8, cmd, "task")) {
        if (std.mem.eql(u8, sub, "add")) return cmd_task.cmdAdd(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "ls")) return cmd_task.cmdList(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "done")) return cmd_task.cmdDone(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "remove")) return cmd_task.cmdRemove(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "edit")) return cmd_task.cmdEdit(allocator, root_dir, writer, rest);
        return error.UnknownCommand;
    }

    if (std.mem.eql(u8, cmd, "sync")) {
        if (std.mem.eql(u8, sub, "config"))  return cmd_sync.cmdConfig(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "link"))    return cmd_sync.cmdLink(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "linear"))  return cmd_sync.cmdLinear(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "github"))  return cmd_sync.cmdGitHub(allocator, root_dir, writer, rest);
        if (std.mem.eql(u8, sub, "trello"))  return cmd_sync.cmdTrello(allocator, root_dir, writer, rest);
        return error.UnknownCommand;
    }

    return error.UnknownCommand;
}
