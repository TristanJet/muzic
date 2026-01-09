const std = @import("std");
const util = @import("util.zig");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const mem = std.mem;

const fmt = std.fmt;
const fs = std.fs;
const os = std.os;
const posix = std.posix;

var tty: fs.File = undefined;
var writer: fs.File.Writer = undefined;
var out: *std.io.Writer = undefined;

// Use posix.termios which is platform-independent
var raw: posix.termios = undefined;
var cooked: posix.termios = undefined;

// Buffer for terminal output
const BUFFER_SIZE = 4096;
var buffer: [BUFFER_SIZE]u8 = undefined;
var buffer_pos: usize = 0;

var caps: Capabilities = undefined;

//global var this is pretty bad lol, who cares
//There should be a bunch of values configged at the start that are read only for every other part of the program
pub var symbols: Symbols = undefined;

const ReadError = error{
    NotATerminal,
    ProcessOrphaned,
    Unexpected,
};

const WriteError = error{
    BufferFull,
    Unexpected,
};

pub const OSError = error{
    NotPosix,
};

pub fn init() !void {
    caps = try detectTerminal();
    symbols = Symbols.init(caps.is_tty);
    try getTty();
    try uncook();
    try setNonBlock();
    try setColor(.white);
    buffer_pos = 0;
}

pub const Capabilities = struct {
    truecolor: bool,
    is_tty: bool,
};

pub fn detectTerminal() OSError!Capabilities {
    const is_tty = switch (comptime native_os) {
        .linux => isTTY(),
        .macos => false,
        else => return OSError.NotPosix,
    };

    return .{
        .truecolor = if (is_tty) false else supportsTrueColor(),
        .is_tty = is_tty,
    };
}

fn isTTY() bool {
    if (posix.getenv("TERM")) |term| {
        return mem.eql(u8, term, "linux");
    }
    return false;
}

fn supportsTrueColor() bool {
    if (posix.getenv("COLORTERM")) |colorterm| {
        if (mem.eql(u8, colorterm, "truecolor") or
            mem.eql(u8, colorterm, "24bit"))
        {
            return true;
        }
    }

    if (comptime native_os == .macos) {
        if (posix.getenv("TERM_PROGRAM")) |term_program| {
            if (mem.eql(u8, term_program, "Apple_Terminal")) {
                return true;
            }
        }
    }

    return false;
}

pub const Symbols = struct {
    h_line: []const u8,
    v_line: []const u8,
    left_up: []const u8,
    right_up: []const u8,
    left_down: []const u8,
    right_down: []const u8,
    round_left_up: []const u8,
    round_right_up: []const u8,
    round_left_down: []const u8,
    round_right_down: []const u8,

    fn init(is_tty: bool) Symbols {
        return if (is_tty) .{
            .h_line = "─",
            .v_line = "│",
            .left_up = "┌",
            .right_up = "┐",
            .left_down = "└",
            .right_down = "┘",
            .round_left_up = "┌", // bad
            .round_right_up = "┐",
            .round_left_down = "└",
            .round_right_down = "┘",
        } else .{
            .h_line = "─",
            .v_line = "│",
            .left_up = "┌",
            .right_up = "┐",
            .left_down = "└",
            .right_down = "┘",
            .round_left_up = "╭",
            .round_right_up = "╮",
            .round_left_down = "╰",
            .round_right_down = "╯",
        };
    }
};

fn getTty() !void {
    tty = try fs.cwd().openFile(
        "/dev/tty",
        .{
            .mode = fs.File.OpenMode.write_only,
            .allow_ctty = false,
            .lock = .none,
            .lock_nonblocking = false,
        },
    );
    writer = tty.writerStreaming(&buffer);
    out = &writer.interface;
}

pub fn fileDescriptor() fs.File.Handle {
    return tty.handle;
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
    const flags = try posix.fcntl(tty.handle, posix.F.GETFL, 0);
    const updated_flags = try posix.fcntl(tty.handle, posix.F.SETFL, util.flagNonBlock(flags));
    if ((updated_flags & 0x0004) != 0) return error.NonBlockError;
}

pub fn deinit() !void {
    try out.flush();
    //
    // cooked = try posix.tcgetattr(tty.handle);
    // errdefer cook() catch {};
    //
    // raw = cooked;
    // // Use portable flags from posix
    // inline for (.{ "ECHO", "ICANON", "ISIG", "IEXTEN" }) |flag| {
    //     @field(raw.lflag, flag) = false;
    // }
    // inline for (.{ "IXON", "ICRNL", "BRKINT", "INPCK", "ISTRIP" }) |flag| {
    //     @field(raw.iflag, flag) = false;
    // }
    // raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    // raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    // try posix.tcsetattr(tty.handle, .FLUSH, raw);
    //
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

    // Enter alternate screen buffer
    try tty.writeAll("\x1b[?1049h");
    try hideCursor();
    try clear();
    try out.flush();
}

fn cook() !void {
    try showCursor();
    try attributeReset();

    // Exit alternate screen buffer (restores previous content)
    try tty.writeAll("\x1b[?1049l");

    try posix.tcsetattr(tty.handle, .FLUSH, cooked);
    try out.flush();
}

pub fn attributeReset() !void {
    try out.writeAll("\x1B[0m");
    try setColor(.white);
}

pub fn setBold() !void {
    try out.writeAll("\x1B[1m");
}

pub fn hideCursor() !void {
    try out.writeAll("\x1B[?25l");
}

pub fn showCursor() !void {
    try out.writeAll("\x1B[?25h");
}

pub fn highlight() !void {
    try out.writeAll("\x1B[7m");
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
    const fullSequence: []const u8 = if (caps.truecolor)
        try trueColor(color, &buf)
    else
        try ansiColor(color, &buf);

    try out.writeAll(fullSequence);
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

pub fn flush() !void {
    try out.flush();
}

// Text output functions
pub fn writeAll(str: []const u8) !void {
    try out.writeAll(str);
}

pub fn writeByteNTimes(byte: u8, n: usize) !void {
    for (0..n) |_| try out.writeByte(byte);
}

// Cursor and position control
pub fn moveCursor(row: usize, col: usize) !void {
    try out.print("\x1B[{};{}H", .{ row + 1, col + 1 });
}

pub fn clear() !void {
    try out.writeAll("\x1B[2J");
}

pub fn clearLine(y: usize, xmin: usize, xmax: usize) !void {
    try moveCursor(y, xmin);
    const width = xmax - xmin + 1;
    try writeByteNTimes(' ', width);
}
