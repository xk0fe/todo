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
    _ = @import("storage/ext_config.zig");
    _ = @import("extensions/types.zig");
    _ = @import("extensions/protocol.zig");
    _ = @import("extensions/runner.zig");
    _ = @import("extensions/registry.zig");
    _ = @import("extensions/engine.zig");
    _ = @import("commands/ext.zig");
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
            error.ExtensionNotFound => stderr.print("error: extension not found. Run `todo ext list` to see installed extensions.\n", .{}) catch {},
            // These already printed a detailed message to stdout.
            error.ImportFailed, error.ExportFailed, error.SetupFailed => {},
            else => stderr.print("error: {s}\n", .{@errorName(err)}) catch {},
        }
        // process.exit skips defers — flush explicitly so buffered output is not lost
        stdout.flush() catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
}
