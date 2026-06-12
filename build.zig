const std = @import("std");

const ext_names = [_][]const u8{ "linear", "github", "trello" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    // App tests — discover all tests through the import chain from main.zig
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Bundled extensions — standalone executables installed to zig-out/extensions/.
    // Copy them into ~/.todo/extensions to use them.
    const shared_mod = b.createModule(.{
        .root_source_file = b.path("extensions/shared/shared.zig"),
        .target = target,
        .optimize = optimize,
    });

    inline for (ext_names) |name| {
        const ext_exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("extensions/" ++ name ++ "/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "shared", .module = shared_mod },
                },
            }),
        });
        const install_ext = b.addInstallArtifact(ext_exe, .{
            .dest_dir = .{ .override = .{ .custom = "extensions" } },
        });
        b.getInstallStep().dependOn(&install_ext.step);

        const ext_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("extensions/" ++ name ++ "/main.zig"),
                .target = target,
                .imports = &.{
                    .{ .name = "shared", .module = shared_mod },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(ext_tests).step);
    }
}
