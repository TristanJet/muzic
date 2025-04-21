const std = @import("std");
const fs = std.fs;
const math = std.math;
var logtty: fs.File = undefined;
var logger: fs.File.Writer = undefined;
//macos tty: /dev/ttys001

pub fn init() !void {
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
    logger.print(format ++ "\n", args) catch {};
}

const S = struct {
    fn compareStrings(context: void, key: []const u8, mid_item: []const u8) math.Order {
        _ = context;
        return std.mem.order(u8, key, mid_item);
    }
};

// Binary search for a string in a sorted slice of strings
pub fn findStringIndex(
    key: []const u8,
    items: []const []const u8,
) ?usize {
    return std.sort.binarySearch(
        []const u8, // Type T
        key, // The string to find
        items, // The sorted slice of strings
        {}, // Context (empty since we don't need it)
        S.compareStrings, // Comparison function
    );
}
