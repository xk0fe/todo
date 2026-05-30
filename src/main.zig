const std = @import("std");
const cli = @import("cli.zig");
const model = @import("model.zig");
const tui = @import("tui.zig");

// Pull all modules into the test binary's compilation unit so their
// inline test blocks are discovered by `zig build test`.
comptime {
    _ = @import("model.zig");
    _ = @import("storage/toml.zig");
    _ = @import("storage/paths.zig");
    _ = @import("storage/space_store.zig");
    _ = @import("storage/project_store.zig");
    _ = @import("storage/task_store.zig");
    _ = @import("storage/config_store.zig");
    _ = @import("storage/push_queue.zig");
    _ = @import("integrations/types.zig");
    _ = @import("integrations/json_util.zig");
    _ = @import("integrations/http.zig");
    _ = @import("integrations/github_oauth.zig");
    _ = @import("integrations/linear.zig");
    _ = @import("integrations/github.zig");
    _ = @import("integrations/trello.zig");
    _ = @import("integrations/sync.zig");
    _ = @import("commands/sync.zig");
}

pub fn main() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) std.debug.print("warning: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        std.debug.print("error: out of memory\n", .{});
        std.process.exit(1);
    };
    defer std.process.argsFree(allocator, args);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // No args → open the TUI
    if (args.len == 1) {
        tui.run(allocator) catch |err| {
            stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
            std.process.exit(1);
        };
        return;
    }

    cli.run(allocator, stdout, args[1..]) catch |err| {
        switch (err) {
            error.UnknownCommand => stderr.print("error: unknown command. Run `todo help` for usage.\n", .{}) catch {},
            error.MissingArgument => stderr.print("error: missing argument. Run `todo help` for usage.\n", .{}) catch {},
            error.InvalidArgument => stderr.print("error: invalid argument. Run `todo help` for usage.\n", .{}) catch {},
            error.AlreadyExists => stderr.print("error: already exists.\n", .{}) catch {},
            error.NotFound, error.SpaceNotFound => stderr.print("error: space not found.\n", .{}) catch {},
            error.ProjectNotFound => stderr.print("error: project not found.\n", .{}) catch {},
            error.TaskNotFound => stderr.print("error: task not found.\n", .{}) catch {},
            error.InvalidStatus => stderr.print("error: invalid status. Use: {s}.\n", .{model.Status.valid_values}) catch {},
            error.InvalidPriority => stderr.print("error: invalid priority. Use: {s}.\n", .{model.Priority.valid_values}) catch {},
            else => stderr.print("error: {s}\n", .{@errorName(err)}) catch {},
        }
        std.process.exit(1);
    };
}
