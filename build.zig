const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSafe)") orelse .ReleaseSafe;

    const families_mod = b.createModule(.{
        .root_source_file = b.path("src/families.zig"),
        .target = target,
        .optimize = optimize,
    });
    const explore = b.addExecutable(.{
        .name = "explore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/explore.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(explore);
    const run_explore = b.addRunArtifact(explore);
    if (b.args) |args| run_explore.addArgs(args);
    b.step("explore", "Report where family rules disagree on small subjects").dependOn(&run_explore.step);

    const test_step = b.step("test", "Run repeat-family oracle tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = families_mod })).step);

    // Differential test against the fork's real matcher (8-bit, static).
    const pcre2 = b.dependency("pcre2", .{
        .target = target,
        .optimize = optimize,
        .@"code-unit-width" = @as([]const u8, "8"),
        .linkage = std.builtin.LinkMode.static,
    });
    const pcre2_c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().addCopyFile(pcre2.path("src/pcre2.h.generic"), "pcre2.h"),
        .target = target,
        .optimize = optimize,
    });
    pcre2_c.defineCMacro("PCRE2_CODE_UNIT_WIDTH", "8");
    pcre2_c.defineCMacro("PCRE2_STATIC", "");
    const diff_mod = b.createModule(.{
        .root_source_file = b.path("src/differential_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    diff_mod.addImport("pcre2_c", pcre2_c.createModule());
    diff_mod.addImport("pcre2_capture_history", pcre2.module("pcre2_capture_history"));
    diff_mod.linkLibrary(pcre2.artifact("pcre2-8"));
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = diff_mod })).step);
}
