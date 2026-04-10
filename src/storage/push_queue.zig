/// Push queue — append-only JSON-lines file that buffers outbound changes.
/// Each line is a JSON object. Flushed by the sync engine when syncing.
const std = @import("std");
const json_util = @import("../integrations/json_util.zig");

const QUEUE_FILE = ".push_queue.jsonl";

pub const PushEntry = struct {
    space:       []const u8,
    project:     []const u8,
    external_id: []const u8,
    source:      []const u8, // "linear" | "github"
    owner:       []const u8, // github owner login; "" for linear
    repo:        []const u8, // github repo name;  "" for linear
    new_status:  []const u8, // "todo"|"in_progress"|"in_review"|"done" or "" = no change
    new_title:   []const u8, // "" = no change

    pub fn deinit(self: PushEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.space);
        allocator.free(self.project);
        allocator.free(self.external_id);
        allocator.free(self.source);
        allocator.free(self.owner);
        allocator.free(self.repo);
        allocator.free(self.new_status);
        allocator.free(self.new_title);
    }
};

/// Append one entry to the queue (creates the file if absent).
pub fn append(root_dir: std.fs.Dir, allocator: std.mem.Allocator, entry: PushEntry) !void {
    _ = allocator;

    const file = blk: {
        if (root_dir.openFile(QUEUE_FILE, .{ .mode = .read_write })) |f| {
            break :blk f;
        } else |err| switch (err) {
            error.FileNotFound => break :blk try root_dir.createFile(QUEUE_FILE, .{ .read = true }),
            else => return err,
        }
    };
    defer file.close();
    try file.seekFromEnd(0);

    // Escape a string field for JSON
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try w.print(
        "{{\"space\":\"{s}\",\"project\":\"{s}\",\"external_id\":\"{s}\",\"source\":\"{s}\",\"owner\":\"{s}\",\"repo\":\"{s}\",\"new_status\":\"{s}\",\"new_title\":\"{s}\"}}\n",
        .{
            entry.space,
            entry.project,
            entry.external_id,
            entry.source,
            entry.owner,
            entry.repo,
            entry.new_status,
            entry.new_title,
        },
    );
    try file.writeAll(fbs.getWritten());
}

/// Load all queued entries.  Caller must call entry.deinit(allocator) on each.
pub fn loadAll(allocator: std.mem.Allocator, root_dir: std.fs.Dir) ![]PushEntry {
    const content = root_dir.readFileAlloc(allocator, QUEUE_FILE, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(content);

    var list = std.ArrayListUnmanaged(PushEntry){};
    errdefer {
        for (list.items) |e| e.deinit(allocator);
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{
            .allocate = .alloc_always,
        }) catch continue;
        defer parsed.deinit();

        const v = parsed.value;
        const entry = PushEntry{
            .space       = try allocator.dupe(u8, json_util.getString(v, "space")),
            .project     = try allocator.dupe(u8, json_util.getString(v, "project")),
            .external_id = try allocator.dupe(u8, json_util.getString(v, "external_id")),
            .source      = try allocator.dupe(u8, json_util.getString(v, "source")),
            .owner       = try allocator.dupe(u8, json_util.getString(v, "owner")),
            .repo        = try allocator.dupe(u8, json_util.getString(v, "repo")),
            .new_status  = try allocator.dupe(u8, json_util.getString(v, "new_status")),
            .new_title   = try allocator.dupe(u8, json_util.getString(v, "new_title")),
        };
        try list.append(allocator, entry);
    }

    return list.toOwnedSlice(allocator);
}

/// Delete the queue file (called after a successful flush).
pub fn clear(root_dir: std.fs.Dir) void {
    root_dir.deleteFile(QUEUE_FILE) catch {};
}
