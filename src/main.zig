const std = @import("std");
const cli = @import("cli.zig");
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
            error.InvalidStatus => stderr.print("error: invalid status. Use: todo, in-progress, in-review, done.\n", .{}) catch {},
            error.InvalidPriority => stderr.print("error: invalid priority. Use: low, medium, high, urgent.\n", .{}) catch {},
            else => stderr.print("error: {s}\n", .{@errorName(err)}) catch {},
        }
        std.process.exit(1);
    };
}
