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

var currSong = mpd.CurrentSong{};

var panelCurrSong: Panel = undefined;
var queue = mpd.Queue{};

var panelQueue: Panel = undefined;
var viewStartQ: usize = 0;
var viewEndQ: usize = undefined;
var cursorPosQ: u8 = 0;

var panelFind: Panel = undefined;
var typeBuffer: [256]u8 = undefined;
var typed: []const u8 = typeBuffer[0..0];

var firstRender: bool = true;
var renderState: RenderState = RenderState.init();

var isPlaying: bool = true;

const Input_State = enum {
    normal,
    typing,
};

var state_input = Input_State.normal;

pub fn main() !void {
    // var respArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer respArena.deinit();
    // const respAllocator = respArena.allocator();
    //
    // defer heapArena.deinit();
    // const heapAllocator = heapArena.allocator();
    // var heapArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    window = try getWindow();

    util.init() catch {};
    defer util.deinit() catch {};

    mpd.connect(wrkbuf[0..64], &mpd.cmdStream, false) catch {
        log("Unable to connect to MPD", .{});
        return;
    };
    defer mpd.disconnect(&mpd.cmdStream);

    mpd.connect(wrkbuf[0..64], &mpd.idleStream, true) catch |err| {
        log("Unable to connect to MPD: {}\n", .{err});
        return;
    };
    defer mpd.disconnect(&mpd.idleStream);

    tty = fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = .read_write },
    ) catch {
        log("could not find tty at /dev/tty", .{});
        return;
    };
    defer tty.close();

    _ = try std.posix.fcntl(tty.handle, os.linux.F.SETFL, os.linux.SOCK.NONBLOCK);

    uncook() catch {
        log("failed to uncook", .{});
        return;
    };
    defer cook() catch {};

    _ = currSong.init();
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

    _ = try mpd.getQueue(wrkallocator, &wrkfba.end_index, &queue);

    panelQueue = Panel.init(true, .{
        .totalfr = 7,
        .startline = 0,
        .endline = 4,
    }, .{
        .totalfr = 7,
        .startline = 2,
        .endline = 7,
    });
    viewEndQ = viewStartQ + panelQueue.validArea().ylen + 1;

    panelFind = Panel.init(true, .{
        .totalfr = 7,
        .startline = 4,
        .endline = 7,
    }, .{
        .totalfr = 7,
        .startline = 2,
        .endline = 7,
    });

    renderState.borders = true;
    renderState.queue = true;
    renderState.find = true;
    var last_render_time = time.milliTimestamp();
    var last_ping_time = time.milliTimestamp();

    _ = try mpd.initIdle();

    while (!quit) {
        defer wrkfba.reset();
        var inputBuffer: [1]u8 = undefined;
        const current_time = time.milliTimestamp();
        try checkInput(inputBuffer[0..]);

        // handle Idle update
        const idleRes = try mpd.checkIdle(wrkallocator, &wrkfba.end_index);
        if (idleRes == 1) {
            _ = currSong.init();
            _ = try mpd.getCurrentSong(wrkallocator, &wrkfba.end_index, &currSong);
            _ = try mpd.getCurrentTrackTime(wrkallocator, &wrkfba.end_index, &currSong);
            _ = try mpd.initIdle();
            renderState.queue = true;
        } else if (idleRes == 2) {
            queue = mpd.Queue{};
            _ = try mpd.getQueue(wrkallocator, &wrkfba.end_index, &queue);
            _ = try mpd.initIdle();
            renderState.queue = true;
        }

        if (isRenderTime(last_render_time, current_time)) {
            if (isPlaying) {
                currSong.time.elapsed += @intCast(current_time - last_render_time);
                renderState.currentTrack = true;
            }
            render(renderState, &wrkfba.end_index) catch |err| {
                log("Couldn't render {}", .{err});
                return;
            };
            renderState = RenderState.init();
            last_render_time = current_time;
        }

        if ((current_time - last_ping_time) >= 25 * 1000) {
            try mpd.checkConnection();
            last_ping_time = current_time;
        }
        time.sleep(time.ns_per_ms * 10);
    }
}

fn isRenderTime(last_render_time: i64, current_time: i64) bool {
    if ((current_time - last_render_time) >= 100) return true;
    return false;
}

fn checkInput(buffer: []u8) !void {
    const bytes_read: usize = tty.read(buffer) catch |err| switch (err) {
        error.WouldBlock => 0, // No input available
        else => |e| return e,
    };

    if (bytes_read < 1) return;

    const func = switch (state_input) {
        Input_State.normal => &inputNormal,
        Input_State.typing => &inputTyping,
    };

    try func(buffer);
}

fn inputTyping(buffer: []u8) !void {
    switch (buffer[0]) {
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try readEscapeCode(&escBuffer);

            if (escRead == 0) {
                typed = typeBuffer[0..0];
                renderState.borders = true;
                state_input = Input_State.normal;
                return;
            }
        },
        // '\r', '\n' => //add song from uri,
        else => {
            typeFind(buffer[0]);
            renderState.find = true;
        },
    }
}

fn inputNormal(buffer: []u8) !void {
    switch (buffer[0]) {
        'q' => quit = true,
        'j' => scrollQ(false),
        'k' => scrollQ(true),
        'p' => isPlaying = try mpd.togglePlaystate(isPlaying),
        'l' => try mpd.nextSong(),
        'h' => try mpd.prevSong(),
        'f' => {
            state_input = Input_State.typing;
            renderState.find = true;
        },
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try readEscapeCode(&escBuffer);

            if (escRead == 0) {
                log("input escape", .{});
                quit = true;
                return;
            }
            if (mem.eql(u8, escBuffer[0..escRead], "[A")) {
                log("input: arrow up\r\n", .{});
            } else if (mem.eql(u8, escBuffer[0..escRead], "[B")) {
                log("input: arrow down\r\n", .{});
            } else if (mem.eql(u8, escBuffer[0..escRead], "[C")) {
                try mpd.seekCur(true);
            } else if (mem.eql(u8, escBuffer[0..escRead], "[D")) {
                try mpd.seekCur(false);
            } else {
                log("unknown escape sequence", .{});
            }
        },
        '\n', '\r' => try mpd.playByPos(wrkallocator, cursorPosQ),
        else => log("input: {} {s}", .{ buffer[0], buffer }),
    }
}

fn readEscapeCode(buffer: []u8) !usize {
    raw.cc[@intFromEnum(os.linux.V.TIME)] = 1;
    raw.cc[@intFromEnum(os.linux.V.MIN)] = 0;
    _ = os.linux.tcsetattr(tty.handle, .NOW, &raw);

    const escRead = tty.read(buffer) catch |err| switch (err) {
        error.WouldBlock => 0, // No input available
        else => |e| return e,
    };

    raw.cc[@intFromEnum(os.linux.V.TIME)] = 0;
    raw.cc[@intFromEnum(os.linux.V.MIN)] = 1;
    _ = os.linux.tcsetattr(tty.handle, .NOW, &raw);

    return escRead;
}

fn typeFind(char: u8) void {
    typeBuffer[typed.len] = char;
    typed = typeBuffer[0 .. typed.len + 1];
}

fn getFindText() ![]const u8 {
    return switch (state_input) {
        Input_State.normal => "find",
        Input_State.typing => try std.fmt.allocPrint(wrkallocator, "find: {s}_", .{typed}),
    };
}

fn scrollQ(isUp: bool) void {
    if (isUp) {
        if (cursorPosQ == 0) return;
        cursorPosQ -= 1;
        if (cursorPosQ < viewStartQ) {
            viewStartQ = cursorPosQ;
            viewEndQ = viewStartQ + panelQueue.validArea().ylen + 1;
        }
    } else {
        if (cursorPosQ >= queue.len - 1) return;
        cursorPosQ += 1;
        if (cursorPosQ >= viewEndQ) {
            viewEndQ = cursorPosQ + 1;
            viewStartQ = viewEndQ - panelQueue.validArea().ylen - 1;
        }
    }
    renderState.queue = true;
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
    if (state.borders) try drawHeader(writer, panelQueue, "queue");
    if (state.borders) try drawBorders(writer, panelFind);
    if (state.borders or state.find) try drawHeader(writer, panelFind, try getFindText());
    if (state.currentTrack) try currTrackRender(wrkallocator, writer, panelCurrSong, currSong, end_index);
    if (state.queue) try queueRender(writer, wrkallocator, &wrkfba.end_index, panelQueue);
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

fn drawHeader(writer: fs.File.Writer, p: Panel, text: []const u8) !void {
    const x = p.xmin + 1;
    try moveCursor(writer, p.ymin, x);
    try writer.writeAll(sym.right_up);
    try writer.writeAll(text);
    try writer.writeAll(sym.left_up);
}

fn formatMilli(allocator: std.mem.Allocator, milli: u64) ![]const u8 {
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

fn formatSeconds(allocator: std.mem.Allocator, seconds: u64) ![]const u8 {
    const minutes = seconds / 60;
    const remainingSeconds = seconds % 60;

    return std.fmt.allocPrint(
        allocator,
        "{d:0>2}:{d:0>2}",
        .{ minutes, remainingSeconds },
    );
}

fn queueRender(writer: fs.File.Writer, allocator: std.mem.Allocator, end_index: *usize, panel: Panel) !void {
    const start = end_index.*;
    defer end_index.* = start;

    const area = panel.validArea();
    const n = area.xlen / 4; // idk why this looks good
    const gapcol = area.xlen / 8;

    var highlighted = false;
    for (viewStartQ..viewEndQ, 0..) |i, j| {
        if (i >= queue.len) break;
        if (queue.items[i].pos == cursorPosQ) {
            try writer.writeAll("\x1B[7m");
            highlighted = true;
        }
        const itemTime = try formatSeconds(allocator, queue.items[i].time);
        try moveCursor(writer, area.ymin + j, area.xmin);
        if ((currSong.id == queue.items[i].id) and !highlighted) try writer.writeAll("\x1B[33m");
        if (n > queue.items[i].title.len) {
            try writer.writeAll(queue.items[i].title);
            try writer.writeByteNTimes(' ', n - queue.items[i].title.len);
        } else {
            try writer.writeAll(queue.items[i].title[0..n]);
        }
        try writer.writeByteNTimes(' ', gapcol);
        if (n > queue.items[i].artist.len) {
            try writer.writeAll(queue.items[i].artist);
            try writer.writeByteNTimes(' ', n - queue.items[i].artist.len);
        } else {
            try writer.writeAll(queue.items[i].artist[0..n]);
        }
        try writer.writeByteNTimes(' ', area.xlen - 4 - gapcol - 2 * n);
        try moveCursor(writer, area.ymin + j, area.xmax - 4);
        try writer.writeAll(itemTime);
        if (highlighted) {
            try writer.writeAll("\x1B[0m");
            highlighted = false;
        }
        if (!highlighted and (queue.items[i].id == currSong.id)) try writer.writeAll("\x1B[0m");
    }
}

// fn scrollQ() !void {}
fn currTrackRender(
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
        try std.fmt.allocPrint(allocator, "{s} - \"{s}\" {s}.", .{
            s.title,
            s.album,
            s.trackno,
        });

    const elapsedTime = try formatMilli(allocator, s.time.elapsed);
    const duration = try formatMilli(allocator, s.time.duration);
    const songTime = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ elapsedTime, duration });

    //Include co-ords in the panel drawing?

    if (!firstRender) {
        try clearLine(writer, ycent, xmin, xmax);
        try clearLine(writer, ycent - 2, xmin, xmax);
    }
    try moveCursor(writer, ycent, xmin);
    try writer.writeAll(songTime);
    try writeLine(writer, s.artist, ycent, xmin, xmax);
    try writeLine(writer, trckalb, ycent - 2, xmin, xmax);
    if (firstRender) firstRender = false;

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

fn clearLine(writer: fs.File.Writer, y: usize, xmin: usize, xmax: usize) !void {
    try moveCursor(writer, y, xmin);
    const width = xmax - xmin + 1;
    try writer.writeByteNTimes(' ', width);
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
    find: bool,

    fn init() RenderState {
        return .{
            .borders = false,
            .currentTrack = false,
            .queue = false,
            .find = false,
        };
    }
};

const Panel = struct {
    borders: bool,
    xmin: usize,
    xmax: usize,
    ymin: usize,
    ymax: usize,
    xlen: usize,
    ylen: usize,

    fn init(borders: bool, x: Dim, y: Dim) Panel {
        // Calculate fractions of total window dimensions
        const xfr = @as(f32, @floatFromInt(window.xmax + 1)) / @as(f32, @floatFromInt(x.totalfr));
        const yfr = @as(f32, @floatFromInt(window.ymax + 1)) / @as(f32, @floatFromInt(y.totalfr));

        // Calculate panel boundaries ensuring they stay within window limits
        const x_min = @min(window.xmax, @as(usize, @intFromFloat(@round(xfr * @as(f32, @floatFromInt(x.startline))))));
        const x_max = @min(window.xmax, @as(usize, @intFromFloat(@round(xfr * @as(f32, @floatFromInt(x.endline))))));
        const x_len = x_max - x_min;
        const y_min = @min(window.ymax, @as(usize, @intFromFloat(@round(yfr * @as(f32, @floatFromInt(y.startline))))));
        const y_max = @min(window.ymax, @as(usize, @intFromFloat(@round(yfr * @as(f32, @floatFromInt(y.endline))))));
        const y_len = y_max - y_min;

        return Panel{
            .borders = borders,
            .xmin = x_min,
            .xmax = x_max,
            .ymin = y_min,
            .ymax = y_max,
            .xlen = x_len,
            .ylen = y_len,
        };
    }

    fn validArea(self: Panel) struct {
        xmin: usize,
        xmax: usize,
        xlen: usize,
        ymin: usize,
        ymax: usize,
        ylen: usize,
    } {
        if (self.borders) {
            return .{
                .xmin = self.xmin + 1,
                .xmax = self.xmax - 1,
                .ymin = self.ymin + 1,
                .ymax = self.ymax - 1,
                .xlen = self.xlen - 2,
                .ylen = self.ylen - 2,
            };
        } else {
            return .{
                .xmin = self.xmin,
                .xmax = self.xmax,
                .ymin = self.ymin,
                .ymax = self.ymax,
                .xlen = self.xlen,
                .ylen = self.ylen,
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
