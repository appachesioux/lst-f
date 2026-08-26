const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "app_name", "lst-f");
    const options_mod = options.createModule();

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "lst-f",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Roda o lst-f").dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/main_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lst_f", .module = lib_mod },
            .{ .name = "build_options", .module = options_mod },
        },
    });

    const exe_tests = b.addTest(.{ .root_module = test_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    b.step("test", "Roda a suite de testes").dependOn(&run_exe_tests.step);
}
