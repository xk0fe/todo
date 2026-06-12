/// Shared types for the extension protocol.
const std = @import("std");
const model = @import("../model.zig");

/// A task received from an extension's import, normalised to local model fields.
pub const RemoteTask = struct {
    external_id: []const u8,
    title:       []const u8,
    description: []const u8,
    status:      model.Status,
    priority:    model.Priority,
    due:         []const u8,
    url:         []const u8,
};

/// Free all heap strings in a RemoteTask.
pub fn deinitRemoteTask(t: RemoteTask, allocator: std.mem.Allocator) void {
    allocator.free(t.external_id);
    allocator.free(t.title);
    allocator.free(t.description);
    allocator.free(t.due);
    allocator.free(t.url);
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "RemoteTask can be created and deinited without leaks" {
    const allocator = std.testing.allocator;
    const task = RemoteTask{
        .external_id = try allocator.dupe(u8, "abc123"),
        .title       = try allocator.dupe(u8, "Test task"),
        .description = try allocator.dupe(u8, "Some description"),
        .status      = .todo,
        .priority    = .medium,
        .due         = try allocator.dupe(u8, "2026-06-01"),
        .url         = try allocator.dupe(u8, "https://example.com/issue/1"),
    };
    deinitRemoteTask(task, allocator);
}
