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

    const use_win32 = b.option(bool, "use_win32", "Use Win32 backend (default: true)") orelse true;
    buildBackend(b, target, optimize, use_win32);
}

fn buildBackend(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_win32: bool,
) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build options passed to source code
    const build_options = b.addOptions();
    build_options.addOption(bool, "use_win32", use_win32);
    exe_mod.addOptions("build_options", build_options);

    // Add ghostty-vt dependency with SIMD disabled for cross-compilation
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    // Add GLFW dependency (only for glfw backend)
    if (!use_win32) {
        if (b.lazyDependency("glfw", .{
            .target = target,
            .optimize = optimize,
        })) |dep| {
            exe_mod.linkLibrary(dep.artifact("glfw3"));
        }
    }

    // Win32 backend: link native Windows libraries
    if (use_win32) {
        exe_mod.linkSystemLibrary("user32", .{});
        exe_mod.linkSystemLibrary("gdi32", .{});
        exe_mod.linkSystemLibrary("dwmapi", .{});
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

    const name = "phantty";

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_mod,
    });

    // Debug builds use Console subsystem so std.debug.print output is visible.
    // Release builds use Windows GUI subsystem to avoid a background console window.
    exe.subsystem = if (optimize == .Debug) .Console else .Windows;

    b.installArtifact(exe);
}
