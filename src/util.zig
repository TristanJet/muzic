const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const math = std.math;
const mem = std.mem;
var logtty: fs.File = undefined;
var logger: fs.File.Writer = undefined;
const state = @import("state.zig");
const alloc = @import("allocators.zig");
const lowerBuf1: *[512]u8 = alloc.ptrLower1;
const lowerBuf2: *[512]u8 = alloc.ptrLower2;
const SearchSample = @import("algo.zig").SearchSample;
const ascii = std.ascii;
//macos tty: /dev/ttys001

pub fn loggerInit() !void {
    logtty = try fs.cwd().openFile(
        "/dev/pts/1",
        .{ .mode = fs.File.OpenMode.write_only },
    );
    logger = logtty.writer();
    try logger.writeAll("\x1B[2J");
    initErr() catch return error.StdErrInitFailed;
}

pub fn deinit() !void {
    logtty.close();
}

fn initErr() !void {
    const stderr_fd = std.io.getStdErr().handle;
    // Redirect stderr to the target terminal's file descriptor
    try std.posix.dup2(logtty.handle, stderr_fd);
}

pub fn log(comptime format: []const u8, args: anytype) void {
    if (builtin.mode == .Debug) logger.print(format ++ "\n", args) catch return;
}

pub const CompareType = enum {
    binary,
    linear,
};

fn linearFind(context: S, items: []const []const u8) ?usize {
    for (items, 0..) |item, i| {
        var lowerItem: []const u8 = undefined;
        if (context.uppers) |uppers| {
            lowerItem = state.fastLowerString(item, uppers[i], context.lowerBuf);
        } else {
            lowerItem = ascii.lowerString(context.lowerBuf, item);
        }
        if (mem.eql(u8, context.key, lowerItem)) return i;
    }
    return null;
}

const S = struct {
    key: []const u8,
    uppers: ?[]const []const u16,
    lowerBuf: []u8,
};

fn compareStrings(context: S, mid_item: []const u8, index: usize) math.Order {
    var lowerItem: []const u8 = undefined;
    if (context.uppers) |uppers| {
        lowerItem = state.fastLowerString(mid_item, uppers[index], context.lowerBuf);
    } else {
        lowerItem = ascii.lowerString(context.lowerBuf, lowerItem);
    }
    const order = std.mem.order(u8, context.key, lowerItem);
    return order;
}

fn binarySearch(
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime compareFn: fn (@TypeOf(context), T, usize) std.math.Order,
) ?usize {
    var low: usize = 0;
    var high: usize = items.len;

    while (low < high) {
        // Avoid overflowing in the midpoint calculation
        const mid = low + (high - low) / 2;
        switch (compareFn(context, items[mid], mid)) {
            .eq => return mid,
            .gt => low = mid + 1,
            .lt => high = mid,
        }
    }
    return null;
}
// Binary search for a string in a sorted slice of strings
pub fn findStringIndex(
    key: []const u8,
    items: []const []const u8,
    uppers: ?[]const []const u16,
    compare_type: CompareType,
) ?usize {
    const lowerKey: []const u8 = ascii.lowerString(lowerBuf1, key);
    return switch (compare_type) {
        .binary => binarySearch([]const u8, items, S{ .key = lowerKey, .uppers = uppers, .lowerBuf = lowerBuf2 }, compareStrings),
        .linear => linearFind(S{ .key = lowerKey, .uppers = uppers, .lowerBuf = lowerBuf2 }, items),
    };
}
