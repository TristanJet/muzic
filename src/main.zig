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
var window: Window = undefined;
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

    //Stores a single Song struct
    var currTrackBuf: [128]u8 = undefined;
    var currTrackfba = std.heap.FixedBufferAllocator.init(&currTrackBuf);
    const currTrackallocator = currTrackfba.allocator();

    tty = try fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = fs.File.OpenMode.read_write },
    );
    defer tty.close();

    try uncook();
    defer cook() catch {};

    window = try getWindow();

    const xdim = Dim{
        .totalfr = 6,
        .startline = 1,
        .endline = 5,
    };

    const ydim = Dim{
        .totalfr = 7,
        .startline = 3,
        .endline = 4,
    };

    const song = try mpd.getCurrentSong(wrkallocator, currTrackallocator, &wrkfba.end_index);
    var songTime = try mpd.getTime(wrkallocator, &wrkfba.end_index);
    const panel: Panel = getPanel(xdim, ydim);
    log("Rendered!", .{});
    log("-------------------", .{});

    log("  title: {s} \n", .{song.getTitle()});
    log("  artist: {s} \n", .{song.getArtist()});
    log("  album: {s} \n", .{song.getAlbum()});
    log("  trackno: {s} \n", .{song.getTrackno()});
    log("  Elapsed time: {} seconds \n", .{songTime.elapsed});
    log("  Total time: {} seconds \n", .{songTime.duration});

    var last_render_time = time.milliTimestamp();

    while (quit != true) {
        const current_time = time.milliTimestamp();
        try checkInput();
        if (isRenderTime(last_render_time, current_time)) {
            songTime.elapsed += @intCast(current_time - last_render_time);
            try render(wrkallocator, panel, song, songTime, &wrkfba.end_index);
            last_render_time = current_time;
        }
        // Small sleep to prevent CPU hogging
        time.sleep(time.ns_per_ms * 10);
    }
}

fn isRenderTime(last_render_time: i64, current_time: i64) bool {
    if ((current_time - last_render_time) >= 200) return true;
    return false;
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
    wrkallocator: std.mem.Allocator,
    p: Panel,
    s: mpd.Song,
    t: mpd.Time,
    end_index: *usize,
) !void {
    const writer = tty.writer();
    try drawBorders(writer, p);
    try currTrack(wrkallocator, writer, p, s, t, end_index);
}

fn drawBorders(writer: fs.File.Writer, p: Panel) !void {
    try moveCursor(writer, p.ymin, p.xmin);
    try writer.writeAll(sym.round_left_up);
    var x: usize = p.xmin + 1;
    while (x != p.xmax) {
        try writer.writeAll(sym.h_line);
        x += 1;
    }
    try writer.writeAll(sym.round_right_up);
    var y: usize = p.ymin + 1;
    while (y != p.ymax) {
        try moveCursor(writer, y, p.xmin);
        try writer.writeAll(sym.v_line);
        try moveCursor(writer, y, p.xmax);
        try writer.writeAll(sym.v_line);
        y += 1;
    }
    try moveCursor(writer, p.ymax, p.xmin);
    try writer.writeAll(sym.round_left_down);
    x = p.xmin + 1;
    while (x != p.xmax) {
        try writer.writeAll(sym.h_line);
        x += 1;
    }
    try writer.writeAll(sym.round_right_down);
}

fn formatTime(allocator: std.mem.Allocator, milli: u64) ![]const u8 {
    // Validate input - ensure we don't exceed reasonable time values
    if (milli > std.math.maxInt(u32) * 1000) {
        return error.TimeValueTooLarge;
    }

    const seconds = milli / 1000;
    const minutes = seconds / 60;
    const remainingSeconds = seconds % 60;

    // Format time string with proper error handling
    return std.fmt.allocPrint(
        allocator,
        "{d:0>2}:{d:0>2}",
        .{ minutes, remainingSeconds },
    );
}

//on loop it will have to change
fn currTrack(
    allocator: std.mem.Allocator,
    writer: fs.File.Writer,
    p: Panel,
    s: mpd.Song,
    t: mpd.Time,
    end_index: *usize,
) !void {
    const start = end_index.*;
    defer end_index.* = start;

    const xmin = p.xmin + 1;
    const xmax = p.xmax - 1;
    const ycent = p.getYCentre();
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

    const elapsedTime = try formatTime(allocator, t.elapsed);
    const duration = try formatTime(allocator, t.duration);
    const songTime = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ elapsedTime, duration });

    //Include co-ords in the panel drawing?
    try moveCursor(writer, ycent, xmin);
    try writer.writeAll(songTime);
    try writeLine(writer, artist, ycent, xmin, xmax);
    try writeLine(writer, trckalb, ycent - 2, xmin, xmax);

    // Draw progress bar
    try moveCursor(writer, ycent + 2, xmin);
    const progress_width = xmax - xmin;
    const progress_ratio = @as(f32, @floatFromInt(t.elapsed)) / @as(f32, @floatFromInt(t.duration));
    const filled_blocks = @as(usize, @intFromFloat(progress_ratio * @as(f32, @floatFromInt(progress_width))));

    var x: usize = 0;
    while (x <= progress_width) : (x += 1) {
        if (x < filled_blocks) {
            try writer.writeAll(full_block);
        } else {
            try writer.writeAll(light_shade);
        }
    }
}

fn writeLine(writer: anytype, txt: []const u8, y: usize, xmin: usize, xmax: usize) !void {
    const panel_width = xmax - xmin;
    const x_pos = xmin + (panel_width - txt.len) / 2;
    try moveCursor(writer, y, x_pos);
    try writer.writeAll(txt);
}

const Window = struct {
    xmin: usize,
    xmax: usize,
    ymin: usize,
    ymax: usize,
};

fn getWindow() !Window {
    var win_size = mem.zeroes(os.linux.winsize);
    const err = os.linux.ioctl(tty.handle, os.linux.T.IOCGWINSZ, @intFromPtr(&win_size));
    if (std.posix.errno(err) != .SUCCESS) {
        return std.posix.unexpectedErrno(os.linux.E.init(err));
    }
    return Window{
        .xmin = 0,
        .xmax = win_size.ws_col - 1, // Columns (width) minus 1 for zero-based indexing
        .ymin = 0,
        .ymax = win_size.ws_row - 1, // Rows (height) minus 1 for zero-based indexing
    };
}

const Panel = struct {
    xmin: usize,
    xmax: usize,
    ymin: usize,
    ymax: usize,

    fn getYCentre(self: Panel) usize {
        return self.ymin + (self.ymax - self.ymin) / 2;
    }

    fn getXCentre(self: Panel) usize {
        return self.xmin + (self.xmax - self.xmin) / 2;
    }
};

const Dim = struct {
    totalfr: u8,
    startline: u8,
    endline: u8,
};

fn getPanel(x: Dim, y: Dim) Panel {
    // Calculate fractions of total window dimensions
    const xfr = @as(f32, @floatFromInt(window.xmax + 1)) / @as(f32, @floatFromInt(x.totalfr));
    const yfr = @as(f32, @floatFromInt(window.ymax + 1)) / @as(f32, @floatFromInt(y.totalfr));

    // Calculate panel boundaries ensuring they stay within window limits
    const x_min = @min(window.xmax, @as(usize, @intFromFloat(@round(xfr * @as(f32, @floatFromInt(x.startline))))));
    const x_max = @min(window.xmax, @as(usize, @intFromFloat(@round(xfr * @as(f32, @floatFromInt(x.endline))))));
    const y_min = @min(window.ymax, @as(usize, @intFromFloat(@round(yfr * @as(f32, @floatFromInt(y.startline))))));
    const y_max = @min(window.ymax, @as(usize, @intFromFloat(@round(yfr * @as(f32, @floatFromInt(y.endline))))));

    return Panel{
        .xmin = x_min,
        .xmax = x_max,
        .ymin = y_min,
        .ymax = y_max,
    };
}
