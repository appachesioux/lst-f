//! Utilitario de teste: escreve em stdout o helper.vim exato que o lst-f
//! escreveria no diretorio de estado. Usado para validar o script contra
//! Vim/Neovim de outras versoes sem abrir uma sessao.
const std = @import("std");
const session = @import("../src/session.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;

    try environ.put("TMPDIR", "/tmp");
    const fake_pid: std.posix.pid_t = @intCast(std.crypto.random.int(u31));

    var state = try session.State.create(arena, io, environ, fake_pid);
    defer state.destroy(io);
    try state.writeHelperScript(io, "lst-f", "test");

    const data = try state.dir.readFileAlloc(io, "helper.vim", arena, .limited(4 * 1024 * 1024));

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    try stdout_writer.interface.writeAll(data);
    try stdout_writer.interface.flush();
}
