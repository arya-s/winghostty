const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to Windows cross-compilation
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add ghostty-vt dependency with SIMD disabled for cross-compilation
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    // Add GLFW dependency
    if (b.lazyDependency("glfw", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.linkLibrary(dep.artifact("glfw3"));
    }

    // Add FreeType dependency
    if (b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("freetype", dep.module("freetype"));
        exe_mod.linkLibrary(dep.artifact("freetype"));
    }

    // Add z2d dependency for sprite rendering
    if (b.lazyDependency("z2d", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("z2d", dep.module("z2d"));
    }

    // Add OpenGL/glad headers and source
    exe_mod.addIncludePath(b.path("vendor/glad/include"));
    exe_mod.addCSourceFile(.{
        .file = b.path("vendor/glad/src/gl.c"),
        .flags = &.{},
    });

    // Link OpenGL on Windows
    exe_mod.linkSystemLibrary("opengl32", .{});

    const exe = b.addExecutable(.{
        .name = "phantty",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
