const std = @import("std");
const sym = @import("symbols.zig");
const mpd = @import("mpdclient.zig");
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
    logger.print(format ++ "\n", args) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

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
    defer clear(logtty.writer()) catch {};
    defer moveCursor(logtty.writer(), 0, 0) catch {};

    size = try getSize();
    log("Size: {}", .{size});

    const xdim = Dim{
        .totalfr = 6,
        .startline = 0,
        .endline = 5,
    };

    const ydim = Dim{
        .totalfr = 7,
        .startline = 0,
        .endline = 1,
    };
    const panel: Panel = getPanel(xdim, ydim);
    log("panel {}", .{panel});

    const allocator = gpa.allocator();

    const song: mpd.Song = try mpd.getCurrentSong(allocator);
    defer {
        // Free the allocated memory
        allocator.free(song.uri);
        allocator.free(song.title);
        allocator.free(song.artist);
    }
    log("Title: {s}", .{song.title});
    log("Artist: {s}", .{song.artist});
    log("Time: {}", .{song.duration});

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
            log("input: {} {s}", .{ buffer[0], buffer });
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
    //try fillPanel(writer, p);
    try writeLine(writer, "Hello, World!!", (size.height / 2), size.width);
    try drawBorders(writer, p);
    try currTrack(writer, p);
}

fn drawBorders(writer: fs.File.Writer, p: Panel) !void {
    try moveCursor(writer, p.p1[1], p.p1[0]);
    try writer.writeAll(sym.round_left_up);
    var x: usize = p.p1[0] + 1;
    while (x != p.p2[0]) {
        try writer.writeAll(sym.h_line);
        x += 1;
    }
    try writer.writeAll(sym.round_right_up);
    var y: usize = p.p1[1] + 1;
    while (y != p.p2[1]) {
        try moveCursor(writer, y, p.p1[0]);
        try writer.writeAll(sym.v_line);
        try moveCursor(writer, y, p.p2[0]);
        try writer.writeAll(sym.v_line);
        y += 1;
    }
    try moveCursor(writer, p.p2[1], p.p1[0]);
    try writer.writeAll(sym.round_left_down);
    x = p.p1[0] + 1;
    while (x != p.p2[0]) {
        try writer.writeAll(sym.h_line);
        x += 1;
    }
    try writer.writeAll(sym.round_right_down);
}

fn currTrack(writer: fs.File.Writer, p: Panel) !void {
    const p1 = [2]usize{ p.p1[0] + 1, p.p1[1] + 1 };
    const p2 = [2]usize{ p.p2[0] - 1, p.p2[1] - 1 };
    const width: usize = p2[0] + 1 - p1[0];
    const height: usize = p2[1] + 1 - p1[1];
    const ycent = (height / 2) + 1;
    log("p2[0] : {}", .{p2[0]});
    log("width: {} ", .{width});
    log("height: {}", .{height});
    const block_char = "\xe2\x96\x88"; // Unicode escape sequence for '█' (U+2588)
    const artist = "Charli XCX";
    const trckalb = "Mean Girls - BRAT - 13.";
    const time = "1:15/3:47";

    try moveCursor(writer, ycent, p1[0]);
    try writer.writeAll(time);
    try writeLine(writer, artist, ycent, width);
    try writeLine(writer, trckalb, ycent - 2, width);
    try moveCursor(writer, ycent + 2, p1[0]);
    var x: usize = p1[0];
    while (x != p2[0] + 1) {
        try writer.writeAll(block_char);
        x += 1;
    }
    log("X pos: {}", .{x});
}

fn fillPanel(writer: anytype, p: Panel) !void {
    //const block_char = "\xe2\x96\x88"; // Unicode escape sequence for '█' (U+2588)
    const block_char = "X";
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
        .width = (p2x + 1) - p1x,
        .height = (p2y + 1) - p1y,
    };
}
