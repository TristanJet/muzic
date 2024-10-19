const fs = @import("std").fs;

var logtty: fs.File = undefined;
var logger: fs.File.Writer = undefined;

pub fn init() !void {
    logtty = try fs.cwd().openFile(
        "/dev/pts/1",
        .{ .mode = fs.File.OpenMode.write_only },
    );
    logger = logtty.writer();
}

pub fn clear(writer: anytype) !void {
    try writer.writeAll("\x1B[2J");
}

pub fn deinit() !void {
    try moveCursor(logtty.writer(), 0, 0);
    try clear(logtty);
    logtty.close();
}

pub fn moveCursor(writer: anytype, row: usize, col: usize) !void {
    _ = try writer.print("\x1B[{};{}H", .{ row + 1, col + 1 });
}

pub fn log(comptime format: []const u8, args: anytype) void {
    logger.print(format ++ "\n", args) catch {};
}
