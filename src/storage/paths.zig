/// Resolves the todo root directory (~/.todo) and opens it, creating it if needed.
const std = @import("std");
const builtin = @import("builtin");

/// Returns the path to ~/.todo as an owned slice. Caller must free.
pub fn todoRootPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = switch (builtin.os.tag) {
        .windows => try std.process.getEnvVarOwned(allocator, "USERPROFILE"),
        else => try std.process.getEnvVarOwned(allocator, "HOME"),
    };
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".todo" });
}

/// Opens (and creates if needed) the ~/.todo directory.
/// Caller must close the returned Dir.
pub fn openOrCreateTodoRoot(allocator: std.mem.Allocator) !std.fs.Dir {
    const root_path = try todoRootPath(allocator);
    defer allocator.free(root_path);
    return std.fs.cwd().makeOpenPath(root_path, .{ .iterate = true });
}

// --- tests ---

test "todoRootPath ends with /.todo" {
    const path = try todoRootPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/.todo") or
        std.mem.endsWith(u8, path, "\\.todo"));
}

test "openOrCreateTodoRoot creates and returns a valid Dir" {
    // Use a temp dir so we don't touch the real ~/.todo
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Just verify makeOpenPath works on a known subdir
    var sub = try tmp.dir.makeOpenPath("test_root", .{ .iterate = true });
    defer sub.close();
    // Should be able to stat it
    const stat = try sub.stat();
    try std.testing.expectEqual(std.fs.File.Kind.directory, stat.kind);
}
