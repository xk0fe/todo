/// Trello extension for todo.
/// Speaks the todo extension protocol: manifest / import.
const std = @import("std");
const shared = @import("shared");
const proto = shared.proto;
const client = @import("client.zig");

comptime {
    _ = client; // pull client tests into `zig build test`
}

const manifest_json =
    \\{"name":"trello","version":"1.0.0",
    \\ "description":"Import cards from a Trello board (status from list mapping)",
    \\ "capabilities":["import"],
    \\ "config":[
    \\   {"key":"api_key","label":"Trello API key","secret":true},
    \\   {"key":"token","label":"Trello token","secret":true},
    \\   {"key":"board_id","label":"Board ID"},
    \\   {"key":"list_todo","label":"List ID: todo"},
    \\   {"key":"list_in_progress","label":"List ID: in-progress"},
    \\   {"key":"list_in_review","label":"List ID: in-review"},
    \\   {"key":"list_done","label":"List ID: done"}
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
        proto.writeError(stdout, "trello extension does not support export yet") catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    }

    proto.writeError(stdout, "unknown command (expected manifest|import)") catch {};
    stdout.flush() catch {};
    std.process.exit(1);
}

fn fail(stdout: *std.io.Writer, err: anyerror) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "trello request failed: {s}", .{@errorName(err)}) catch "trello request failed";
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

    const api_key = req.configGet("api_key");
    const token = req.configGet("token");
    if (api_key.len == 0 or token.len == 0)
        die(stdout, "api_key/token not configured — run: todo ext config trello api_key=<k> token=<t>");
    const board_id = req.configGet("board_id");
    if (board_id.len == 0)
        die(stdout, "board_id not configured — run: todo ext link <space> <project> trello board_id=<id>");

    const list_map = client.TrelloListMap{
        .todo        = req.configGet("list_todo"),
        .in_progress = req.configGet("list_in_progress"),
        .in_review   = req.configGet("list_in_review"),
        .done        = req.configGet("list_done"),
    };

    const tasks = try client.fetchCards(allocator, api_key, token, board_id, list_map);
    defer {
        for (tasks) |t| shared.task.deinitRemoteTask(t, allocator);
        allocator.free(tasks);
    }
    try proto.writeTasksResponse(stdout, tasks);
}
