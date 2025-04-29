const std = @import("std");
const mem = std.mem;

const log = @import("util.zig").log;
const fmt = std.fmt;
const fs = std.fs;
const os = std.os;
const posix = std.posix;

var tty: fs.File = undefined;
var writer: fs.File.Writer = undefined;

// Use posix.termios which is platform-independent
var raw: posix.termios = undefined;
var cooked: posix.termios = undefined;

// Buffer for terminal output
const BUFFER_SIZE = 1024;
var buffer: [BUFFER_SIZE]u8 = undefined;
var buffer_pos: usize = 0;

const color_true = true;

const ReadError = error{
    NotATerminal,
    ProcessOrphaned,
    Unexpected,
};

const WriteError = error{
    BufferFull,
    Unexpected,
};

pub fn init() !void {
    try getTty();
    try uncook();
    try setNonBlock();
    try setColor(.white);
    buffer_pos = 0;
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

pub fn readBytes(read_buffer: []u8) ReadError!usize {
    return tty.read(read_buffer) catch |err| switch (err) {
        error.WouldBlock => 0, // No input available
        else => ReadError.Unexpected,
    };
}

pub fn readEscapeCode(read_buffer: []u8) ReadError!usize {
    // Use platform-independent constants for terminal settings
    // VTIME and VMIN are standardized by POSIX
    raw.cc[@intFromEnum(posix.V.TIME)] = 1;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    try posix.tcsetattr(tty.handle, .NOW, raw);

    const escRead = tty.read(read_buffer) catch |err| switch (err) {
        error.WouldBlock => 0, // No input available
        else => return ReadError.Unexpected,
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
    // const NONBLOCK = 0x0004; // This is O_NONBLOCK value for most systems including macOS
    const NONBLOCK = 0o4000;
    _ = try posix.fcntl(tty.handle, posix.F.SETFL, flags | NONBLOCK);
    const updated_flags = try posix.fcntl(tty.handle, posix.F.GETFL, 0);
    log("setNonBlock: Set flags=0x{x}, expected NONBLOCK=0x{x}", .{ updated_flags, NONBLOCK });
    if ((updated_flags & NONBLOCK) == 0) {
        log("setNonBlock: Failed to set O_NONBLOCK", .{});
    }
}

pub fn deinit() !void {
    try flushBuffer();

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
    try flushBuffer();
}

fn cook() !void {
    try posix.tcsetattr(tty.handle, .FLUSH, cooked);
    try clear();
    try showCursor();
    try attributeReset();
    try moveCursor(0, 0);
    try flushBuffer();
}

pub fn flushBuffer() !void {
    if (buffer_pos == 0) return;

    while (buffer_pos > 0) {
        //resolves to darwin libc write
        const n = writer.write(buffer[0..buffer_pos]) catch |err| {
            switch (err) {
                error.WouldBlock => {
                    std.time.sleep(1);
                    continue;
                },
                else => return err,
            }
        };
        if (n < buffer_pos) {
            mem.copyForwards(u8, buffer[0 .. buffer_pos - n], buffer[n..buffer_pos]);
        }
        buffer_pos -= n;
    }
}

fn writeToBuffer(data: []const u8) !void {
    // Check if we need to flush before adding more data
    if (buffer_pos + data.len > BUFFER_SIZE) {
        try flushBuffer();

        // If data is larger than buffer, write directly
        if (data.len > BUFFER_SIZE) {
            _ = try writer.write(data);
            return;
        }
    }

    // Copy data to buffer
    mem.copyForwards(u8, buffer[buffer_pos..], data);
    buffer_pos += data.len;
}

fn writeByteToBuffer(byte: u8) !void {
    // Check if buffer is full
    if (buffer_pos >= BUFFER_SIZE) {
        try flushBuffer();
    }

    buffer[buffer_pos] = byte;
    buffer_pos += 1;
}

// Terminal control sequences
pub fn attributeReset() !void {
    try writeToBuffer("\x1B[0m");
    try setColor(.white);
}

pub fn setBold() !void {
    try writeToBuffer("\x1B[1m");
}

pub fn hideCursor() !void {
    try writeToBuffer("\x1B[?25l");
}

pub fn showCursor() !void {
    try writeToBuffer("\x1B[?25h");
}

pub fn highlight() !void {
    try writeToBuffer("\x1B[7m");
}

pub const Color = enum {
    // red,
    // green,
    // blue,
    // yellow,
    white,
    cyan,
    magenta,
};

pub fn setColor(color: Color) !void {
    var buf: [20]u8 = undefined;
    const fullSequence: []const u8 = if (color_true)
        try trueColor(color, &buf)
    else
        try ansiColor(color, &buf);

    try writeToBuffer(fullSequence);
}

fn ansiColor(color: Color, buf: []u8) ![]const u8 {
    const color_code: u16 = switch (color) {
        // .blue => 34,
        // .red => 31,
        // .green => 32,
        // .yellow => 33,
        .white => 37,
        .cyan => 36,
        .magenta => 35,
    };

    return try fmt.bufPrint(buf, "\x1B[{}m", .{color_code});
}

fn trueColor(color: Color, buf: []u8) ![]const u8 {
    // Predefined RGB values for each named color
    const RGB = struct { r: u8, g: u8, b: u8 };
    const rgb: RGB = switch (color) {
        // .blue => .{ .r = 0, .g = 0, .b = 255 }, // True color blue
        // .red => .{ .r = 80, .g = 30, .b = 170 }, // True color red
        // .green => .{ .r = 0, .g = 255, .b = 0 }, // True color green
        // .yellow => .{ .r = 0, .g = 100, .b = 100 },
        .white => .{ .r = 255, .g = 255, .b = 255 },
        .cyan => .{ .r = 35, .g = 210, .b = 229 },
        .magenta => .{ .r = 240, .g = 60, .b = 170 },
    };

    // Format the true color ANSI sequence
    return try fmt.bufPrint(
        buf,
        "\x1B[38;2;{};{};{}m",
        .{ rgb.r, rgb.g, rgb.b },
    );
}
// Text output functions
pub fn writeAll(str: []const u8) !void {
    try writeToBuffer(str);
}

pub fn print(comptime fmt_: []const u8, args: anytype) !void {
    var temp_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&temp_buf);
    try fmt.format(fbs.writer(), fmt_, args);
    try writeToBuffer(fbs.getWritten());
}

pub fn writeByte(byte: u8) !void {
    try writeByteToBuffer(byte);
}

pub fn writeByteNTimes(byte: u8, n: usize) !void {
    for (0..n) |_| {
        try writeByteToBuffer(byte);

        // If buffer gets full, flush it automatically
        if (buffer_pos == BUFFER_SIZE) {
            try flushBuffer();
        }
    }
}

// Cursor and position control
pub fn moveCursor(row: usize, col: usize) !void {
    try print("\x1B[{};{}H", .{ row + 1, col + 1 });
}

pub fn clear() !void {
    try writeToBuffer("\x1B[2J");
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

// Helper function to write a byte sequence multiple times
pub fn writeBytesNTimesChunked(bytes: []const u8, n: usize) !void {
    for (0..n) |_| {
        try writeToBuffer(bytes);

        // If buffer gets full, flush it automatically
        if (buffer_pos + bytes.len > BUFFER_SIZE) {
            try flushBuffer();
        }
    }
}

test "buffer write" {
    if (buffer_pos == 0) return;

    var count: usize = 0;
    while (buffer_pos > 0) : (count += 1) {
        //resolves to darwin libc write
        const n = writer.write(buffer[0..buffer_pos]) catch |err| {
            switch (err) {
                error.WouldBlock => {
                    std.time.sleep(1);
                    continue;
                },
                else => return err,
            }
        };
        if (n < buffer_pos) {
            mem.copyForwards(u8, buffer[0 .. buffer_pos - n], buffer[n..buffer_pos]);
        }
        buffer_pos -= n;
    }
    log("count: {}", .{count});
}
