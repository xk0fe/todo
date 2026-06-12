/// Linear extension for todo.
/// Speaks the todo extension protocol: manifest / import / export.
const std = @import("std");
const shared = @import("shared");
const proto = shared.proto;
const client = @import("client.zig");

comptime {
    _ = client; // pull client tests into `zig build test`
}

const manifest_json =
    \\{"name":"linear","version":"1.0.0",
    \\ "description":"Import and export Linear issues assigned to you",
    \\ "capabilities":["import","export"],
    \\ "config":[
    \\   {"key":"api_key","label":"Linear API key","secret":true},
    \\   {"key":"team_id","label":"Team ID (enables status export)"}
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

    proto.writeError(stdout, "unknown command (expected manifest|import|export)") catch {};
    stdout.flush() catch {};
    std.process.exit(1);
}

fn fail(stdout: *std.io.Writer, err: anyerror) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "linear request failed: {s}", .{@errorName(err)}) catch "linear request failed";
    proto.writeError(stdout, msg) catch {};
    stdout.flush() catch {};
    std.process.exit(1);
}

fn requireKey(stdout: *std.io.Writer, req: proto.Request) ?[]const u8 {
    const api_key = req.configGet("api_key");
    if (api_key.len == 0) {
        proto.writeError(stdout, "api_key not configured — run: todo ext config linear api_key=<key>") catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    }
    return api_key;
}

fn cmdImport(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    const input = try proto.readStdin(allocator);
    defer allocator.free(input);
    const req = try proto.parseRequest(allocator, input);
    defer req.deinit();
    const api_key = requireKey(stdout, req).?;

    const tasks = try client.fetchIssues(allocator, api_key, req.configGet("team_id"), req.configGet("project_id"));
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
    const api_key = requireKey(stdout, req).?;
    const team_id = req.configGet("team_id");

    var exported: u32 = 0;
    var skipped: u32 = 0;
    for (req.tasks()) |t| {
        const external_id = shared.json_util.getString(t, "external_id");
        const source = shared.json_util.getString(t, "source");
        if (external_id.len == 0 or !std.mem.eql(u8, source, "linear")) {
            skipped += 1;
            continue;
        }

        const title = shared.json_util.getString(t, "title");
        client.pushUpdate(allocator, api_key, external_id, title) catch {
            skipped += 1;
            continue;
        };
        if (shared.task.Status.fromString(shared.json_util.getString(t, "status"))) |status| {
            client.pushStatusUpdate(allocator, api_key, team_id, external_id, status) catch {};
        } else |_| {}
        exported += 1;
    }
    try proto.writeExportResponse(stdout, exported, skipped);
}
