const std = @import("std");
const term = @import("terminal.zig");
const mpd = @import("mpdclient.zig");
const algo = @import("algo.zig");
const state = @import("state.zig");
const alloc = @import("allocators.zig");
const window = @import("window.zig");
const mem = std.mem;
const time = std.time;
const assert = std.debug.assert;
const RenderState = @import("render.zig").RenderState;

const log = @import("util.zig").log;
const wrkallocator = alloc.wrkallocator;

var app: *state.State = undefined;
var render_state: *RenderState = undefined;
var current: state.State = undefined;
pub var data: state.Data = undefined;

var last_input: i64 = 0;

pub var scroll_threshold: f16 = 0.2;
pub var min_scroll: u8 = 0;
pub var max_scroll: u8 = undefined;

pub const Input_State = enum {
    normal_queue,
    typing_find,
    normal_browse,
    typing_browse,
};

pub const cursorDirection = enum {
    up,
    down,
};

pub fn checkInputEvent(buffer: []u8) !?state.Event {
    assert(buffer.len == 1);
    const bytes_read: usize = try term.readBytes(buffer);
    if (bytes_read < 1) return null;

    return state.Event{ .input_char = buffer[0] };
}

pub fn handleInput(char: u8, app_state: *state.State, render_state_: *RenderState) void {
    app = app_state;
    current = app_state.*;
    render_state = render_state_;
    switch (app_state.input_state) {
        .normal_queue => {
            normalQueue(char) catch unreachable;
        },
        .typing_find => {
            typingFind(char) catch unreachable;
        },
        .normal_browse => {
            normalBrowse(char) catch unreachable;
        },
        else => unreachable,
    }
}

fn onTypingExit() void {
    app.typing_display.reset();
    render_state.borders = true;
    render_state.find = true;
    render_state.queueEffects = true;
    app.viewable_searchable = null;
    app.input_state = .normal_queue;
    app.find_cursor_pos = 0;
    algo.resetItems();
    _ = alloc.typingArena.reset(.retain_capacity);
    _ = alloc.algoArena.reset(.free_all);
}

fn typingFind(char: u8) !void {
    switch (char) {
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                onTypingExit();
                return;
            }
        },
        'n' & '\x1F' => {
            log("input: Ctrl-n\r\n", .{});
            scroll(&app.find_cursor_pos, current.viewable_searchable.?.len - 1, .down);
            render_state.find = true;
        },
        'p' & '\x1F' => {
            log("input: Ctrl-p\r\n", .{});
            scroll(&app.find_cursor_pos, null, .up);
            render_state.find = true;
        },
        '\r', '\n' => {
            const addUri = current.viewable_searchable.?[current.find_cursor_pos].uri;
            try mpd.addFromUri(wrkallocator, addUri);
            log("added: {s}", .{addUri});
            onTypingExit();
            return;
        },
        else => {
            typeFind(char);
            log("typed: {s}\n", .{app.typing_display.typed});
            const slice = try algo.algorithm(&alloc.algoArena, alloc.typingAllocator, app.typing_display.typed);
            app.viewable_searchable = slice[0..];
            log("viewable string: {s}\n", .{slice[0].string.?});
            render_state.find = true;
            return;
        },
    }
}

fn normalQueue(char: u8) !void {
    switch (char) {
        'q' => app.quit = true,
        'j' => scrollQ(false),
        'k' => scrollQ(true),
        'p' => {
            if (debounce()) return;
            app.isPlaying = try mpd.togglePlaystate(current.isPlaying);
        },
        'l' => {
            if (debounce()) return;
            try mpd.nextSong();
        },
        'h' => {
            if (debounce()) return;
            try mpd.prevSong();
        },
        'f' => {
            app.input_state = .typing_find;
            render_state.find = true;
            render_state.queue = true;
        },
        'b' => {
            app.input_state = .normal_browse;
            render_state.find = true;
            render_state.browse_one = true;
            render_state.browse_cursor_one = true;
            render_state.browse_two = true;
            render_state.queue = true;
        },
        'x' => {
            if (debounce()) return;
            try mpd.rmFromPos(wrkallocator, current.cursorPosQ);
            if (current.cursorPosQ == 0) {
                if (current.queue.len > 1) return;
            }
            moveCursorPos(&app.cursorPosQ, &app.prevCursorPos, .down);
        },
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                app.quit = true;
                return;
            }
            if (mem.eql(u8, escBuffer[0..escRead], "[A")) {
                // log("input: arrow up\r\n", .{});
            } else if (mem.eql(u8, escBuffer[0..escRead], "[B")) {
                // log("input: arrow down\r\n", .{});
            } else if (mem.eql(u8, escBuffer[0..escRead], "[C")) {
                if (debounce()) return;
                try mpd.seekCur(true);
            } else if (mem.eql(u8, escBuffer[0..escRead], "[D")) {
                if (debounce()) return;
                try mpd.seekCur(false);
            } else {
                log("unknown escape sequence", .{});
            }
        },
        '\n', '\r' => {
            if (debounce()) return;
            try mpd.playByPos(wrkallocator, current.cursorPosQ);
            if (!current.isPlaying) app.isPlaying = true;
        },
        else => log("input: {c}", .{char}),
    }
}

fn normalBrowse(char: u8) !void {
    switch (char) {
        'q' => app.quit = true,
        '\x1B' => {
            var escBuffer: [8]u8 = undefined;
            const escRead = try term.readEscapeCode(&escBuffer);

            if (escRead == 0) {
                // render_state.borders = true;
                // render_state.find = true;
                render_state.queueEffects = true;
                app.input_state = .normal_queue;
                app.find_cursor_pos = 0;
            }
        },
        'j' => {
            switch (app.selected_column) {
                .one => {
                    const max: u8 = @intCast(@min(window.panels.browse1.validArea().ylen, app.column_1.displaying.len));
                    app.column_1.scroll(.down, max);
                    app.column_2.displaying = switch (app.column_1.pos) {
                        0 => data.albums,
                        1 => data.artists,
                        2 => data.songs,
                        else => unreachable,
                    };
                    render_state.browse_one = true;
                    render_state.browse_cursor_one = true;
                    render_state.browse_two = true;
                },
                .two => {},
                .three => {},
            }
        },
        'k' => {
            switch (current.selected_column) {
                .one => {
                    app.column_1.scroll(.up, 0);
                    app.column_2.displaying = switch (app.column_1.pos) {
                        0 => data.albums,
                        1 => data.artists,
                        2 => data.songs,
                        else => unreachable,
                    };
                    render_state.browse_one = true;
                    render_state.browse_cursor_one = true;
                    render_state.browse_two = true;
                },
                .two => {},
                .three => {},
            }
        },
        '\n', '\r' => {
            // switch (current.selected_column) {
            //     .one => {
            //         app.selected_column = .two;
            //     },
            //     .two => .three,
            //     .three => .one,
            // }
        },
        else => unreachable,
    }
}

fn debounce() bool {
    //input debounce
    const current_time = time.milliTimestamp();
    const diff = current_time - last_input;
    if (diff < 300) {
        return true;
    }
    last_input = current_time;
    return false;
}

fn typeFind(char: u8) void {
    app.typing_display.typeBuffer[current.typing_display.typed.len] = char;
    app.typing_display.typed = app.typing_display.typeBuffer[0 .. current.typing_display.typed.len + 1];
}

pub fn scrollQ(isUp: bool) void {
    if (isUp) {
        if (current.cursorPosQ == 0) return;
        moveCursorPos(&app.cursorPosQ, &app.prevCursorPos, .down);
        if (current.cursorPosQ < current.viewStartQ) {
            app.viewStartQ = current.cursorPosQ;
            app.viewEndQ = app.viewStartQ + window.panels.queue.validArea().ylen + 1;
        }
    } else {
        if (current.cursorPosQ >= current.queue.len - 1) return;
        moveCursorPos(&app.cursorPosQ, &app.prevCursorPos, .up);
        if (current.cursorPosQ >= current.viewEndQ) {
            app.viewEndQ = current.cursorPosQ + 1;
            app.viewStartQ = app.viewEndQ - window.panels.queue.validArea().ylen - 1;
        }
    }
    render_state.queueEffects = true;
}
fn moveCursorPos(current_dir: *u8, previous_dir: *u8, direction: cursorDirection) void {
    switch (direction) {
        .up => {
            previous_dir.* = current_dir.*;
            current_dir.* += 1;
        },
        .down => {
            previous_dir.* = current_dir.*;
            current_dir.* -= 1;
        },
    }
}

fn scroll(cursor_pos: *u8, max: ?usize, dir: cursorDirection) void {
    switch (dir) {
        .up => {
            if (cursor_pos.* > 0) {
                cursor_pos.* -= 1;
            }
        },
        .down => {
            if (cursor_pos.* < max.?) {
                cursor_pos.* += 1;
            }
        },
    }
}
