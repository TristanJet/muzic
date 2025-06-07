const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const math = std.math;
const mem = std.mem;
var logtty: fs.File = undefined;
var logger: fs.File.Writer = undefined;
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

fn linearFind(key: []const u8, items: []const []const u8) ?usize {
    for (items, 0..) |item, i| {
        if (mem.eql(u8, key, item)) return i;
    }
    return null;
}
const S = struct {
    fn compareStrings(key: []const u8, mid_item: []const u8) math.Order {
        return std.mem.order(u8, key, mid_item);
    }
};

// Binary search for a string in a sorted slice of strings
pub fn findStringIndex(
    key: []const u8,
    items: []const []const u8,
    compare_type: CompareType,
) ?usize {
    return switch (compare_type) {
        .binary => std.sort.binarySearch([]const u8, items, key, S.compareStrings),
        .linear => linearFind(key, items),
    };
}
