/// Extension CLI command handlers.
const std = @import("std");
const toml = @import("../storage/toml.zig");
const ext_config = @import("../storage/ext_config.zig");
const registry = @import("../extensions/registry.zig");
const runner = @import("../extensions/runner.zig");
const protocol = @import("../extensions/protocol.zig");
const engine = @import("../extensions/engine.zig");

/// Split "key=value" into a toml.KV; null when there is no '='.
fn parseKeyValue(arg: []const u8) ?toml.KV {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    if (eq == 0) return null;
    return toml.KV{ .key = arg[0..eq], .value = arg[eq + 1 ..] };
}

fn maskSecret(buf: []u8, value: []const u8) []const u8 {
    if (value.len == 0) return "(not set)";
    const tail = @min(4, value.len);
    const stars = @min(buf.len -| tail, 8);
    @memset(buf[0..stars], '*');
    std.mem.copyForwards(u8, buf[stars .. stars + tail], value[value.len - tail ..]);
    return buf[0 .. stars + tail];
}

/// todo ext list
pub fn cmdList(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    _ = args;
    const refs = try registry.list(allocator, root_dir);
    defer registry.freeList(allocator, refs);

    if (refs.len == 0) {
        try writer.print("No extensions installed.\nDrop executables into ~/.todo/extensions to add some.\n", .{});
        return;
    }

    for (refs) |ref| {
        // Ask each extension for its manifest; tolerate broken ones.
        const out = runner.run(allocator, ref.path, "manifest", null) catch {
            try writer.print("{s}  (not runnable)\n", .{ref.name});
            continue;
        };
        defer out.deinit(allocator);
        if (!out.ok()) {
            try writer.print("{s}  (manifest failed)\n", .{ref.name});
            continue;
        }
        const manifest = protocol.parseManifest(allocator, out.stdout) catch {
            try writer.print("{s}  (invalid manifest)\n", .{ref.name});
            continue;
        };
        defer manifest.deinit(allocator);

        try writer.print("{s}", .{ref.name});
        if (manifest.version.len > 0) try writer.print(" v{s}", .{manifest.version});
        try writer.print("  [", .{});
        var first = true;
        inline for (.{ .{ manifest.can_import, "import" }, .{ manifest.can_export, "export" }, .{ manifest.can_setup, "setup" } }) |cap| {
            if (cap[0]) {
                if (!first) try writer.print(", ", .{});
                try writer.print("{s}", .{cap[1]});
                first = false;
            }
        }
        try writer.print("]", .{});
        if (manifest.description.len > 0) try writer.print("\n    {s}", .{manifest.description});
        try writer.print("\n", .{});
    }
}

/// todo ext config <name> [key=value ...]
pub fn cmdConfig(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return error.MissingArgument;
    const name = args[0];

    const ref = try registry.find(allocator, root_dir, name) orelse return error.ExtensionNotFound;
    defer ref.deinit(allocator);

    var set_any = false;
    for (args[1..]) |arg| {
        const kv = parseKeyValue(arg) orelse return error.InvalidArgument;
        try ext_config.setGlobalValue(allocator, root_dir, name, kv.key, kv.value);
        set_any = true;
    }
    if (set_any) {
        try writer.print("Config updated for {s}.\n", .{name});
        return;
    }

    // Show current values, masking keys the manifest declares secret.
    var map = try ext_config.loadGlobal(allocator, root_dir, name);
    defer toml.freeMap(allocator, &map);

    var manifest: ?protocol.Manifest = null;
    defer if (manifest) |m| m.deinit(allocator);
    if (runner.run(allocator, ref.path, "manifest", null)) |out| {
        defer out.deinit(allocator);
        if (out.ok()) manifest = protocol.parseManifest(allocator, out.stdout) catch null;
    } else |_| {}

    if (manifest) |m| {
        if (m.config_keys.len == 0 and map.count() == 0) {
            try writer.print("{s} declares no config keys.\n", .{name});
            return;
        }
        for (m.config_keys) |ck| {
            const value = map.get(ck.key) orelse "";
            var mask_buf: [16]u8 = undefined;
            const display = if (ck.secret) maskSecret(&mask_buf, value) else if (value.len > 0) value else "(not set)";
            try writer.print("{s} = {s}    # {s}\n", .{ ck.key, display, ck.label });
        }
    } else {
        var it = map.iterator();
        while (it.next()) |entry| {
            try writer.print("{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
}

/// todo ext setup <name>
pub fn cmdSetup(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return error.MissingArgument;
    const name = args[0];

    const ref = try registry.find(allocator, root_dir, name) orelse return error.ExtensionNotFound;
    defer ref.deinit(allocator);

    // Pass the extension's current global config via TODO_EXT_CONFIG.
    var map = try ext_config.loadGlobal(allocator, root_dir, name);
    defer toml.freeMap(allocator, &map);
    var kvs = std.ArrayListUnmanaged(protocol.KV){};
    defer kvs.deinit(allocator);
    var it = map.iterator();
    while (it.next()) |entry| {
        try kvs.append(allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
    }
    const config_json = try protocol.buildConfigObject(allocator, kvs.items);
    defer allocator.free(config_json);

    // Flush before handing the terminal to the extension.
    try writer.flush();

    const out = try runner.runSetup(allocator, ref.path, config_json);
    defer out.deinit(allocator);
    if (!out.ok()) return error.SetupFailed;

    const payload = try protocol.parseSetupResponse(allocator, out.stdout);
    defer payload.deinit(allocator);
    if (payload.err_msg) |msg| {
        try writer.print("Setup failed: {s}\n", .{msg});
        return error.SetupFailed;
    }

    for (payload.pairs) |kv| {
        try ext_config.setGlobalValue(allocator, root_dir, name, kv.key, kv.value);
    }
    try writer.print("Setup complete for {s} ({d} config value(s) saved).\n", .{ name, payload.pairs.len });
}

/// todo ext link <space> <project> <name> [key=value ...]
pub fn cmdLink(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len < 3) return error.MissingArgument;
    const space = args[0];
    const project = args[1];
    const name = args[2];

    const ref = try registry.find(allocator, root_dir, name) orelse return error.ExtensionNotFound;
    defer ref.deinit(allocator);

    var pairs = std.ArrayListUnmanaged(toml.KV){};
    defer pairs.deinit(allocator);
    for (args[3..]) |arg| {
        const kv = parseKeyValue(arg) orelse return error.InvalidArgument;
        try pairs.append(allocator, kv);
    }

    try ext_config.saveProjectLink(allocator, root_dir, space, project, name, pairs.items);
    try writer.print("Linked {s}/{s} to {s}.\n", .{ space, project, name });
}

/// todo ext unlink <space> <project>
pub fn cmdUnlink(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    _ = allocator;
    if (args.len < 2) return error.MissingArgument;
    try ext_config.removeProjectLink(root_dir, args[0], args[1]);
    try writer.print("Unlinked {s}/{s}.\n", .{ args[0], args[1] });
}

/// todo ext import <space> <project>
pub fn cmdImport(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len < 2) return error.MissingArgument;

    const outcome = try engine.importProject(allocator, root_dir, args[0], args[1]);
    defer outcome.deinit(allocator);
    switch (outcome) {
        .ok => |r| try writer.print("Import done: {d} created, {d} updated, {d} errors.\n", .{ r.created, r.updated, r.errors }),
        .fail => |msg| {
            try writer.print("Import failed: {s}\n", .{msg});
            return error.ImportFailed;
        },
    }
}

/// todo ext export <space> <project>
pub fn cmdExport(allocator: std.mem.Allocator, root_dir: std.fs.Dir, writer: *std.io.Writer, args: []const []const u8) !void {
    if (args.len < 2) return error.MissingArgument;

    const outcome = try engine.exportProject(allocator, root_dir, args[0], args[1]);
    defer outcome.deinit(allocator);
    switch (outcome) {
        .ok => |r| try writer.print("Export done: {d} exported, {d} skipped.\n", .{ r.exported, r.skipped }),
        .fail => |msg| {
            try writer.print("Export failed: {s}\n", .{msg});
            return error.ExportFailed;
        },
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "parseKeyValue splits on first equals" {
    const kv = parseKeyValue("api_key=abc=def").?;
    try std.testing.expectEqualStrings("api_key", kv.key);
    try std.testing.expectEqualStrings("abc=def", kv.value);

    try std.testing.expect(parseKeyValue("noequals") == null);
    try std.testing.expect(parseKeyValue("=value") == null);
}

test "maskSecret keeps only the tail visible" {
    var buf: [16]u8 = undefined;
    const masked = maskSecret(&buf, "lin_api_secret123");
    try std.testing.expect(std.mem.endsWith(u8, masked, "t123"));
    try std.testing.expect(std.mem.startsWith(u8, masked, "********"));
    try std.testing.expectEqualStrings("(not set)", maskSecret(&buf, ""));
}
