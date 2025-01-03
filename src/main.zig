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

var wrkbuf: [4096]u8 = undefined;
var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
const wrkallocator = wrkfba.allocator();

var currSong: mpd.CurrentSong = undefined;
var panelCurrSong: Panel = undefined;
var queue: mpd.Queue = undefined;
var panelQueue: Panel = undefined;

var renderState: RenderState = RenderState.init();

pub fn main() !void {
    window = try getWindow();

    util.init() catch {};
    defer util.deinit() catch {};

    mpd.connect(wrkbuf[0..64]) catch {
        log("Unable to connect to MPD", .{});
        return;
    };
    defer mpd.disconnect();

    tty = fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = .read_write },
    ) catch {
        log("could not find tty at /dev/tty", .{});
        return;
    };
    defer tty.close();

    uncook() catch {
        log("failed to uncook", .{});
        return;
    };
    defer cook() catch {};

    currSong = mpd.CurrentSong.init();

    _ = try mpd.getCurrentSong(wrkallocator, &wrkfba.end_index, &currSong);
    _ = try mpd.getCurrentTrackTime(wrkallocator, &wrkfba.end_index, &currSong);

    panelCurrSong = Panel.init(
        true,
        .{
            .totalfr = 6,
            .startline = 1,
            .endline = 5,
        },
        .{
            .totalfr = 7,
            .startline = 0,
            .endline = 1,
        },
    );

    panelQueue = Panel.init(true, .{
        .totalfr = 7,
        .startline = 2,
        .endline = 5,
    }, .{
        .totalfr = 7,
        .startline = 2,
        .endline = 5,
    });

    renderState.borders = true;
    renderState.queue = true;
    var last_render_time = time.milliTimestamp();

    while (quit != true) {
        const current_time = time.milliTimestamp();
        try checkInput();
        if (isRenderTime(last_render_time, current_time)) {
            currSong.time.elapsed += @intCast(current_time - last_render_time);
            renderState.currentTrack = true;
            render(renderState, &wrkfba.end_index) catch |err| {
                log("Couldn't render {}", .{err});
                return;
            };
            renderState = RenderState.init();
            last_render_time = current_time;
        }
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

fn render(state: RenderState, end_index: *usize) !void {
    const writer = tty.writer();
    if (state.borders) try drawBorders(writer, panelCurrSong);
    if (state.borders) try drawBorders(writer, panelQueue);
    if (state.borders) try drawHeader(writer, panelQueue);
    if (state.currentTrack) try currTrack(wrkallocator, writer, panelCurrSong, currSong, end_index);
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

fn drawHeader(writer: fs.File.Writer, p: Panel) !void {
    const x = p.xmin + 1;
    try moveCursor(writer, p.ymin, x);
    try writer.writeAll(sym.right_up);
    try writer.writeAll("Queue");
    try writer.writeAll(sym.left_up);
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

// fn queueRender(writer: fs.File.Writer, panel: Panel, queue: mpd.Queue) !void {
// }

fn currTrack(
    allocator: std.mem.Allocator,
    writer: fs.File.Writer,
    p: Panel,
    s: mpd.CurrentSong,
    end_index: *usize,
) !void {
    const start = end_index.*;
    defer end_index.* = start;

    const area = p.validArea();

    const xmin = area.xmin;
    const xmax = area.xmax;
    const ycent = p.getYCentre();
    const full_block = "\xe2\x96\x88"; // Unicode escape sequence for '█' (U+2588)
    const light_shade = "\xe2\x96\x92"; // Unicode escape sequence for '▒' (U+2592)

    const has_album = s.album.len > 0;
    const has_trackno = s.trackno.len > 0;

    const trckalb = if (!has_album)
        try std.fmt.allocPrint(allocator, "{s}", .{s.title})
    else if (!has_trackno)
        try std.fmt.allocPrint(allocator, "{s} - {s}", .{
            s.title,
            s.album,
        })
    else
        try std.fmt.allocPrint(allocator, "{s} - {s} - {s}", .{
            s.title,
            s.album,
            s.trackno,
        });

    const elapsedTime = try formatTime(allocator, s.time.elapsed);
    const duration = try formatTime(allocator, s.time.duration);
    const songTime = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ elapsedTime, duration });

    //Include co-ords in the panel drawing?
    try moveCursor(writer, ycent, xmin);
    try writer.writeAll(songTime);
    try writeLine(writer, s.artist, ycent, xmin, xmax);
    try writeLine(writer, trckalb, ycent - 2, xmin, xmax);

    // Draw progress bar
    try moveCursor(writer, ycent + 2, xmin);
    const progress_width = xmax - xmin;
    const progress_ratio = @as(f32, @floatFromInt(s.time.elapsed)) / @as(f32, @floatFromInt(s.time.duration));
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

const RenderState = struct {
    borders: bool,
    currentTrack: bool,
    queue: bool,

    fn init() RenderState {
        return .{
            .borders = false,
            .currentTrack = false,
            .queue = false,
        };
    }
};

const Panel = struct {
    borders: bool,
    xmin: usize,
    xmax: usize,
    ymin: usize,
    ymax: usize,

    fn init(borders: bool, x: Dim, y: Dim) Panel {
        // Calculate fractions of total window dimensions
        const xfr = @as(f32, @floatFromInt(window.xmax + 1)) / @as(f32, @floatFromInt(x.totalfr));
        const yfr = @as(f32, @floatFromInt(window.ymax + 1)) / @as(f32, @floatFromInt(y.totalfr));

        // Calculate panel boundaries ensuring they stay within window limits
        const x_min = @min(window.xmax, @as(usize, @intFromFloat(@round(xfr * @as(f32, @floatFromInt(x.startline))))));
        const x_max = @min(window.xmax, @as(usize, @intFromFloat(@round(xfr * @as(f32, @floatFromInt(x.endline))))));
        const y_min = @min(window.ymax, @as(usize, @intFromFloat(@round(yfr * @as(f32, @floatFromInt(y.startline))))));
        const y_max = @min(window.ymax, @as(usize, @intFromFloat(@round(yfr * @as(f32, @floatFromInt(y.endline))))));

        return Panel{
            .borders = borders,
            .xmin = x_min,
            .xmax = x_max,
            .ymin = y_min,
            .ymax = y_max,
        };
    }

    fn validArea(self: Panel) struct { xmin: usize, xmax: usize, ymin: usize, ymax: usize } {
        if (self.borders) {
            return .{
                .xmin = self.xmin + 1,
                .xmax = self.xmax - 1,
                .ymin = self.ymin + 1,
                .ymax = self.ymax - 1,
            };
        } else {
            return .{
                .xmin = self.xmin,
                .xmax = self.xmax,
                .ymin = self.ymin,
                .ymax = self.ymax,
            };
        }
    }

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
