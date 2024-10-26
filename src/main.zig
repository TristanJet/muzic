const std = @import("std");
const sym = @import("symbols.zig");
const util = @import("util.zig");
const mpd = @import("mpdclient.zig");
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const os = std.os;
const time = std.time;

const moveCursor = util.moveCursor;
const log = util.log;
const clear = util.clear;

var tty: fs.File = undefined;
var size: Size = undefined;
var raw: os.linux.termios = undefined;
var cooked: os.linux.termios = undefined;
var quit: bool = false;

pub fn main() !void {
    try util.init();
    defer util.deinit() catch {};

    try mpd.connect();
    defer mpd.disconnect();

    // working buffer to store temporary data
    var wrkbuf: [4096]u8 = undefined;
    var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
    const wrkallocator = wrkfba.allocator();

    var storbuf: [512]u8 = undefined;
    var storfba = std.heap.FixedBufferAllocator.init(&storbuf);
    const storallocator = storfba.allocator();

    tty = try fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = fs.File.OpenMode.read_write },
    );
    defer tty.close();

    try uncook();
    defer cook() catch {};

    size = try getSize();

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

    const song = try mpd.getCurrentSong(wrkallocator, storallocator, &wrkfba.end_index);
    const songTime = try mpd.getTime(wrkallocator, &wrkfba.end_index);
    const panel: Panel = getPanel(xdim, ydim);
    log("Rendered!", .{});

    log("  title: {s} \n", .{song.getTitle()});
    log("  artist: {s} \n", .{song.getArtist()});
    log("  album: {s} \n", .{song.getAlbum()});
    log("  trackno: {s} \n", .{song.getTrackno()});
    log("  Elapsed time: {} seconds \n", .{songTime.elapsed});
    log("  Total time: {} seconds \n", .{songTime.duration});

    // var last_render_time = time.milliTimestamp();
    while (quit != true) {
        try checkInput();
        try render(wrkallocator, panel, song, songTime);
        // Sleep for a short duration to control the loop speed
        time.sleep(time.ns_per_ms * 200);
    }
}

fn checkInput() !void {
    var buffer: [1]u8 = undefined;

    // Set the tty to non-blocking mode
    _ = try std.posix.fcntl(tty.handle, os.linux.F.SETFL, os.linux.SOCK.NONBLOCK);

    const bytes_read = tty.read(&buffer) catch |err| switch (err) {
        error.WouldBlock => 0, // No input available
        else => |e| return e,
    };

    if (bytes_read > 0) {
        if (buffer[0] == 'q') {
            quit = true;
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

fn fetchTime() !mpd.Time {
    return try mpd.get_status();
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

fn render(
    allocator: std.mem.Allocator,
    p: Panel,
    s: mpd.Song,
    t: mpd.Time,
) !void {
    const writer = tty.writer();
    //try fillPanel(writer, p);
    try drawBorders(writer, p);
    try currTrack(allocator, writer, p, s, t);
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

fn formatTime(seconds: u32) [5]u8 {
    const minutes = seconds / 60;
    const remainingSeconds = seconds % 60;
    var result: [5]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{d:0>2}:{d:0>2}", .{ minutes, remainingSeconds }) catch unreachable;
    return result;
}

//on loop it will have to change
fn currTrack(
    allocator: std.mem.Allocator,
    writer: fs.File.Writer,
    p: Panel,
    s: mpd.Song,
    t: mpd.Time,
) !void {
    const p1 = [2]usize{ p.p1[0] + 1, p.p1[1] + 1 };
    const p2 = [2]usize{ p.p2[0] - 1, p.p2[1] - 1 };
    const width: usize = p2[0] + 1 - p1[0];
    const height: usize = p2[1] + 1 - p1[1];
    const ycent = (height / 2) + 1;
    const full_block = "\xe2\x96\x88"; // Unicode escape sequence for '█' (U+2588)
    const light_shade = "\xe2\x96\x92"; // Unicode escape sequence for '▒' (U+2592)

    const artist = s.getArtist();
    const album = s.getAlbum();
    const trackno = s.getTrackno();
    const has_album = album.len > 0;
    const has_trackno = trackno.len > 0;

    const trckalb = if (!has_album)
        try std.fmt.allocPrint(allocator, "{s}", .{s.getTitle()})
    else if (!has_trackno)
        try std.fmt.allocPrint(allocator, "{s} - {s}", .{
            s.getTitle(),
            album,
        })
    else
        try std.fmt.allocPrint(allocator, "{s} - {s} - {s}", .{
            s.getTitle(),
            album,
            trackno,
        });
    defer allocator.free(trckalb);

    const elapsedTime = formatTime(t.elapsed);
    const duration = formatTime(t.duration);
    const songTime = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ elapsedTime, duration });
    defer allocator.free(songTime);

    try moveCursor(writer, ycent, p1[0]);
    try writer.writeAll(songTime);
    try writeLine(writer, artist, ycent, width);
    try writeLine(writer, trckalb, ycent - 2, width);

    // Draw progress bar
    try moveCursor(writer, ycent + 2, p1[0]);
    const progress_width = p2[0] + 1 - p1[0];
    const progress_ratio = @as(f32, @floatFromInt(t.elapsed)) / @as(f32, @floatFromInt(t.duration));
    const filled_blocks = @as(usize, @intFromFloat(progress_ratio * @as(f32, @floatFromInt(progress_width))));

    var x: usize = 0;
    while (x < progress_width) : (x += 1) {
        if (x < filled_blocks) {
            try writer.writeAll(full_block);
        } else {
            try writer.writeAll(light_shade);
        }
    }
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
