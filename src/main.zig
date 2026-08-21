const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    return cli.run(init);
}

test {
    _ = @import("plan.zig");
    _ = @import("explorer.zig");
    _ = @import("fsops.zig");
    _ = @import("fzf.zig");
    _ = @import("editor.zig");
    _ = @import("preview.zig");
    _ = @import("session.zig");
    _ = @import("cli.zig");
}
