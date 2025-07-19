const std = @import("std");
const Allocator = std.mem.Allocator;
const DisplayWidth = @import("DisplayWidth");
const CodePointIterator = @import("code_point").Iterator;
const ascii = @import("ascii");

const util = @import("util.zig");
const Panels = @import("window.zig").Panels;
const FixedString = @import("render.zig").FixedString;
const pers_alloc = @import("allocators.zig").persistentAllocator;

const queue_cache_size = 100;
const playing_cache_size = 20;

var dw: DisplayWidth = undefined;
var cache: Cache = undefined;

pub const Width = struct {
    byte_offset: usize,
    cells: usize,
};

const Which_Cache = enum {
    queue,
    col1,
    col2,
    col3,
    playing,
};

const Cache = struct {
    queue: HashQueue(queue_cache_size),
    qw: usize,
    col1: HashQueue(queue_cache_size),
    c1w: usize,
    col2: HashQueue(queue_cache_size),
    c2w: usize,
    col3: HashQueue(queue_cache_size),
    c3w: usize,
    playing: HashQueue(playing_cache_size),
    pw: usize,

    fn init(allocator: Allocator, panels: Panels) Cache {
        return Cache{
            .queue = HashQueue(queue_cache_size).init(allocator),
            .qw = panels.queue.validArea().xlen / 4,
            .col1 = HashQueue(queue_cache_size).init(allocator),
            .c1w = panels.browse1.validArea().xlen,
            .col2 = HashQueue(queue_cache_size).init(allocator),
            .c2w = panels.browse2.validArea().xlen,
            .col3 = HashQueue(queue_cache_size).init(allocator),
            .c3w = panels.browse3.validArea().xlen,
            .playing = HashQueue(playing_cache_size).init(allocator),
            .pw = panels.curr_song.validArea().xlen,
        };
    }
};

fn getWidthFromCache(
    comptime capacity: usize,
    hash_queue: *HashQueue(capacity),
    max_width: usize,
    str: []const u8,
) !Width {
    if (hash_queue.contains(str)) return hash_queue.get(str) orelse return error.CacheError;
    const w: Width = lookupWidth(max_width, str);
    try hash_queue.put(str, w);
    return w;
}

pub fn getDisplayWidth(str: []const u8, cache_type: Which_Cache) !Width {
    return switch (cache_type) {
        .queue => getWidthFromCache(queue_cache_size, &cache.queue, cache.qw, str),
        .col1 => getWidthFromCache(queue_cache_size, &cache.col1, cache.c1w, str),
        .col2 => getWidthFromCache(queue_cache_size, &cache.col2, cache.c2w, str),
        .col3 => getWidthFromCache(queue_cache_size, &cache.col3, cache.c3w, str),
        .playing => getWidthFromCache(playing_cache_size, &cache.playing, cache.pw, str),
    };
}

fn HashQueue(n_str: usize) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        strings: [n_str]FixedString,
        map: std.hash_map.StringHashMap(Width),
        start: usize = 0,
        len: usize = 0,
        max_size: usize,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .strings = undefined, // Buffers are set during put
                .map = std.hash_map.StringHashMap(Width).init(allocator),
                .start = 0,
                .len = 0,
                .max_size = n_str,
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        pub fn put(self: *Self, key: []const u8, value: Width) !void {
            if (self.map.contains(key)) {
                // Update existing value
                if (key.len > FixedString.MAX_LEN) {
                    try self.map.put(key[0..FixedString.MAX_LEN], value);
                } else {
                    try self.map.put(key, value);
                }
            } else {
                // Insert new key-value pair
                if (self.len == self.max_size) {
                    // Remove oldest
                    const oldest_idx = self.start;
                    const oldest_key = self.strings[oldest_idx].slice;
                    _ = self.map.remove(oldest_key);
                    self.start = (self.start + 1) % self.max_size;
                    self.len -= 1;
                }
                // Add new key at the end
                const idx = (self.start + self.len) % self.max_size;
                const owned_key = self.strings[idx].set(key);
                try self.map.put(owned_key, value);
                self.len += 1;
            }
        }

        pub fn get(self: *Self, key: []const u8) ?Width {
            if (key.len > FixedString.MAX_LEN) {
                return self.map.get(key[0..FixedString.MAX_LEN]);
            } else {
                return self.map.get(key);
            }
        }

        pub fn contains(self: *Self, key: []const u8) bool {
            return if (key.len > FixedString.MAX_LEN)
                self.map.contains(key[0..FixedString.MAX_LEN])
            else
                self.map.contains(key);
        }
    };
}

pub fn init(alloc: Allocator, panels: Panels) !void {
    dw = try DisplayWidth.init(alloc);
    cache = Cache.init(alloc, panels);
}

pub fn deinit(alloc: Allocator) void {
    dw.deinit(alloc);
}

fn lookupWidth(max: usize, str: []const u8) Width {
    var width_total: isize = 0;

    // ASCII fast path
    if (ascii.isAsciiOnly(str)) {
        if (str.len < max) {
            return .{
                .byte_offset = str.len,
                .cells = str.len,
            };
        }
        return .{
            .byte_offset = max,
            .cells = max,
        };
    }

    var giter = dw.graphemes.iterator(str);
    var offset: usize = 0;
    while (giter.next()) |gc| {
        var cp_iter = CodePointIterator{ .bytes = gc.bytes(str) };
        var gc_total: isize = 0;

        while (cp_iter.next()) |cp| {
            var w = dw.codePointWidth(cp.code);

            if (w != 0) {
                // Handle text emoji sequence.
                if (cp_iter.next()) |ncp| {
                    // emoji text sequence.
                    if (ncp.code == 0xFE0E) w = 1;
                    if (ncp.code == 0xFE0F) w = 2;
                }

                // Only adding width of first non-zero-width code point.
                if (gc_total == 0) {
                    gc_total = w;
                    break;
                }
            }
        }

        if (width_total + gc_total > max) return .{
            .byte_offset = offset,
            .cells = @intCast(@max(0, width_total)),
        };

        width_total += gc_total;
        offset = gc.offset + gc.len;
    }

    return .{
        .byte_offset = offset,
        .cells = @intCast(@max(0, width_total)),
    };
}

test "display width" {
    try util.loggerInit();
    try init(pers_alloc);
    // defer util.deinit() catch {};

    const string = "작은 것들을 위한 시 (Boy With Luv)";
    // const string = "ペルソナ3 オリジナル･サウンドトラック";
    const width = dw.strWidth(string);
    const zeroes = [_]u8{'0'} ** 1024;
    util.log("", .{});
    util.log("Width: {}\nString:\n{s}\n{s}", .{ width, string, zeroes[0..width] });
}

test "fitting bytes" {
    // try util.loggerInit();
    // defer util.deinit() catch {};
    try init(pers_alloc);

    const string = "작은 것들을 위한 시 (Boy With Luv)";
    // const string = "ペルソナ3 オリジナル･サウンドトラック";
    const zeroes = [_]u8{'0'} ** 1024;
    const s = lookupWidth(dw, 11, string);
    const offset = s[0];
    util.log("Max: 11\nString:\n{s}\n{s}", .{ string[0..offset], zeroes[0..11] });
    util.log("display width: {}", .{s[1]});
}
