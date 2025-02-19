const fs = @import("std").fs;
const terminal = @import("terminal.zig");

var logtty: fs.File = undefined;
var logger: fs.File.Writer = undefined;

pub fn init() !void {
    logtty = try fs.cwd().openFile(
        "/dev/pts/1",
        .{ .mode = fs.File.OpenMode.write_only },
    );
    logger = logtty.writer();
    try terminal.clear();
}

pub fn deinit() !void {
    try terminal.moveCursor(0, 0);
    logtty.close();
}

pub fn log(comptime format: []const u8, args: anytype) void {
    logger.print(format ++ "\n", args) catch {};
}
