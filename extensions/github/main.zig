/// GitHub Issues extension for todo.
/// Speaks the todo extension protocol: manifest / import / export / setup.
/// Setup runs the OAuth device flow interactively (stderr is the user's terminal).
const std = @import("std");
const shared = @import("shared");
const proto = shared.proto;
const client = @import("client.zig");
const oauth = @import("oauth.zig");

comptime {
    _ = client; // pull client tests into `zig build test`
    _ = oauth;
}

const manifest_json =
    \\{"name":"github","version":"1.0.0",
    \\ "description":"Import and export GitHub issues assigned to you",
    \\ "capabilities":["import","export","setup"],
    \\ "config":[
    \\   {"key":"token","label":"GitHub token","secret":true},
    \\   {"key":"client_id","label":"OAuth app client ID (for setup)"},
    \\   {"key":"owner","label":"Repository owner"},
    \\   {"key":"repo","label":"Repository name"}
    \\ ]}
    \\
;

pub fn main() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = std.process.argsAlloc(allocator) catch std.process.exit(1);
    defer std.process.argsFree(allocator, args);
    const command = if (args.len > 1) args[1] else "";

    if (std.mem.eql(u8, command, "manifest")) {
        stdout.writeAll(manifest_json) catch {};
        return;
    }
    if (std.mem.eql(u8, command, "import")) {
        cmdImport(allocator, stdout) catch |err| fail(stdout, err);
        return;
    }
    if (std.mem.eql(u8, command, "export")) {
        cmdExport(allocator, stdout) catch |err| fail(stdout, err);
        return;
    }
    if (std.mem.eql(u8, command, "setup")) {
        cmdSetup(allocator, stdout) catch |err| fail(stdout, err);
        return;
    }

    proto.writeError(stdout, "unknown command (expected manifest|import|export|setup)") catch {};
    stdout.flush() catch {};
    std.process.exit(1);
}

fn fail(stdout: *std.io.Writer, err: anyerror) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "github request failed: {s}", .{@errorName(err)}) catch "github request failed";
    proto.writeError(stdout, msg) catch {};
    stdout.flush() catch {};
    std.process.exit(1);
}

fn die(stdout: *std.io.Writer, msg: []const u8) noreturn {
    proto.writeError(stdout, msg) catch {};
    stdout.flush() catch {};
    std.process.exit(1);
}

fn cmdImport(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    const input = try proto.readStdin(allocator);
    defer allocator.free(input);
    const req = try proto.parseRequest(allocator, input);
    defer req.deinit();

    const token = req.configGet("token");
    if (token.len == 0) die(stdout, "token not configured — run: todo ext setup github (or: todo ext config github token=<token>)");
    const owner = req.configGet("owner");
    const repo = req.configGet("repo");
    if (owner.len == 0 or repo.len == 0)
        die(stdout, "owner/repo not configured — run: todo ext link <space> <project> github owner=<o> repo=<r>");

    const tasks = try client.fetchIssues(allocator, token, owner, repo);
    defer {
        for (tasks) |t| shared.task.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try proto.writeTasksResponse(stdout, tasks);
}

fn cmdExport(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    const input = try proto.readStdin(allocator);
    defer allocator.free(input);
    const req = try proto.parseRequest(allocator, input);
    defer req.deinit();

    const token = req.configGet("token");
    if (token.len == 0) die(stdout, "token not configured — run: todo ext setup github");
    const owner = req.configGet("owner");
    const repo = req.configGet("repo");
    if (owner.len == 0 or repo.len == 0)
        die(stdout, "owner/repo not configured — run: todo ext link <space> <project> github owner=<o> repo=<r>");

    var exported: u32 = 0;
    var skipped: u32 = 0;
    for (req.tasks()) |t| {
        const external_id = shared.json_util.getString(t, "external_id");
        const source = shared.json_util.getString(t, "source");
        if (external_id.len == 0 or !std.mem.eql(u8, source, "github")) {
            skipped += 1;
            continue;
        }

        const status = shared.json_util.getString(t, "status");
        const state: []const u8 = if (std.mem.eql(u8, status, "done")) "closed" else "open";
        const title = shared.json_util.getString(t, "title");
        client.pushUpdate(allocator, token, owner, repo, external_id, state, title) catch {
            skipped += 1;
            continue;
        };
        exported += 1;
    }
    try proto.writeExportResponse(stdout, exported, skipped);
}

/// Interactive OAuth device flow. Progress goes to stderr (the terminal);
/// the resulting config JSON goes to stdout for the app to save.
fn cmdSetup(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // Existing config arrives via TODO_EXT_CONFIG.
    const cfg_json = std.process.getEnvVarOwned(allocator, "TODO_EXT_CONFIG") catch
        try allocator.dupe(u8, "{}");
    defer allocator.free(cfg_json);
    const parsed = try shared.json_util.parseObject(allocator, cfg_json);
    defer parsed.deinit();
    const client_id = shared.json_util.getString(parsed.value, "client_id");
    if (client_id.len == 0)
        die(stdout, "client_id not configured — run: todo ext config github client_id=<oauth app id>");

    const dc = try oauth.requestDeviceCode(allocator, client_id);
    defer dc.deinit(allocator);

    try stderr.print("Open {s} and enter code: {s}\nWaiting for authorisation", .{ dc.verification_uri, dc.user_code });
    try stderr.flush();

    var interval: u64 = @intCast(@max(5, dc.interval));
    while (true) {
        std.Thread.sleep(interval * std.time.ns_per_s);
        const poll = oauth.pollToken(allocator, client_id, dc.device_code) catch continue;
        switch (poll) {
            .token => |t| {
                defer allocator.free(t);
                try stderr.print(" done.\n", .{});
                try stderr.flush();
                try proto.writeSetupResponse(stdout, &.{.{ .key = "token", .value = t }});
                return;
            },
            .pending => {
                try stderr.print(".", .{});
                try stderr.flush();
            },
            .slow_down => interval += 5,
            .expired => die(stdout, "device code expired — try again"),
            .denied => die(stdout, "authorisation denied"),
            .err => |msg| {
                defer allocator.free(msg);
                var buf: [256]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "oauth failed: {s}", .{msg}) catch "oauth failed";
                die(stdout, m);
            },
        }
    }
}
