const fs = @import("std").fs;
var logtty: fs.File = undefined;
var logger: fs.File.Writer = undefined;

pub fn init() !void {
    logtty = try fs.cwd().openFile(
        "/dev/pts/1",
        .{ .mode = fs.File.OpenMode.write_only },
    );
    logger = logtty.writer();
    try logger.writeAll("\x1B[2J");
}

pub fn deinit() !void {
    logtty.close();
}

pub fn log(comptime format: []const u8, args: anytype) void {
    logger.print(format ++ "\n", args) catch {};
}
