const std = @import("std");

const log = @import("util.zig").log;
const fs = std.fs;
const os = std.os;

var tty: fs.File = undefined;
var writer: fs.File.Writer = undefined;

var raw: os.linux.termios = undefined;
var cooked: os.linux.termios = undefined;

const ReadError = error{
    UnknownReadError,
};

pub fn init() !void {
    try getTty();
    try cook();
    try setNonBlock();
}

fn getTty() !void {
    tty = try fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = .read_write },
    );
    writer = tty.writer();
}

pub fn ttyFile() *const fs.File {
    return &tty;
}

pub fn getWriter() *fs.File.Writer {
    return &writer;
}

pub fn readBytes(buffer: []u8) ReadError!usize {
    return tty.read(buffer) catch |err| switch (err) {
        error.WouldBlock => 0, // No input available
        else => return ReadError.UnknownReadError,
    };
}

pub fn readEscapeCode(buffer: []u8) ReadError!usize {
    raw.cc[@intFromEnum(os.linux.V.TIME)] = 1;
    raw.cc[@intFromEnum(os.linux.V.MIN)] = 0;
    _ = os.linux.tcsetattr(tty.handle, .NOW, &raw);

    const escRead = tty.read(buffer) catch |err| switch (err) {
        error.WouldBlock => 0, // No input available
        else => return ReadError.UnknownReadError,
    };

    raw.cc[@intFromEnum(os.linux.V.TIME)] = 0;
    raw.cc[@intFromEnum(os.linux.V.MIN)] = 1;
    _ = os.linux.tcsetattr(tty.handle, .NOW, &raw);

    return escRead;
}

fn setNonBlock() !void {
    _ = try std.posix.fcntl(tty.handle, os.linux.F.SETFL, os.linux.SOCK.NONBLOCK);
}

pub fn deinit() !void {
    _ = os.linux.tcgetattr(tty.handle, &cooked);
    errdefer cook() catch {};

    raw = cooked;
    inline for (.{ "ECHO", "ICANON", "ISIG", "IEXTEN" }) |flag| {
        @field(raw.lflag, flag) = false;
    }
    inline for (.{ "IXON", "ICRNL", "BRKINT", "INPCK", "ISTRIP" }) |flag| {
        @field(raw.iflag, flag) = false;
    }
    raw.cc[@intFromEnum(os.linux.V.TIME)] = 0;
    raw.cc[@intFromEnum(os.linux.V.MIN)] = 1;
    _ = os.linux.tcsetattr(tty.handle, .FLUSH, &raw);

    try hideCursor();
    try clear();
}

fn cook() !void {
    _ = os.linux.tcsetattr(tty.handle, .FLUSH, &cooked);
    try clear();
    try showCursor();
    try attributeReset();
    try moveCursor(0, 0);
}

fn attributeReset() !void {
    try writer.writeAll("\x1B[0m");
}

fn hideCursor() !void {
    try writer.writeAll("\x1B[?25l");
}

fn showCursor() !void {
    try writer.writeAll("\x1B[?25h");
}

pub fn writeLine(txt: []const u8, y: usize, xmin: usize, xmax: usize) !void {
    const panel_width = xmax - xmin;
    const x_pos = xmin + (panel_width - txt.len) / 2;
    try moveCursor(y, x_pos);
    try writer.writeAll(txt);
}

pub fn clearLine(y: usize, xmin: usize, xmax: usize) !void {
    try moveCursor(y, xmin);
    const width = xmax - xmin + 1;
    try writer.writeByteNTimes(' ', width);
}

pub fn moveCursor(row: usize, col: usize) !void {
    _ = try writer.print("\x1B[{};{}H", .{ row + 1, col + 1 });
}
fn clear() !void {
    try writer.writeAll("\x1B[2J");
}
