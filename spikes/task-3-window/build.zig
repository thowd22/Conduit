//! Throwaway spike for TASK-3 (windowing/GPU candidate "GLFW 3.4 + OpenGL 3.3 core").
//! This is NOT the Conduit build. See README.md.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .Debug,
    });

    // GLFW bindings: generated at build time from the vendored GLFW 3.4 C header
    // with `zig translate-c`, then linked against the *system* libglfw.
    const glfw_tc = std.Build.Step.TranslateC.create(b, .{
        .root_source_file = b.path("c/glfw3.h"),
        .target = target,
        .optimize = optimize,
    });
    glfw_tc.addIncludePath(b.path("c"));

    // OpenGL bindings: zopengl (OpenGL core profile up to 4.6, pure Zig).
    const zopengl = b.dependency("zopengl", .{});

    const exe = b.addExecutable(.{
        .name = "glfw-gl-quad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("glfw", glfw_tc.createModule());
    exe.root_module.addImport("zopengl", zopengl.module("root"));
    exe.root_module.linkSystemLibrary("glfw", .{});

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the spike (needs an X display; wrap in xvfb-run -a)").dependOn(&run.step);
}
