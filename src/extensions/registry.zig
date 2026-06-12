/// Extension discovery — extensions are executables in <root>/extensions/.
/// `<name>.toml` files in the same directory hold each extension's global
/// config and are skipped during discovery.
const std = @import("std");

pub const EXT_DIR = "extensions";

pub const ExtRef = struct {
    name: []u8, // filename, used as the extension's identity
    path: []u8, // absolute path, runnable by the process spawner

    pub fn deinit(self: ExtRef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub fn freeList(allocator: std.mem.Allocator, refs: []ExtRef) void {
    for (refs) |r| r.deinit(allocator);
    allocator.free(refs);
}

fn lessThan(_: void, a: ExtRef, b: ExtRef) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// List installed extensions sorted by name. Creates the extensions
/// directory if it does not exist yet.
pub fn list(allocator: std.mem.Allocator, root_dir: std.fs.Dir) ![]ExtRef {
    var ext_dir = try root_dir.makeOpenPath(EXT_DIR, .{ .iterate = true });
    defer ext_dir.close();

    var result = std.ArrayListUnmanaged(ExtRef){};
    errdefer {
        for (result.items) |r| r.deinit(allocator);
        result.deinit(allocator);
    }

    var iter = ext_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (std.mem.endsWith(u8, entry.name, ".toml")) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const path = ext_dir.realpathAlloc(allocator, entry.name) catch continue;
        errdefer allocator.free(path);
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try result.append(allocator, .{ .name = name, .path = path });
    }

    const slice = try result.toOwnedSlice(allocator);
    std.mem.sort(ExtRef, slice, {}, lessThan);
    return slice;
}

/// Find one extension by name. Caller must call ref.deinit().
pub fn find(allocator: std.mem.Allocator, root_dir: std.fs.Dir, name: []const u8) !?ExtRef {
    const refs = try list(allocator, root_dir);
    var found: ?ExtRef = null;
    for (refs) |r| {
        if (found == null and std.mem.eql(u8, r.name, name)) {
            found = r;
        } else {
            r.deinit(allocator);
        }
    }
    allocator.free(refs);
    return found;
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "list: empty root creates extensions dir and returns nothing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const refs = try list(std.testing.allocator, tmp.dir);
    defer freeList(std.testing.allocator, refs);
    try std.testing.expectEqual(@as(usize, 0), refs.len);

    var d = try tmp.dir.openDir(EXT_DIR, .{});
    d.close();
}

test "list: finds executables, skips toml and dotfiles, sorts by name" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath(EXT_DIR);

    inline for (.{ "zeta", "alpha", "alpha.toml", ".hidden" }) |n| {
        const f = try tmp.dir.createFile(EXT_DIR ++ "/" ++ n, .{});
        f.close();
    }

    const refs = try list(std.testing.allocator, tmp.dir);
    defer freeList(std.testing.allocator, refs);

    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("alpha", refs[0].name);
    try std.testing.expectEqualStrings("zeta", refs[1].name);
    try std.testing.expect(std.fs.path.isAbsolute(refs[0].path));
}

test "find: returns named extension or null" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath(EXT_DIR);
    {
        const f = try tmp.dir.createFile(EXT_DIR ++ "/linear", .{});
        f.close();
    }

    const found = try find(std.testing.allocator, tmp.dir, "linear");
    try std.testing.expect(found != null);
    found.?.deinit(std.testing.allocator);

    const missing = try find(std.testing.allocator, tmp.dir, "jira");
    try std.testing.expect(missing == null);
}
