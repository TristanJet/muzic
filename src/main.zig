const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const os = std.os;

var logtty: fs.File = undefined;
var logger: fs.File.Writer = undefined;
var tty: fs.File = undefined;
var size: Size = undefined;
var raw: os.linux.termios = undefined;
var cooked: os.linux.termios = undefined;

fn log(comptime format: []const u8, args: anytype) void {
    logger.print(format, args) catch {};
}

pub fn main() !void {
    tty = try fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = fs.File.OpenMode.read_write },
    );
    defer tty.close();

    logtty = try fs.cwd().openFile(
        "/dev/pts/1",
        .{ .mode = fs.File.OpenMode.write_only },
    );
    defer logtty.close();
    logger = logtty.writer();

    try uncook();
    defer cook() catch {};

    size = try getSize();
    log("Size: {}\n", .{size});

    const xdim = Dim{
        .totalfr = 6,
        .startline = 2,
        .endline = 4,
    };

    const ydim = Dim{
        .totalfr = 8,
        .startline = 0,
        .endline = 1,
    };
    const panel: Panel = getPanel(xdim, ydim);
    log("panel {}\n", .{panel});

    while (true) {
        try render(panel);
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
            log("input: {} {s}\r\n", .{ buffer[0], buffer });
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

fn render(p: Panel) !void {
    const writer = tty.writer();
    try fillPanel(writer, p);
    try writeLine(writer, "Hello, World!!", (size.height / 2), size.width);
}

fn fillPanel(writer: anytype, p: Panel) !void {
    const block_char = "\xe2\x96\x88"; // Unicode escape sequence for '█' (U+2588)
    var blocks = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, p.width * 3);
    defer blocks.deinit();

    for (0..p.width) |_| {
        try blocks.appendSlice(block_char);
    }

    for (0..p.height) |row| {
        try moveCursor(writer, p.p1[1] + row, p.p1[0]);
        try writer.writeAll(blocks.items);
    }
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

const Panel = struct {
    p1: [2]usize,
    p2: [2]usize,
    width: usize,
    height: usize,
};

const Dim = struct {
    totalfr: u8,
    startline: u8,
    endline: u8,
};

fn getPanel(x: Dim, y: Dim) Panel {
    const xfr = @as(f32, @floatFromInt(size.width)) / @as(f32, @floatFromInt(x.totalfr));
    const yfr = @as(f32, @floatFromInt(size.height)) / @as(f32, @floatFromInt(y.totalfr));

    const p1x = @as(usize, @intFromFloat(@round(xfr * @as(f32, @floatFromInt(x.startline)))));
    const p1y = @as(usize, @intFromFloat(@round(yfr * @as(f32, @floatFromInt(y.startline)))));
    const p2x = @as(usize, @intFromFloat(@round(xfr * @as(f32, @floatFromInt(x.endline)))));
    const p2y = @as(usize, @intFromFloat(@round(yfr * @as(f32, @floatFromInt(y.endline)))));

    return Panel{
        .p1 = .{ p1x, p1y },
        .p2 = .{ p2x, p2y },
        .width = p2x - p1x,
        .height = p2y - p1y,
    };
}
