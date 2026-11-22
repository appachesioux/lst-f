const std = @import("std");
const testing = std.testing;
const tzif = @import("lst_f").tzif;

fn putU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .big);
}
fn putI32(buf: []u8, off: usize, v: i32) void {
    std.mem.writeInt(i32, buf[off..][0..4], v, .big);
}
fn putI64(buf: []u8, off: usize, v: i64) void {
    std.mem.writeInt(i64, buf[off..][0..8], v, .big);
}

test "parseTzif rejeita cabecalho invalido ou truncado" {
    try testing.expectError(error.InvalidTzif, tzif.parseTzif("", 0));
    var bad: [44]u8 = @splat(0);
    @memcpy(bad[0..4], "NOPE");
    try testing.expectError(error.InvalidTzif, tzif.parseTzif(&bad, 0));
    var short: [15]u8 = @splat(0);
    @memcpy(short[0..5], "TZif2");
    try testing.expectError(error.InvalidTzif, tzif.parseTzif(&short, 0));
}

test "parseTzif v1 resolve transicao de horario de verao" {
    // 2 transicoes (t=1000 -> -7200, t=2000 -> -10800), 2 ttinfos, 4 chars
    var buf: [44 + 2 * 4 + 2 + 2 * 6 + 4]u8 = @splat(0);
    @memcpy(buf[0..4], "TZif");
    buf[4] = 0; // v1
    putU32(&buf, 32, 2); // timecnt
    putU32(&buf, 36, 2); // typecnt
    putU32(&buf, 40, 4); // charcnt

    // transitions
    putI32(&buf, 44, 1000);
    putI32(&buf, 48, 2000);
    // types
    buf[52] = 1; // DST (-7200)
    buf[53] = 0; // STD (-10800)
    // ttinfo[0]: -10800, isdst=0
    putI32(&buf, 54, -10800);
    buf[58] = 0;
    // ttinfo[1]: -7200, isdst=1
    putI32(&buf, 60, -7200);
    buf[64] = 1;

    try testing.expectEqual(@as(i32, -10800), try tzif.parseTzif(&buf, 500));
    try testing.expectEqual(@as(i32, -7200), try tzif.parseTzif(&buf, 1500));
    try testing.expectEqual(@as(i32, -10800), try tzif.parseTzif(&buf, 2500));
}

test "parseTzif v2 le bloco de 64 bits" {
    // v1 vazio (1 ttinfo) + v2 com 1 transicao > 2^31
    const v1_data_len = 6 + 1;
    const v2_off = 44 + v1_data_len;
    const v2_data_len = 8 + 1 + 2 * 6 + 1;
    var buf: [v2_off + 44 + v2_data_len]u8 = @splat(0);

    // v1 header
    @memcpy(buf[0..4], "TZif");
    buf[4] = '2';
    putU32(&buf, 36, 1); // typecnt
    putU32(&buf, 40, 1); // charcnt
    putI32(&buf, 44, 0);

    // v2 header
    @memcpy(buf[v2_off .. v2_off + 4], "TZif");
    buf[v2_off + 4] = '2';
    putU32(&buf, v2_off + 32, 1); // timecnt
    putU32(&buf, v2_off + 36, 2); // typecnt
    putU32(&buf, v2_off + 40, 1); // charcnt

    const d2 = v2_off + 44;
    putI64(&buf, d2, 5_000_000_000);
    buf[d2 + 8] = 1;
    putI32(&buf, d2 + 9, -10800);
    buf[d2 + 13] = 0;
    putI32(&buf, d2 + 15, -7200);
    buf[d2 + 19] = 1;

    try testing.expectEqual(@as(i32, -10800), try tzif.parseTzif(&buf, 4_000_000_000));
    try testing.expectEqual(@as(i32, -7200), try tzif.parseTzif(&buf, 5_000_000_001));
}
