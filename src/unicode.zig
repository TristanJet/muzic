const DisplayWidth = @import("DisplayWidth");
const CodePointIterator = @import("code_point").Iterator;
const ascii = @import("ascii");

const util = @import("util.zig");
const alloc = @import("allocators.zig");

pub const StringWidth = struct {
    byte_offset: usize,
    width: usize,
};

pub fn fittingBytes(dw: DisplayWidth, max: usize, str: []const u8) StringWidth {
    var width_total: isize = 0;

    // ASCII fast path
    if (ascii.isAsciiOnly(str)) {
        if (str.len < max) {
            return .{
                .byte_offset = str.len,
                .width = str.len,
            };
        }
        return .{
            .byte_offset = max,
            .width = max,
        };
    }

    var giter = dw.graphemes.iterator(str);
    var offset: usize = 0;
    while (giter.next()) |gc| {
        var cp_iter = CodePointIterator{ .bytes = gc.bytes(str) };
        var gc_total: isize = 0;

        while (cp_iter.next()) |cp| {
            var w = dw.codePointWidth(cp.code);

            if (w != 0) {
                // Handle text emoji sequence.
                if (cp_iter.next()) |ncp| {
                    // emoji text sequence.
                    if (ncp.code == 0xFE0E) w = 1;
                    if (ncp.code == 0xFE0F) w = 2;
                }

                // Only adding width of first non-zero-width code point.
                if (gc_total == 0) {
                    gc_total = w;
                    break;
                }
            }
        }

        util.log("width: {}", .{width_total + gc_total});
        util.log("string offset: {s}", .{str[0..(gc.offset + gc.len)]});
        util.log("offset: {}", .{gc.offset + gc.len});
        util.log("-----------------", .{});
        if (width_total + gc_total > max) return .{
            .byte_offset = offset,
            .width = @intCast(@max(0, width_total)),
        };

        width_total += gc_total;
        offset = gc.offset + gc.len;
    }

    return .{
        .byte_offset = offset,
        .width = @intCast(@max(0, width_total)),
    };
}

test "display width" {
    try util.loggerInit();
    // defer util.deinit() catch {};

    const dw: DisplayWidth = try DisplayWidth.init(alloc.persistentAllocator);
    const string = "작은 것들을 위한 시 (Boy With Luv)";
    // const string = "ペルソナ3 オリジナル･サウンドトラック";
    const width = dw.strWidth(string);
    const zeroes = [_]u8{'0'} ** 1024;
    util.log("", .{});
    util.log("Width: {}\nString:\n{s}\n{s}", .{ width, string, zeroes[0..width] });
}

test "fitting bytes" {
    // try util.loggerInit();
    defer util.deinit() catch {};

    const dw: DisplayWidth = try DisplayWidth.init(alloc.persistentAllocator);
    const string = "작은 것들을 위한 시 (Boy With Luv)";
    // const string = "ペルソナ3 オリジナル･サウンドトラック";
    const zeroes = [_]u8{'0'} ** 1024;
    const s = fittingBytes(dw, 11, string);
    const offset = s[0];
    util.log("Max: 11\nString:\n{s}\n{s}", .{ string[0..offset], zeroes[0..11] });
    util.log("display width: {}", .{s[1]});
}
