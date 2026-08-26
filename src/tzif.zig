const std = @import("std");

fn rdU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .big);
}
fn rdI32(b: []const u8, off: usize) i32 {
    return std.mem.readInt(i32, b[off..][0..4], .big);
}
fn rdI64(b: []const u8, off: usize) i64 {
    return std.mem.readInt(i64, b[off..][0..8], .big);
}

const TzHeader = struct {
    version: u8,
    isutcnt: u32,
    isstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,
};

fn parseHeader(b: []const u8) !TzHeader {
    if (b.len < 44 or !std.mem.eql(u8, b[0..4], "TZif")) return error.InvalidTzif;
    return .{
        .version = b[4],
        .isutcnt = rdU32(b, 20),
        .isstdcnt = rdU32(b, 24),
        .leapcnt = rdU32(b, 28),
        .timecnt = rdU32(b, 32),
        .typecnt = rdU32(b, 36),
        .charcnt = rdU32(b, 40),
    };
}

fn blockSize(h: TzHeader, time_size: usize) usize {
    return h.timecnt * time_size + h.timecnt + h.typecnt * 6 +
        h.charcnt + h.leapcnt * (time_size + 4) + h.isstdcnt + h.isutcnt;
}

fn offsetForNow(h: TzHeader, data: []const u8, time_size: usize, now: i64) !i32 {
    if (h.typecnt == 0) return error.InvalidTzif;
    if (data.len < blockSize(h, time_size)) return error.InvalidTzif;

    const trans = data[0 .. h.timecnt * time_size];
    const types = data[h.timecnt * time_size ..][0..h.timecnt];
    const ttinfo = data[h.timecnt * time_size + h.timecnt ..][0 .. h.typecnt * 6];

    var chosen: ?usize = null;
    var i: usize = 0;
    while (i < h.timecnt) : (i += 1) {
        const t: i64 = if (time_size == 8) rdI64(trans, i * 8) else rdI32(trans, i * 4);
        if (t <= now) chosen = i else break;
    }

    var type_idx: usize = undefined;
    if (chosen) |c| {
        type_idx = types[c];
    } else {
        type_idx = 0;
        var k: usize = 0;
        while (k < h.typecnt) : (k += 1) {
            if (ttinfo[k * 6 + 4] == 0) {
                type_idx = k;
                break;
            }
        }
    }
    if (type_idx >= h.typecnt) return error.InvalidTzif;
    return rdI32(ttinfo, type_idx * 6);
}

pub fn parseTzif(b: []const u8, now: i64) !i32 {
    const h1 = try parseHeader(b);
    if (h1.version >= '2') {
        const off2 = 44 + blockSize(h1, 4);
        if (b.len < off2 + 44) return error.InvalidTzif;
        const h2 = try parseHeader(b[off2..]);
        return offsetForNow(h2, b[off2 + 44 ..], 8, now);
    }
    return offsetForNow(h1, b[44..], 4, now);
}
