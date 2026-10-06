//! TASK-2 spike build script (THROWAWAY).
//!
//! Mirrors `example/zig-vt/build.zig` from the pinned Ghostty tree: consume the
//! `ghostty-vt` Zig module exported by the `ghostty` package.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ghostty = b.dependency("ghostty", .{});
    mod.addImport("ghostty-vt", ghostty.module("ghostty-vt"));

    const exe = b.addExecutable(.{
        .name = "conduit-vt-spike",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Feed VT bytes into libghostty-vt and dump the grid");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}
