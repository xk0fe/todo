/// Global config and per-project integration config persistence.
/// Global config lives at <root>/config.toml.
/// Per-project integration config lives at <root>/<space>/<project>/.integration.toml.
const std = @import("std");
const toml = @import("toml.zig");

pub const GlobalConfig = struct {
    linear_api_key:         []const u8,
    linear_enabled:         bool,
    github_token:           []const u8,
    github_enabled:         bool,
    github_oauth_client_id: []const u8, // for device-flow OAuth (optional)
    trello_api_key:         []const u8,
    trello_token:           []const u8,
    trello_enabled:         bool,
    compact_mode:           bool,

    pub fn deinit(self: GlobalConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.linear_api_key);
        allocator.free(self.github_token);
        allocator.free(self.github_oauth_client_id);
        allocator.free(self.trello_api_key);
        allocator.free(self.trello_token);
    }
};

pub const ProjectIntegration = struct {
    linear_team_id:           []const u8,
    linear_project_id:        []const u8,
    github_owner:             []const u8,
    github_repo:              []const u8,
    trello_board_id:          []const u8,
    trello_list_id_todo:      []const u8,
    trello_list_id_in_progress: []const u8,
    trello_list_id_in_review: []const u8,
    trello_list_id_done:      []const u8,

    pub fn deinit(self: ProjectIntegration, allocator: std.mem.Allocator) void {
        allocator.free(self.linear_team_id);
        allocator.free(self.linear_project_id);
        allocator.free(self.github_owner);
        allocator.free(self.github_repo);
        allocator.free(self.trello_board_id);
        allocator.free(self.trello_list_id_todo);
        allocator.free(self.trello_list_id_in_progress);
        allocator.free(self.trello_list_id_in_review);
        allocator.free(self.trello_list_id_done);
    }
};

pub fn loadGlobalConfig(allocator: std.mem.Allocator, root_dir: std.fs.Dir) !GlobalConfig {
    const file = root_dir.openFile("config.toml", .{}) catch |err| switch (err) {
        error.FileNotFound => return defaultGlobalConfig(allocator),
        else => return err,
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    var map = try toml.parse(allocator, content);
    defer toml.freeMap(allocator, &map);

    return GlobalConfig{
        .linear_api_key         = try allocator.dupe(u8, map.get("linear_api_key") orelse ""),
        .linear_enabled         = std.mem.eql(u8, map.get("linear_enabled") orelse "false", "true"),
        .github_token           = try allocator.dupe(u8, map.get("github_token") orelse ""),
        .github_enabled         = std.mem.eql(u8, map.get("github_enabled") orelse "false", "true"),
        .github_oauth_client_id = try allocator.dupe(u8, map.get("github_oauth_client_id") orelse ""),
        .trello_api_key         = try allocator.dupe(u8, map.get("trello_api_key") orelse ""),
        .trello_token           = try allocator.dupe(u8, map.get("trello_token") orelse ""),
        .trello_enabled         = std.mem.eql(u8, map.get("trello_enabled") orelse "false", "true"),
        .compact_mode           = std.mem.eql(u8, map.get("compact_mode") orelse "false", "true"),
    };
}

fn defaultGlobalConfig(allocator: std.mem.Allocator) !GlobalConfig {
    return GlobalConfig{
        .linear_api_key         = try allocator.dupe(u8, ""),
        .linear_enabled         = false,
        .github_token           = try allocator.dupe(u8, ""),
        .github_enabled         = false,
        .github_oauth_client_id = try allocator.dupe(u8, ""),
        .trello_api_key         = try allocator.dupe(u8, ""),
        .trello_token           = try allocator.dupe(u8, ""),
        .trello_enabled         = false,
        .compact_mode           = false,
    };
}

pub fn saveGlobalConfig(allocator: std.mem.Allocator, root_dir: std.fs.Dir, cfg: GlobalConfig) !void {
    const pairs = [_]toml.KV{
        .{ .key = "linear_api_key",         .value = cfg.linear_api_key },
        .{ .key = "linear_enabled",         .value = if (cfg.linear_enabled) "true" else "false" },
        .{ .key = "github_token",           .value = cfg.github_token },
        .{ .key = "github_enabled",         .value = if (cfg.github_enabled) "true" else "false" },
        .{ .key = "github_oauth_client_id", .value = cfg.github_oauth_client_id },
        .{ .key = "trello_api_key",         .value = cfg.trello_api_key },
        .{ .key = "trello_token",           .value = cfg.trello_token },
        .{ .key = "trello_enabled",         .value = if (cfg.trello_enabled) "true" else "false" },
        .{ .key = "compact_mode",           .value = if (cfg.compact_mode) "true" else "false" },
    };
    const content = try toml.serialize(allocator, &pairs);
    defer allocator.free(content);
    const file = try root_dir.createFile("config.toml", .{});
    defer file.close();
    try file.writeAll(content);
}

pub fn loadProjectIntegration(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8) !ProjectIntegration {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/.integration.toml", .{ space, project }) catch
        return error.PathTooLong;

    const file = root_dir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return defaultProjectIntegration(allocator),
        else => return err,
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    var map = try toml.parse(allocator, content);
    defer toml.freeMap(allocator, &map);

    return ProjectIntegration{
        .linear_team_id           = try allocator.dupe(u8, map.get("linear_team_id") orelse ""),
        .linear_project_id        = try allocator.dupe(u8, map.get("linear_project_id") orelse ""),
        .github_owner             = try allocator.dupe(u8, map.get("github_owner") orelse ""),
        .github_repo              = try allocator.dupe(u8, map.get("github_repo") orelse ""),
        .trello_board_id          = try allocator.dupe(u8, map.get("trello_board_id") orelse ""),
        .trello_list_id_todo      = try allocator.dupe(u8, map.get("trello_list_id_todo") orelse ""),
        .trello_list_id_in_progress = try allocator.dupe(u8, map.get("trello_list_id_in_progress") orelse ""),
        .trello_list_id_in_review = try allocator.dupe(u8, map.get("trello_list_id_in_review") orelse ""),
        .trello_list_id_done      = try allocator.dupe(u8, map.get("trello_list_id_done") orelse ""),
    };
}

fn defaultProjectIntegration(allocator: std.mem.Allocator) !ProjectIntegration {
    return ProjectIntegration{
        .linear_team_id           = try allocator.dupe(u8, ""),
        .linear_project_id        = try allocator.dupe(u8, ""),
        .github_owner             = try allocator.dupe(u8, ""),
        .github_repo              = try allocator.dupe(u8, ""),
        .trello_board_id          = try allocator.dupe(u8, ""),
        .trello_list_id_todo      = try allocator.dupe(u8, ""),
        .trello_list_id_in_progress = try allocator.dupe(u8, ""),
        .trello_list_id_in_review = try allocator.dupe(u8, ""),
        .trello_list_id_done      = try allocator.dupe(u8, ""),
    };
}

pub fn saveProjectIntegration(allocator: std.mem.Allocator, root_dir: std.fs.Dir, space: []const u8, project: []const u8, pi: ProjectIntegration) !void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/.integration.toml", .{ space, project }) catch
        return error.PathTooLong;

    const pairs = [_]toml.KV{
        .{ .key = "linear_team_id",             .value = pi.linear_team_id },
        .{ .key = "linear_project_id",          .value = pi.linear_project_id },
        .{ .key = "github_owner",               .value = pi.github_owner },
        .{ .key = "github_repo",                .value = pi.github_repo },
        .{ .key = "trello_board_id",            .value = pi.trello_board_id },
        .{ .key = "trello_list_id_todo",        .value = pi.trello_list_id_todo },
        .{ .key = "trello_list_id_in_progress", .value = pi.trello_list_id_in_progress },
        .{ .key = "trello_list_id_in_review",   .value = pi.trello_list_id_in_review },
        .{ .key = "trello_list_id_done",        .value = pi.trello_list_id_done },
    };
    const content = try toml.serialize(allocator, &pairs);
    defer allocator.free(content);
    const file = try root_dir.createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "loadGlobalConfig returns defaults when config.toml is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg = try loadGlobalConfig(std.testing.allocator, tmp.dir);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("", cfg.linear_api_key);
    try std.testing.expectEqual(false, cfg.linear_enabled);
    try std.testing.expectEqualStrings("", cfg.github_token);
    try std.testing.expectEqual(false, cfg.github_enabled);
    try std.testing.expectEqualStrings("", cfg.trello_api_key);
    try std.testing.expectEqualStrings("", cfg.trello_token);
    try std.testing.expectEqual(false, cfg.trello_enabled);
}

test "GlobalConfig round-trips through save and load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = GlobalConfig{
        .linear_api_key         = "lin_api_test123",
        .linear_enabled         = true,
        .github_token           = "ghp_testtoken",
        .github_enabled         = true,
        .github_oauth_client_id = "Ov23litest",
        .trello_api_key         = "trello_key",
        .trello_token           = "trello_tok",
        .trello_enabled         = false,
    };

    try saveGlobalConfig(std.testing.allocator, tmp.dir, original);

    const loaded = try loadGlobalConfig(std.testing.allocator, tmp.dir);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("lin_api_test123", loaded.linear_api_key);
    try std.testing.expectEqual(true, loaded.linear_enabled);
    try std.testing.expectEqualStrings("ghp_testtoken", loaded.github_token);
    try std.testing.expectEqual(true, loaded.github_enabled);
    try std.testing.expectEqualStrings("trello_key", loaded.trello_api_key);
    try std.testing.expectEqualStrings("trello_tok", loaded.trello_token);
    try std.testing.expectEqual(false, loaded.trello_enabled);
}

test "loadGlobalConfig with partial file uses defaults for missing keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a partial config with only linear_api_key set
    const partial = "linear_api_key = \"mykey\"\n";
    const file = try tmp.dir.createFile("config.toml", .{});
    defer file.close();
    try file.writeAll(partial);

    const cfg = try loadGlobalConfig(std.testing.allocator, tmp.dir);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("mykey", cfg.linear_api_key);
    try std.testing.expectEqual(false, cfg.linear_enabled); // default
    try std.testing.expectEqualStrings("", cfg.github_token); // default
}

test "ProjectIntegration round-trips through save and load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create space/project directory structure
    try tmp.dir.makePath("work/api");

    const original = ProjectIntegration{
        .linear_team_id           = "team-abc",
        .linear_project_id        = "proj-xyz",
        .github_owner             = "myorg",
        .github_repo              = "myrepo",
        .trello_board_id          = "board123",
        .trello_list_id_todo      = "list-todo",
        .trello_list_id_in_progress = "list-wip",
        .trello_list_id_in_review = "list-review",
        .trello_list_id_done      = "list-done",
    };

    try saveProjectIntegration(std.testing.allocator, tmp.dir, "work", "api", original);

    const loaded = try loadProjectIntegration(std.testing.allocator, tmp.dir, "work", "api");
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("team-abc",    loaded.linear_team_id);
    try std.testing.expectEqualStrings("proj-xyz",    loaded.linear_project_id);
    try std.testing.expectEqualStrings("myorg",       loaded.github_owner);
    try std.testing.expectEqualStrings("myrepo",      loaded.github_repo);
    try std.testing.expectEqualStrings("board123",    loaded.trello_board_id);
    try std.testing.expectEqualStrings("list-todo",   loaded.trello_list_id_todo);
    try std.testing.expectEqualStrings("list-wip",    loaded.trello_list_id_in_progress);
    try std.testing.expectEqualStrings("list-review", loaded.trello_list_id_in_review);
    try std.testing.expectEqualStrings("list-done",   loaded.trello_list_id_done);
}

test "loadProjectIntegration returns defaults when file missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("work/api");

    const pi = try loadProjectIntegration(std.testing.allocator, tmp.dir, "work", "api");
    defer pi.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("", pi.linear_team_id);
    try std.testing.expectEqualStrings("", pi.github_owner);
    try std.testing.expectEqualStrings("", pi.trello_board_id);
}
