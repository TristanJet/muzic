const std = @import("std");

const log = @import("util.zig").log;
const fs = std.fs;
const os = std.os;
const posix = std.posix;

var tty: fs.File = undefined;
var writer: fs.File.Writer = undefined;

// Use posix.termios which is platform-independent
var raw: posix.termios = undefined;
var cooked: posix.termios = undefined;

const ReadError = error{
    UnknownReadError,
    NotATerminal,
    ProcessOrphaned,
    Unexpected,
};

// For chunked writes to prevent WouldBlock errors on macOS
// Use smaller chunk sizes for macOS which has stricter buffer limits
const DEFAULT_CHUNK_SIZE = 16;
const MULTIBYTE_CHUNK_SIZE = 8;

pub fn init() !void {
    try getTty();
    try uncook();
    try setNonBlock();
}

fn getTty() !void {
    // Try to open terminal device
    // On macOS, this is /dev/tty - avoid hardcoding ttys000
    tty = try fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = .read_write },
    );
    writer = tty.writer();
}

pub fn ttyFile() *const fs.File {
    return &tty;
}

pub fn readBytes(buffer: []u8) ReadError!usize {
    return tty.read(buffer) catch |err| switch (err) {
        error.WouldBlock => 0, // No input available
        else => return ReadError.UnknownReadError,
    };
}

pub fn readEscapeCode(buffer: []u8) ReadError!usize {
    // Use platform-independent constants for terminal settings
    // VTIME and VMIN are standardized by POSIX
    raw.cc[@intFromEnum(posix.V.TIME)] = 1;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    try posix.tcsetattr(tty.handle, .NOW, raw);

    const escRead = tty.read(buffer) catch |err| switch (err) {
        error.WouldBlock => 0, // No input available
        else => return ReadError.UnknownReadError,
    };

    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(tty.handle, .NOW, raw);

    return escRead;
}

fn setNonBlock() !void {
    // Use platform-independent fcntl with O_NONBLOCK
    const flags = try posix.fcntl(tty.handle, posix.F.GETFL, 0);
    // Use direct constant instead of NONBLOCK which may not be available on all platforms
    const NONBLOCK = 0x0004; // This is O_NONBLOCK value for most systems including macOS
    _ = try posix.fcntl(tty.handle, posix.F.SETFL, flags | NONBLOCK);
}

// Basic write functions with chunking to handle WouldBlock
fn writeAllInternal(str: []const u8) !void {
    // Write one byte at a time for maximum compatibility with macOS
    for (str) |byte| {
        try writer.writeByte(byte);
    }
}

fn writeByteInternal(byte: u8) !void {
    try writer.writeByte(byte);
}

fn writeByteNTimesInternal(byte: u8, n: usize) !void {
    var remaining = n;
    while (remaining > 0) {
        const chunk_size = @min(remaining, DEFAULT_CHUNK_SIZE);
        // Break it down even further - writing one byte at a time for maximum compatibility
        var i: usize = 0;
        while (i < chunk_size) : (i += 1) {
            try writer.writeByte(byte);
        }
        remaining -= chunk_size;
    }
}

fn printInternal(comptime fmt: []const u8, args: anytype) !void {
    // For very small outputs, try direct print
    var buf: [128]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, fmt, args) catch {
        // If it doesn't fit in our buffer, use standard print
        return writer.print(fmt, args);
    };

    // Write the formatted result as a string
    return writeAllInternal(result);
}

pub fn deinit() !void {
    cooked = try posix.tcgetattr(tty.handle);
    errdefer cook() catch {};

    raw = cooked;
    // Use portable flags from posix
    inline for (.{ "ECHO", "ICANON", "ISIG", "IEXTEN" }) |flag| {
        @field(raw.lflag, flag) = false;
    }
    inline for (.{ "IXON", "ICRNL", "BRKINT", "INPCK", "ISTRIP" }) |flag| {
        @field(raw.iflag, flag) = false;
    }
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    try posix.tcsetattr(tty.handle, .FLUSH, raw);

    try cook();
}

fn uncook() !void {
    cooked = try posix.tcgetattr(tty.handle);
    errdefer cook() catch {};

    raw = cooked;
    inline for (.{ "ECHO", "ICANON", "ISIG", "IEXTEN" }) |flag| {
        @field(raw.lflag, flag) = false;
    }
    inline for (.{ "IXON", "ICRNL", "BRKINT", "INPCK", "ISTRIP" }) |flag| {
        @field(raw.iflag, flag) = false;
    }
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    try posix.tcsetattr(tty.handle, .FLUSH, raw);

    try hideCursor();
    try clear();
}

fn cook() !void {
    try posix.tcsetattr(tty.handle, .FLUSH, cooked);
    try clear();
    try showCursor();
    try attributeReset();
    try moveCursor(0, 0);
}

// Terminal control sequences
pub fn attributeReset() !void {
    try writeAllInternal("\x1B[0m");
}

pub fn hideCursor() !void {
    try writeAllInternal("\x1B[?25l");
}

pub fn showCursor() !void {
    try writeAllInternal("\x1B[?25h");
}

pub fn highlight() !void {
    try writeAllInternal("\x1B[7m");
}

pub fn unhighlight() !void {
    try writeAllInternal("\x1B[0m");
}

pub fn setColor(color: []const u8) !void {
    try writeAllInternal(color);
}

// Text output functions
pub fn writeAll(str: []const u8) !void {
    try writeAllInternal(str);
}

pub fn print(comptime fmt: []const u8, args: anytype) !void {
    try printInternal(fmt, args);
}

pub fn writeByte(byte: u8) !void {
    try writeByteInternal(byte);
}

pub fn writeByteNTimes(byte: u8, n: usize) !void {
    try writeByteNTimesInternal(byte, n);
}

pub fn writeBytesNTimes(bytes: []const u8, n: usize) !void {
    var remaining = n;
    while (remaining > 0) {
        const chunk_size = @min(remaining, MULTIBYTE_CHUNK_SIZE);
        var i: usize = 0;
        while (i < chunk_size) : (i += 1) {
            try writeAllInternal(bytes);
        }
        remaining -= chunk_size;
    }
}

// Cursor and position control
pub fn moveCursor(row: usize, col: usize) !void {
    try printInternal("\x1B[{};{}H", .{ row + 1, col + 1 });
}

pub fn clear() !void {
    try writeAllInternal("\x1B[2J");
}

// Higher-level rendering functions
pub fn writeLine(txt: []const u8, y: usize, xmin: usize, xmax: usize) !void {
    const panel_width = xmax - xmin;
    const x_pos = xmin + (panel_width - txt.len) / 2;
    try moveCursor(y, x_pos);
    try writeAll(txt);
}

pub fn clearLine(y: usize, xmin: usize, xmax: usize) !void {
    try moveCursor(y, xmin);
    const width = xmax - xmin + 1;
    try writeByteNTimes(' ', width);
}
