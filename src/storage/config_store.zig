/// App preferences persistence — <root>/config.toml.
/// Extension credentials/config live in ext_config.zig, not here.
const std = @import("std");
const toml = @import("toml.zig");

pub const GlobalConfig = struct {
    compact_mode: bool,

    pub fn deinit(self: GlobalConfig, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub fn loadGlobalConfig(allocator: std.mem.Allocator, root_dir: std.fs.Dir) !GlobalConfig {
    const file = root_dir.openFile("config.toml", .{}) catch |err| switch (err) {
        error.FileNotFound => return GlobalConfig{ .compact_mode = false },
        else => return err,
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    var map = try toml.parse(allocator, content);
    defer toml.freeMap(allocator, &map);

    return GlobalConfig{
        .compact_mode = std.mem.eql(u8, map.get("compact_mode") orelse "false", "true"),
    };
}

pub fn saveGlobalConfig(allocator: std.mem.Allocator, root_dir: std.fs.Dir, cfg: GlobalConfig) !void {
    const pairs = [_]toml.KV{
        .{ .key = "compact_mode", .value = if (cfg.compact_mode) "true" else "false" },
    };
    const content = try toml.serialize(allocator, &pairs);
    defer allocator.free(content);
    const file = try root_dir.createFile("config.toml", .{});
    defer file.close();
    try file.writeAll(content);
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "loadGlobalConfig returns defaults when config.toml is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg = try loadGlobalConfig(std.testing.allocator, tmp.dir);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(false, cfg.compact_mode);
}

test "GlobalConfig round-trips through save and load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveGlobalConfig(std.testing.allocator, tmp.dir, .{ .compact_mode = true });

    const loaded = try loadGlobalConfig(std.testing.allocator, tmp.dir);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, loaded.compact_mode);
}

test "loadGlobalConfig ignores unknown legacy keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Old config files carried integration credentials; they must not break loading.
    const legacy =
        \\linear_api_key = "lin_old"
        \\github_token = "ghp_old"
        \\compact_mode = "true"
        \\
    ;
    const file = try tmp.dir.createFile("config.toml", .{});
    defer file.close();
    try file.writeAll(legacy);

    const cfg = try loadGlobalConfig(std.testing.allocator, tmp.dir);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, cfg.compact_mode);
}
