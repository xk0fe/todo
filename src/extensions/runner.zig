/// Spawns extension executables and exchanges protocol JSON over stdio.
const std = @import("std");

const MAX_OUTPUT_BYTES = 16 * 1024 * 1024;

pub const Output = struct {
    stdout:    []u8,
    stderr:    []u8,
    exit_code: u8, // 255 when the process did not exit normally

    pub fn deinit(self: Output, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn ok(self: Output) bool {
        return self.exit_code == 0;
    }
};

/// Run `<ext_path> <command>`, writing `stdin_data` to its stdin (if any)
/// and collecting stdout/stderr. Caller must call output.deinit().
pub fn run(
    allocator: std.mem.Allocator,
    ext_path: []const u8,
    command: []const u8,
    stdin_data: ?[]const u8,
) !Output {
    var child = std.process.Child.init(&.{ ext_path, command }, allocator);
    child.stdin_behavior = if (stdin_data != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    if (stdin_data) |data| {
        // Requests are small; a single blocking write is fine.
        child.stdin.?.writeAll(data) catch {};
        child.stdin.?.close();
        child.stdin = null;
    }

    var stdout = std.ArrayList(u8).empty;
    defer stdout.deinit(allocator);
    var stderr = std.ArrayList(u8).empty;
    defer stderr.deinit(allocator);
    try child.collectOutput(allocator, &stdout, &stderr, MAX_OUTPUT_BYTES);

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };

    return Output{
        .stdout    = try stdout.toOwnedSlice(allocator),
        .stderr    = try stderr.toOwnedSlice(allocator),
        .exit_code = code,
    };
}

/// Run `<ext_path> setup` interactively: the user's terminal stays attached
/// to stdin/stderr so the extension can talk to them; stdout (the config
/// JSON) is captured. Existing config is passed via TODO_EXT_CONFIG.
pub fn runSetup(
    allocator: std.mem.Allocator,
    ext_path: []const u8,
    config_json: []const u8,
) !Output {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("TODO_EXT_CONFIG", config_json);

    var child = std.process.Child.init(&.{ ext_path, "setup" }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.env_map = &env;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    const stdout = try child.stdout.?.readToEndAlloc(allocator, MAX_OUTPUT_BYTES);
    errdefer allocator.free(stdout);

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };

    return Output{
        .stdout    = stdout,
        .stderr    = try allocator.dupe(u8, ""),
        .exit_code = code,
    };
}

// ── tests ─────────────────────────────────────────────────────────────────────

const builtin = @import("builtin");

test "run: executes a script and round-trips stdin to stdout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = "#!/bin/sh\necho \"arg:$1\"\ncat\n";
    {
        const f = try tmp.dir.createFile("echo-ext", .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll(script);
    }
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "echo-ext");
    defer std.testing.allocator.free(path);

    const out = try run(std.testing.allocator, path, "import", "{\"x\":1}");
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(out.ok());
    try std.testing.expectEqualStrings("arg:import\n{\"x\":1}", out.stdout);
}

test "run: nonzero exit code is reported" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("fail-ext", .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll("#!/bin/sh\necho oops >&2\nexit 3\n");
    }
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "fail-ext");
    defer std.testing.allocator.free(path);

    const out = try run(std.testing.allocator, path, "manifest", null);
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(!out.ok());
    try std.testing.expectEqual(@as(u8, 3), out.exit_code);
    try std.testing.expectEqualStrings("oops\n", out.stderr);
}
