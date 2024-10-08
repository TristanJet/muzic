const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const os = std.os;

var tty: fs.File = undefined;
var size: Size = undefined;
var raw: os.linux.termios = undefined;
var cooked: os.linux.termios = undefined;

pub fn main() !void {
    tty = try fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = fs.File.OpenMode.read_write },
    );
    defer tty.close();

    try uncook();
    defer cook() catch {};

    size = try getSize();

    while (true) {
        try render();
        var buffer: [1]u8 = undefined;
        _ = try tty.read(&buffer);
        if (buffer[0] == 'q') {
            return;
        } else if (buffer[0] == '\x1B') {
            //Escape
            //debug.print("input: escape\r\n", .{});
        } else if (buffer[0] == '\n' or buffer[0] == '\r') {
            //return
            //debug.print("input: return\r\n", .{});
        } else {
            //character
            //debug.print("input: {} {s}\r\n", .{ buffer[0], buffer });
        }
    }
}

fn uncook() !void {
    const writer = tty.writer();
    _ = os.linux.tcgetattr(tty.handle, &cooked);
    errdefer cook() catch {};

    raw = cooked;
    // var original: os.linux.termios = undefined;
    // _ = os.linux.tcgetattr(tty.handle, &original);
    // raw = original;
    inline for (.{ "ECHO", "ICANON", "ISIG", "IEXTEN" }) |flag| {
        @field(raw.lflag, flag) = false;
    }
    inline for (.{ "IXON", "ICRNL", "BRKINT", "INPCK", "ISTRIP" }) |flag| {
        @field(raw.iflag, flag) = false;
    }
    raw.cc[@intFromEnum(os.linux.V.TIME)] = 0;
    raw.cc[@intFromEnum(os.linux.V.MIN)] = 1;
    _ = os.linux.tcsetattr(tty.handle, .FLUSH, &raw);

    try hideCursor(writer);
    try clear(writer);
}

fn cook() !void {
    _ = os.linux.tcsetattr(tty.handle, .FLUSH, &cooked);
    const writer = tty.writer();
    try clear(writer);
    try showCursor(writer);
    //try attributeReset(writer);
    try moveCursor(writer, 0, 0);
}

fn attributeReset(writer: anytype) !void {
    try writer.writeAll("\x1B[0m");
}

fn hideCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25l");
}

fn showCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25h");
}

fn clear(writer: anytype) !void {
    try writer.writeAll("\x1B[2J");
}

fn render() !void {
    const writer = tty.writer();
    try writeLine(writer, "Hello, World!!", (size.height / 2), size.width);
}

fn moveCursor(writer: anytype, row: usize, col: usize) !void {
    _ = try writer.print("\x1B[{};{}H", .{ row + 1, col + 1 });
}

fn writeLine(writer: anytype, txt: []const u8, y: usize, width: usize) !void {
    try moveCursor(writer, y, (width - txt.len) / 2);
    try writer.writeAll(txt);
    try writer.writeByteNTimes(' ', width - txt.len);
}

const Size = struct { width: usize, height: usize };

fn getSize() !Size {
    var win_size = mem.zeroes(os.linux.winsize);
    const err = os.linux.ioctl(tty.handle, os.linux.T.IOCGWINSZ, @intFromPtr(&win_size));
    if (std.posix.errno(err) != .SUCCESS) {
        return std.posix.unexpectedErrno(os.linux.E.init(err));
    }
    return Size{
        .height = win_size.ws_row,
        .width = win_size.ws_col,
    };
}
