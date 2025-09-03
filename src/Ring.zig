const std = @import("std");
const mem = std.mem;
const debug = std.debug;

fn Buffer(size: usize, T: type) type {
    return struct {
        const Self = @This();
        buf: []T,
        first: usize,
        stop: usize,
        fill: usize,
        items: Iterator,

        const Iterator = struct {
            buf: [*]const T,
            index: usize,
            remaining: usize,

            pub fn next(self: *Iterator) ?T {
                if (self.remaining == 0) return null;
                const value = self.buf[self.index];
                self.index = (self.index + 1) % size;
                self.remaining -= 1;
                return value;
            }
        };

        fn init(allocator: mem.Allocator) !Self {
            const buf = try allocator.alloc(T, size);
            return .{
                .buf = buf,
                .first = 0,
                .stop = 0,
                .fill = 0,
                .items = Iterator{
                    .buf = buf.ptr,
                    .index = 0,
                    .remaining = 0,
                },
            };
        }

        fn forwardWrite(self: *Self, src: []const T) void {
            debug.assert(src.len <= size);
            const rest = size - self.stop;
            if (src.len <= rest) {
                @memcpy(self.buf[self.stop .. self.stop + src.len], src);
            } else {
                @memcpy(self.buf[self.stop..size], src[0..rest]);
                @memcpy(self.buf[0 .. src.len - rest], src[rest..]);
            }
            self.stop = (self.stop + src.len) % size;

            self.fill += src.len;
            if (self.fill > size) {
                self.first = (self.first + (self.fill - size)) % size;
                self.fill = size;
            }

            self.items.index = self.first;
            self.items.remaining = self.fill;
        }

        fn backwardWrite(self: *Self, src: []const T) void {
            debug.assert(src.len <= size);
            const start: usize = (self.first + size - src.len) % size;
            if (src.len <= self.first) {
                @memcpy(self.buf[start..self.first], src);
            } else {
                const tail_len = size - start;
                @memcpy(self.buf[start..size], src[0..tail_len]);
                const head_len = src.len - tail_len;
                @memcpy(self.buf[0..head_len], src[tail_len..]);
            }
            self.first = start;

            self.fill += src.len;
            if (self.fill > size) {
                const overflow = self.fill - size;
                self.stop = (self.stop + size - overflow) % size;
                self.fill = size;
            }

            self.items.index = self.first;
            self.items.remaining = self.fill;
        }
    };
}

fn StrBuffer(size: usize, max_str: usize) type {
    const T = [32:0]u8;
    return struct {
        const Self = @This();
        buf: []T,
        first: usize,
        stop: usize,
        fill: usize,
        items: Iterator,

        const Iterator = struct {
            buf: [*]const T,
            index: usize,
            remaining: usize,

            pub fn next(self: *Iterator) ?[]const u8 {
                if (self.remaining == 0) return null;
                const ptr: [*:0]const u8 = @ptrCast(&self.buf[self.index]);
                const value = mem.span(ptr); // Computes length up to null terminator.
                self.index = (self.index + 1) % size;
                self.remaining -= 1;
                return value;
            }
        };

        pub fn init(allocator: mem.Allocator) !Self {
            const buf = try allocator.alloc(T, size);
            return .{
                .buf = buf,
                .first = 0,
                .stop = 0,
                .fill = 0,
                .items = Iterator{
                    .buf = buf.ptr,
                    .index = 0,
                    .remaining = 0,
                },
            };
        }

        pub fn forwardWrite(self: *Self, src: []const []const u8) void {
            debug.assert(src.len <= size);
            const rest = size - self.stop;
            var i: usize = 0;
            if (src.len <= rest) {
                while (i < src.len) : (i += 1) {
                    const pos = self.stop + i;
                    copyString(&self.buf[pos], src[i]);
                }
            } else {
                while (i < rest) : (i += 1) {
                    const pos = self.stop + i;
                    copyString(&self.buf[pos], src[i]);
                }
                while (i < src.len) : (i += 1) {
                    copyString(&self.buf[i - rest], src[i]);
                }
            }
            self.stop = (self.stop + src.len) % size;

            self.fill += src.len;
            if (self.fill > size) {
                self.first = (self.first + (self.fill - size)) % size;
                self.fill = size;
            }

            self.items.index = self.first;
            self.items.remaining = self.fill;
        }

        pub fn backwardWrite(self: *Self, src: []const []const u8) void {
            debug.assert(src.len <= size);
            const start: usize = (self.first + size - src.len) % size;
            var i: usize = 0;
            if (src.len <= self.first) {
                while (i < src.len) : (i += 1) {
                    const pos = start + i;
                    copyString(&self.buf[pos], src[i]);
                }
            } else {
                const tail_len = size - start;
                while (i < tail_len) : (i += 1) {
                    const pos = start + i;
                    copyString(&self.buf[pos], src[i]);
                }
                while (i < src.len) : (i += 1) {
                    copyString(&self.buf[i - tail_len], src[i]);
                }
            }
            self.first = start;

            self.fill += src.len;
            if (self.fill > size) {
                const overflow = self.fill - size;
                self.stop = (self.stop + size - overflow) % size;
                self.fill = size;
            }

            self.items.index = self.first;
            self.items.remaining = self.fill;
        }

        fn copyString(dest: *T, str: []const u8) void {
            debug.assert(str.len < max_str); // Reserve space for null terminator.
            @memcpy(dest[0..str.len], str);
            dest[str.len] = 0; // Null-terminate.
        }
    };
}

test "ring" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var arr: [8]u8 = undefined;
    for (0..8) |i| {
        const cast: u8 = @intCast(i);
        arr[i] = cast;
    }
    var ring = try Buffer(8, u8).init(allocator);

    ring.forwardWrite(arr[0..]);

    debug.print("---------------\n", .{});
    for (ring.buf) |x| {
        debug.print("Val: {}\n", .{x});
    }

    for (0..4) |i| {
        arr[i] = 69;
    }

    ring.forwardWrite(arr[0..4]);

    debug.print("---------------\n", .{});
    for (ring.buf) |x| {
        debug.print("Val: {}\n", .{x});
    }

    debug.print("---------------\n", .{});
    debug.print("Ordered\n", .{});
    while (ring.items.next()) |item| {
        debug.print("Val: {}\n", .{item});
    }
}

test "string ring" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var ring = try StrBuffer(4, 32).init(allocator);

    ring.forwardWrite(&[_][]const u8{ "Tristan", "Ngan", "Mari" });
    ring.backwardWrite(&[_][]const u8{"peeppe"});
    ring.backwardWrite(&[_][]const u8{"Jet"});

    debug.print("---------------\n", .{});
    while (ring.items.next()) |item| {
        debug.print("Val: {s}\n", .{item});
    }
    ring.forwardWrite(&[_][]const u8{ "Lee", "Harry", "Friedrich" });
    debug.print("---------------\n", .{});
    while (ring.items.next()) |item| {
        debug.print("Val: {s}\n", .{item});
    }
}
