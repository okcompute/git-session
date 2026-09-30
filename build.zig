const std = @import("std");

/// Configures the build graph for the `git-session` executable.
/// Registers a "run" step so the binary can be launched via `zig build run`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const zon = @import("build.zig.zon");
    const version = b.option([]const u8, "version", "Override version string") orelse
        zon.version;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", options);
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));

    const exe = b.addExecutable(.{
        .name = "git-session",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run git-session");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------------------
    // Test step: `zig build test`
    // ---------------------------------------------------------------------------
    // Each source module with `test` blocks gets its own test compilation.
    const test_modules = [_][]const u8{
        "src/config.zig",
        "src/git.zig",
        "src/git_branch_validate.zig",
        "src/tmux.zig",
        "src/term.zig",
        "src/repo.zig",
        "src/process.zig",
        "src/usage.zig",
    };

    const test_step = b.step("test", "Run unit tests");

    for (test_modules) |src| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
}
