const std = @import("std");

pub const Status = enum {
    todo,
    in_progress,
    in_review,
    done,

    pub fn fromString(s: []const u8) !Status {
        if (std.mem.eql(u8, s, "todo"))        return .todo;
        if (std.mem.eql(u8, s, "in-progress")) return .in_progress;
        if (std.mem.eql(u8, s, "in-review"))   return .in_review;
        if (std.mem.eql(u8, s, "done"))        return .done;
        return error.InvalidStatus;
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .todo        => "todo",
            .in_progress => "in-progress",
            .in_review   => "in-review",
            .done        => "done",
        };
    }

    pub fn next(self: Status) ?Status {
        return switch (self) {
            .todo        => .in_progress,
            .in_progress => .in_review,
            .in_review   => .done,
            .done        => null,
        };
    }

    pub fn prev(self: Status) ?Status {
        return switch (self) {
            .todo        => null,
            .in_progress => .todo,
            .in_review   => .in_progress,
            .done        => .in_review,
        };
    }

    /// Completion weight for progress calculation (0–100).
    pub fn weight(self: Status) u32 {
        return switch (self) {
            .todo        => 0,
            .in_progress => 35,
            .in_review   => 70,
            .done        => 100,
        };
    }
};

pub const Priority = enum {
    low,
    medium,
    high,
    urgent,

    pub fn fromString(s: []const u8) !Priority {
        if (std.mem.eql(u8, s, "low"))    return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "mid"))    return .medium;
        if (std.mem.eql(u8, s, "high"))   return .high;
        if (std.mem.eql(u8, s, "urgent")) return .urgent;
        return error.InvalidPriority;
    }

    pub fn toString(self: Priority) []const u8 {
        return switch (self) {
            .low    => "low",
            .medium => "medium",
            .high   => "high",
            .urgent => "urgent",
        };
    }

    /// Next = move right toward urgent (higher priority).
    pub fn next(self: Priority) ?Priority {
        return switch (self) {
            .low    => .medium,
            .medium => .high,
            .high   => .urgent,
            .urgent => null,
        };
    }

    /// Prev = move left toward low (lower priority).
    pub fn prev(self: Priority) ?Priority {
        return switch (self) {
            .low    => null,
            .medium => .low,
            .high   => .medium,
            .urgent => .high,
        };
    }

    /// Weight for progress calculation: higher priority tasks count more.
    pub fn progressWeight(self: Priority) u32 {
        return switch (self) {
            .low    => 1,
            .medium => 2,
            .high   => 3,
            .urgent => 4,
        };
    }
};

pub const ItemColor = enum {
    default, red, green, blue, orange, purple, cyan, yellow,

    pub fn fromString(s: []const u8) ItemColor {
        if (std.mem.eql(u8, s, "red"))    return .red;
        if (std.mem.eql(u8, s, "green"))  return .green;
        if (std.mem.eql(u8, s, "blue"))   return .blue;
        if (std.mem.eql(u8, s, "orange")) return .orange;
        if (std.mem.eql(u8, s, "purple")) return .purple;
        if (std.mem.eql(u8, s, "cyan"))   return .cyan;
        if (std.mem.eql(u8, s, "yellow")) return .yellow;
        return .default;
    }

    pub fn toString(self: ItemColor) []const u8 {
        return switch (self) {
            .default => "default",
            .red     => "red",    .green  => "green",  .blue   => "blue",
            .orange  => "orange", .purple => "purple",  .cyan   => "cyan",
            .yellow  => "yellow",
        };
    }

    pub fn next(self: ItemColor) ItemColor {
        return switch (self) {
            .default => .red,  .red    => .green,  .green  => .blue,
            .blue    => .orange, .orange => .purple, .purple => .cyan,
            .cyan    => .yellow, .yellow => .default,
        };
    }
};

pub const SubTask = struct {
    title: []const u8,
    done:  bool,

    pub fn deinit(self: SubTask, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
    }
};

pub const Task = struct {
    id:          u32,
    title:       []const u8,
    status:      Status,
    priority:    Priority,
    description: []const u8,
    created:     []const u8,
    due:         []const u8,
    subtasks:    []SubTask,

    pub fn deinit(self: Task, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.created);
        allocator.free(self.due);
        for (self.subtasks) |st| st.deinit(allocator);
        allocator.free(self.subtasks);
    }
};

pub const Project = struct {
    name:        []const u8,
    description: []const u8,

    pub fn deinit(self: Project, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

pub const Space = struct {
    name: []const u8,

    pub fn deinit(self: Space, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

test "Status.fromString valid values" {
    try std.testing.expectEqual(Status.todo,        try Status.fromString("todo"));
    try std.testing.expectEqual(Status.in_progress, try Status.fromString("in-progress"));
    try std.testing.expectEqual(Status.in_review,   try Status.fromString("in-review"));
    try std.testing.expectEqual(Status.done,        try Status.fromString("done"));
}

test "Status.fromString invalid value" {
    try std.testing.expectError(error.InvalidStatus, Status.fromString("garbage"));
}

test "Status.toString" {
    try std.testing.expectEqualStrings("todo",        Status.todo.toString());
    try std.testing.expectEqualStrings("in-progress", Status.in_progress.toString());
    try std.testing.expectEqualStrings("in-review",   Status.in_review.toString());
    try std.testing.expectEqualStrings("done",        Status.done.toString());
}

test "Status roundtrip" {
    const cases = [_][]const u8{ "todo", "in-progress", "in-review", "done" };
    for (cases) |c| {
        const s = try Status.fromString(c);
        try std.testing.expectEqualStrings(c, s.toString());
    }
}

test "Status.weight" {
    try std.testing.expectEqual(@as(u32,   0), Status.todo.weight());
    try std.testing.expectEqual(@as(u32,  35), Status.in_progress.weight());
    try std.testing.expectEqual(@as(u32,  70), Status.in_review.weight());
    try std.testing.expectEqual(@as(u32, 100), Status.done.weight());
}

test "Priority.fromString valid values" {
    try std.testing.expectEqual(Priority.low,    try Priority.fromString("low"));
    try std.testing.expectEqual(Priority.medium, try Priority.fromString("medium"));
    try std.testing.expectEqual(Priority.medium, try Priority.fromString("mid"));
    try std.testing.expectEqual(Priority.high,   try Priority.fromString("high"));
    try std.testing.expectEqual(Priority.urgent, try Priority.fromString("urgent"));
}

test "Priority.fromString invalid value" {
    try std.testing.expectError(error.InvalidPriority, Priority.fromString("banana"));
}

test "Priority roundtrip" {
    const cases = [_][]const u8{ "low", "medium", "high", "urgent" };
    for (cases) |c| {
        const p = try Priority.fromString(c);
        try std.testing.expectEqualStrings(c, p.toString());
    }
}
