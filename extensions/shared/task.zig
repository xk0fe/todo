/// Task model used inside extension executables. Mirrors the todo app's
/// status/priority vocabulary; the protocol speaks these strings.
const std = @import("std");

pub const Status = enum {
    todo,
    in_progress,
    in_review,
    done,

    pub fn fromString(s: []const u8) !Status {
        if (std.mem.eql(u8, s, "todo")) return .todo;
        if (std.mem.eql(u8, s, "in-progress")) return .in_progress;
        if (std.mem.eql(u8, s, "in-review")) return .in_review;
        if (std.mem.eql(u8, s, "done")) return .done;
        return error.InvalidStatus;
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .todo => "todo",
            .in_progress => "in-progress",
            .in_review => "in-review",
            .done => "done",
        };
    }
};

pub const Priority = enum {
    low,
    medium,
    high,
    urgent,

    pub fn fromString(s: []const u8) !Priority {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "urgent")) return .urgent;
        return error.InvalidPriority;
    }

    pub fn toString(self: Priority) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
            .urgent => "urgent",
        };
    }
};

/// A task fetched from a remote service, normalised to protocol fields.
pub const RemoteTask = struct {
    external_id: []const u8,
    title:       []const u8,
    description: []const u8,
    status:      Status,
    priority:    Priority,
    due:         []const u8,
    url:         []const u8,
};

pub fn deinitRemoteTask(t: RemoteTask, allocator: std.mem.Allocator) void {
    allocator.free(t.external_id);
    allocator.free(t.title);
    allocator.free(t.description);
    allocator.free(t.due);
    allocator.free(t.url);
}

test "Status round-trips" {
    inline for (.{ "todo", "in-progress", "in-review", "done" }) |s| {
        try std.testing.expectEqualStrings(s, (try Status.fromString(s)).toString());
    }
}
