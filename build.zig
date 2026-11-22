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
    run_cmd.addPassthruArgs();
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

    // Escreve o helper.vim gerado em stdout, para validar o VimL contra
    // Vim/Neovim sem abrir uma sessao de verdade.
    const dump_mod = b.createModule(.{
        .root_source_file = b.path("test/dump_helper.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lst_f", .module = lib_mod },
            .{ .name = "build_options", .module = options_mod },
        },
    });
    const dump = b.addExecutable(.{ .name = "dump-helper", .root_module = dump_mod });
    const dump_run = b.addRunArtifact(dump);
    b.step("dump-helper", "Imprime o helper.vim gerado").dependOn(&dump_run.step);

    // Testa o helper.vim real no Vim e/ou Neovim headless usando arquivo temporario exclusivo.
    const vim_test = b.addSystemCommand(&.{
        "sh",
        "-eu",
        "-c",
        \\tmp="$(mktemp -d "${TMPDIR:-/tmp}/lstf-vim-test.XXXXXX")"
        \\trap 'rm -rf "$tmp"' EXIT
        \\helper="$tmp/helper.vim"
        \\"$1" > "$helper"
        \\export LST_F_HELPER="$helper"
        \\ran=0
        \\if command -v vim >/dev/null 2>&1; then
        \\  vim -Nu NONE -i NONE -n -es -S test/sort_test.vim
        \\  ran=1
        \\fi
        \\if command -v nvim >/dev/null 2>&1; then
        \\  nvim --headless -u NONE -i NONE -n -S test/sort_test.vim
        \\  ran=1
        \\fi
        \\if [ "$ran" -eq 0 ]; then
        \\  echo "nenhum vim ou nvim encontrado no PATH" >&2
        \\  exit 1
        \\fi
    ,
        "--",
    });
    vim_test.addArtifactArg(dump);
    b.step("test-vim", "Roda a suite de testes VimL no Vim e Neovim").dependOn(&vim_test.step);
}
