/// Extension config persistence.
/// Global config per extension:  <root>/extensions/<name>.toml
/// Per-project link:             <root>/<space>/<project>/.extension.toml
///   The reserved key "extension" names the linked extension; every other
///   key is per-project config that overrides the global value.
const std = @import("std");
const toml = @import("toml.zig");

pub const LINK_FILE = ".extension.toml";
pub const RESERVED_EXT_KEY = "extension";

fn globalPath(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "extensions/{s}.toml", .{name}) catch error.PathTooLong;
}

fn linkPath(buf: []u8, space: []const u8, project: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/" ++ LINK_FILE, .{ space, project }) catch error.PathTooLong;
}

fn loadMap(allocator: std.mem.Allocator, root_dir: std.fs.Dir, path: []const u8) !toml.Map {
    const file = root_dir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => return err,
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);
    return toml.parse(allocator, content);
}

fn saveMapSorted(allocator: std.mem.Allocator, root_dir: std.fs.Dir, path: []const u8, map: *const toml.Map) !void {
    var keys = std.ArrayListUnmanaged([]const u8){};
    defer keys.deinit(allocator);
    var it = map.iterator();
    while (it.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var pairs = std.ArrayListUnmanaged(toml.KV){};
    defer pairs.deinit(allocator);
    for (keys.items) |k| {
        try pairs.append(allocator, .{ .key = k, .value = map.get(k).? });
    }

    const content = try toml.serialize(allocator, pairs.items);
    defer allocator.free(content);
    const file = try root_dir.createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Load an extension's global config. Caller frees with toml.freeMap.
pub fn loadGlobal(allocator: std.mem.Allocator, root_dir: std.fs.Dir, name: []const u8) !toml.Map {
    var buf: [512]u8 = undefined;
    return loadMap(allocator, root_dir, try globalPath(&buf, name));
}

/// Set one key in an extension's global config (creating the file if needed).
pub fn setGlobalValue(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    name: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    var map = try loadGlobal(allocator, root_dir, name);
    defer toml.freeMap(allocator, &map);

    const k = try allocator.dupe(u8, key);
    errdefer allocator.free(k);
    const v = try allocator.dupe(u8, value);
    errdefer allocator.free(v);
    if (map.fetchRemove(key)) |old| {
        allocator.free(old.key);
        allocator.free(old.value);
    }
    try map.put(allocator, k, v);

    try root_dir.makePath("extensions");
    var buf: [512]u8 = undefined;
    try saveMapSorted(allocator, root_dir, try globalPath(&buf, name), &map);
}

pub const ProjectLink = struct {
    extension: []const u8,
    config:    toml.Map, // per-project overrides (without the "extension" key)

    pub fn deinit(self: *ProjectLink, allocator: std.mem.Allocator) void {
        allocator.free(self.extension);
        toml.freeMap(allocator, &self.config);
    }
};

/// Load a project's extension link, or null when the project is not linked.
pub fn loadProjectLink(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
) !?ProjectLink {
    var buf: [512]u8 = undefined;
    var map = try loadMap(allocator, root_dir, try linkPath(&buf, space, project));
    errdefer toml.freeMap(allocator, &map);

    const removed = map.fetchRemove(RESERVED_EXT_KEY) orelse {
        toml.freeMap(allocator, &map);
        return null;
    };
    allocator.free(removed.key);
    if (removed.value.len == 0) {
        allocator.free(removed.value);
        toml.freeMap(allocator, &map);
        return null;
    }

    return ProjectLink{ .extension = removed.value, .config = map };
}

/// Link a project to an extension, merging `pairs` into any existing
/// per-project config. Pass an extension name to (re)link.
pub fn saveProjectLink(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    space: []const u8,
    project: []const u8,
    extension: []const u8,
    pairs: []const toml.KV,
) !void {
    var buf: [512]u8 = undefined;
    const path = try linkPath(&buf, space, project);

    var map = try loadMap(allocator, root_dir, path);
    defer toml.freeMap(allocator, &map);

    const put = struct {
        fn put(a: std.mem.Allocator, m: *toml.Map, key: []const u8, value: []const u8) !void {
            const k = try a.dupe(u8, key);
            errdefer a.free(k);
            const v = try a.dupe(u8, value);
            errdefer a.free(v);
            if (m.fetchRemove(key)) |old| {
                a.free(old.key);
                a.free(old.value);
            }
            try m.put(a, k, v);
        }
    }.put;

    try put(allocator, &map, RESERVED_EXT_KEY, extension);
    for (pairs) |kv| try put(allocator, &map, kv.key, kv.value);

    try saveMapSorted(allocator, root_dir, path, &map);
}

/// Remove a project's extension link.
pub fn removeProjectLink(root_dir: std.fs.Dir, space: []const u8, project: []const u8) !void {
    var buf: [512]u8 = undefined;
    const path = linkPath(&buf, space, project) catch return error.PathTooLong;
    root_dir.deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub const MergedConfig = struct {
    pairs: []toml.KV, // keys and values are owned

    pub fn deinit(self: MergedConfig, allocator: std.mem.Allocator) void {
        for (self.pairs) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(self.pairs);
    }
};

/// Global config overlaid with the project's per-project values
/// (project wins), sorted by key.
pub fn mergedConfig(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    name: []const u8,
    space: []const u8,
    project: []const u8,
) !MergedConfig {
    var merged = try loadGlobal(allocator, root_dir, name);
    defer toml.freeMap(allocator, &merged);

    var link = try loadProjectLink(allocator, root_dir, space, project);
    if (link) |*l| {
        defer l.deinit(allocator);
        if (std.mem.eql(u8, l.extension, name)) {
            var it = l.config.iterator();
            while (it.next()) |entry| {
                const k = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(k);
                const v = try allocator.dupe(u8, entry.value_ptr.*);
                errdefer allocator.free(v);
                if (merged.fetchRemove(k)) |old| {
                    allocator.free(old.key);
                    allocator.free(old.value);
                }
                try merged.put(allocator, k, v);
            }
        }
    }

    var keys = std.ArrayListUnmanaged([]const u8){};
    defer keys.deinit(allocator);
    var it = merged.iterator();
    while (it.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var pairs = std.ArrayListUnmanaged(toml.KV){};
    errdefer {
        for (pairs.items) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        pairs.deinit(allocator);
    }
    for (keys.items) |k| {
        const key = try allocator.dupe(u8, k);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, merged.get(k).?);
        try pairs.append(allocator, .{ .key = key, .value = value });
    }

    return MergedConfig{ .pairs = try pairs.toOwnedSlice(allocator) };
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "global config: set and load round-trip" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try setGlobalValue(std.testing.allocator, tmp.dir, "linear", "api_key", "lin_123");
    try setGlobalValue(std.testing.allocator, tmp.dir, "linear", "team_id", "team-x");
    try setGlobalValue(std.testing.allocator, tmp.dir, "linear", "api_key", "lin_456"); // overwrite

    var map = try loadGlobal(std.testing.allocator, tmp.dir, "linear");
    defer toml.freeMap(std.testing.allocator, &map);
    try std.testing.expectEqualStrings("lin_456", map.get("api_key").?);
    try std.testing.expectEqualStrings("team-x", map.get("team_id").?);
}

test "loadGlobal: missing file yields empty map" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var map = try loadGlobal(std.testing.allocator, tmp.dir, "nope");
    defer toml.freeMap(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "project link: save, load, unlink" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("work/api");

    try saveProjectLink(std.testing.allocator, tmp.dir, "work", "api", "github", &.{
        .{ .key = "owner", .value = "myorg" },
        .{ .key = "repo", .value = "myrepo" },
    });

    var link = (try loadProjectLink(std.testing.allocator, tmp.dir, "work", "api")).?;
    defer link.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("github", link.extension);
    try std.testing.expectEqualStrings("myorg", link.config.get("owner").?);

    try removeProjectLink(tmp.dir, "work", "api");
    const gone = try loadProjectLink(std.testing.allocator, tmp.dir, "work", "api");
    try std.testing.expect(gone == null);
}

test "loadProjectLink: returns null when not linked" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("work/api");
    const link = try loadProjectLink(std.testing.allocator, tmp.dir, "work", "api");
    try std.testing.expect(link == null);
}

test "mergedConfig: project values override global, sorted by key" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("work/api");

    try setGlobalValue(std.testing.allocator, tmp.dir, "linear", "api_key", "global-key");
    try setGlobalValue(std.testing.allocator, tmp.dir, "linear", "team_id", "global-team");
    try saveProjectLink(std.testing.allocator, tmp.dir, "work", "api", "linear", &.{
        .{ .key = "team_id", .value = "project-team" },
    });

    const merged = try mergedConfig(std.testing.allocator, tmp.dir, "linear", "work", "api");
    defer merged.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), merged.pairs.len);
    try std.testing.expectEqualStrings("api_key", merged.pairs[0].key);
    try std.testing.expectEqualStrings("global-key", merged.pairs[0].value);
    try std.testing.expectEqualStrings("team_id", merged.pairs[1].key);
    try std.testing.expectEqualStrings("project-team", merged.pairs[1].value);
}

test "mergedConfig: link to a different extension does not leak its config" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("work/api");

    try setGlobalValue(std.testing.allocator, tmp.dir, "linear", "api_key", "k");
    try saveProjectLink(std.testing.allocator, tmp.dir, "work", "api", "github", &.{
        .{ .key = "owner", .value = "o" },
    });

    const merged = try mergedConfig(std.testing.allocator, tmp.dir, "linear", "work", "api");
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), merged.pairs.len);
    try std.testing.expectEqualStrings("api_key", merged.pairs[0].key);
}
