const std = @import("std");
const sym = @import("symbols.zig");
const util = @import("util.zig");
const mpd = @import("mpdclient.zig");
const algo = @import("algo.zig");
const window = @import("window.zig");
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
var raw: os.linux.termios = undefined;
var cooked: os.linux.termios = undefined;
var quit: bool = false;

var wrkbuf: [4096]u8 = undefined;
var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
const wrkallocator = wrkfba.allocator();

var algoArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const algoArenaAllocator = algoArena.allocator();

var respArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const respAllocator = respArena.allocator();

var persistentArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const persistentAllocator = persistentArena.allocator();

var typingArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const typingAllocator = typingArena.allocator();

var all_searchable: []mpd.Searchable = undefined;
var viewable_searchable: ?[]mpd.Searchable = null;

var currSong = mpd.CurrentSong{};

var panelCurrSong: window.Panel = undefined;
var queue = mpd.Queue{};

var panelQueue: window.Panel = undefined;
var viewStartQ: usize = 0;
var viewEndQ: usize = undefined;
var cursorPosQ: u8 = 0;

var panelFind: window.Panel = undefined;
var typeBuffer: [256]u8 = undefined;
var typed: []const u8 = typeBuffer[0..0];
var findSelected: u8 = 0;

var firstRender: bool = true;
var renderState: RenderState = RenderState.init();

var isPlaying: bool = true;

const Input_State = enum {
    normal,
    typing,
};

var state_input = Input_State.normal;

pub fn main() !void {
    defer typingArena.deinit();
    defer algoArena.deinit();

    try window.getWindow(&tty);

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

    panelCurrSong = window.Panel.init(true, .{
        .absolute = .{
            .min = window.window.xmin,
            .max = window.window.xmax,
        },
    }, .{ .absolute = .{ .min = 0, .max = 6 } });

    _ = try mpd.getQueue(wrkallocator, &wrkfba.end_index, &queue);

    panelQueue = window.Panel.init(
        true,
        .{ .fractional = .{
            .totalfr = 7,
            .startline = 0,
            .endline = 4,
        } },
        .{ .absolute = .{
            .min = 7,
            .max = window.window.ymax,
        } },
    );

    viewEndQ = viewStartQ + panelQueue.validArea().ylen + 1;

    panelFind = window.Panel.init(
        true,
        .{ .fractional = .{
            .totalfr = 7,
            .startline = 4,
            .endline = 7,
        } },
        .{ .absolute = .{
            .min = 7,
            .max = window.window.ymax,
        } },
    );
    algo.nRanked = panelFind.validArea().ylen;

    _ = try mpd.initIdle();

    all_searchable = try mpd.getSearchable(persistentAllocator, respAllocator);
    algo.pointerToAll = &all_searchable;
    algo.resetItems();
    log("allsearchable len: {}", .{all_searchable.len});
    respArena.deinit();

    renderState.borders = true;
    renderState.queue = true;
    renderState.find = true;
    var last_render_time = time.milliTimestamp();
    var last_ping_time = time.milliTimestamp();

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
                renderState.find = true;
                viewable_searchable = null;
                state_input = Input_State.normal;
                findSelected = 0;
                algo.resetItems();
                _ = typingArena.reset(.free_all);
                _ = algoArena.reset(.free_all);
                log("all items: {}\n", .{all_searchable.len});
                log("\narena state: {} \n", .{algoArena.state.end_index});
                log("\nlong state: {} \n", .{typingArena.state.end_index});
                return;
            }
        },
        'n' & '\x1F' => {
            log("input: Ctrl-n\r\n", .{});
            if (findSelected < 9) {
                findSelected += 1;
            }
            renderState.find = true;
            return;
        },
        'p' & '\x1F' => {
            log("input: Ctrl-p\r\n", .{});
            if (findSelected > 0) {
                findSelected -= 1;
            }
            renderState.find = true;
            return;
        },
        '\r', '\n' => {
            //add song from uri
            const addUri = viewable_searchable.?[findSelected].uri;
            log("uri: {s}", .{addUri});
            try mpd.addFromUri(wrkallocator, addUri);
            typed = typeBuffer[0..0];
            renderState.borders = true;
            renderState.find = true;
            renderState.queue = true;
            viewable_searchable = null;
            state_input = Input_State.normal;
            findSelected = 0;
            algo.resetItems();
            _ = typingArena.reset(.free_all);
            _ = algoArena.reset(.free_all);
            log("all items: {}\n", .{all_searchable.len});
            log("\narena state: {} \n", .{algoArena.state.end_index});
            log("\nlong state: {} \n", .{typingArena.state.end_index});
            return;
        },
        else => {
            typeFind(buffer[0]);
            const slice = try algo.algorithm(&algoArena, typingAllocator, typed[0..]);
            viewable_searchable = slice[0..];
            // log("viewable 1: {}\n", .{viewable_searchable.?.len});
            renderState.find = true;
            return;
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
            renderState.queue = true;
        },
        'x' => {
            try mpd.rmFromPos(wrkallocator, cursorPosQ);
            if (cursorPosQ == 0) {
                if (queue.len > 1) return;
            }
            cursorPosQ -= 1;
        },
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try readEscapeCode(&escBuffer);

            if (escRead == 0) {
                // log("input escape", .{});
                quit = true;
                return;
            }
            if (mem.eql(u8, escBuffer[0..escRead], "[A")) {
                // log("input: arrow up\r\n", .{});
            } else if (mem.eql(u8, escBuffer[0..escRead], "[B")) {
                // log("input: arrow down\r\n", .{});
            } else if (mem.eql(u8, escBuffer[0..escRead], "[C")) {
                try mpd.seekCur(true);
            } else if (mem.eql(u8, escBuffer[0..escRead], "[D")) {
                try mpd.seekCur(false);
            } else {
                log("unknown escape sequence", .{});
            }
        },
        '\n', '\r' => {
            try mpd.playByPos(wrkallocator, cursorPosQ);
            if (!isPlaying) isPlaying = true;
        },
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

fn findRender(writer: std.fs.File.Writer, panel: window.Panel) !void {
    const area = panel.validArea();

    if (viewable_searchable) |viewable| {
        for (0..area.ylen) |i| {
            try moveCursor(writer, area.ymin + i, area.xmin);
            try writer.writeByteNTimes(' ', area.xlen);
        }
        for (viewable, 0..) |song, j| {
            const len = if (song.string.?.len > area.xlen) area.xlen else song.string.?.len;
            if (j == findSelected) try writer.writeAll("\x1B[7m");
            try moveCursor(writer, area.ymin + j, area.xmin);
            try writer.writeAll(song.string.?[0..len]);
            if (j == findSelected) try writer.writeAll("\x1B[0m");
        }
    } else {
        for (0..area.ylen) |i| {
            try moveCursor(writer, area.ymin + i, area.xmin);
            try writer.writeByteNTimes(' ', area.xlen);
        }
    }
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
    if (state.find) findRender(writer, panelFind) catch |err| log("Error: {}", .{err});
}

fn drawBorders(writer: fs.File.Writer, p: window.Panel) !void {
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

fn drawHeader(writer: fs.File.Writer, p: window.Panel, text: []const u8) !void {
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

fn queueRender(writer: fs.File.Writer, allocator: std.mem.Allocator, end_index: *usize, panel: window.Panel) !void {
    const start = end_index.*;
    defer end_index.* = start;

    const area = panel.validArea();
    const n = area.xlen / 4; // idk why this looks good
    const gapcol = area.xlen / 8;

    for (0..area.ylen) |i| {
        try moveCursor(writer, area.ymin + i, area.xmin);
        try writer.writeByteNTimes(' ', area.xlen);
    }

    var highlighted = false;
    for (viewStartQ..viewEndQ, 0..) |i, j| {
        if (i >= queue.len) break;
        if (queue.items[i].pos == cursorPosQ and state_input == .normal) {
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
    p: window.Panel,
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
