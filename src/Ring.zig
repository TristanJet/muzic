const std = @import("std");
const mem = std.mem;
const debug = std.debug;

const Ring = @This();

size: usize,
first: usize,
stop: usize,
fill: usize,

pub fn increment(self: *Ring) void {
    self.stop = (self.stop + 1) % self.size;

    self.fill += 1;
    if (self.fill > self.size) {
        self.first = self.stop;
        self.fill = self.size;
    }
}
pub fn decrement(self: *Ring) void {
    const start: usize = (self.first + self.size - 1) % self.size;
    self.first = start;

    self.fill += 1;
    if (self.fill > self.size) {
        self.stop = self.first;
        self.fill = self.size;
    }
}

pub fn Buffer(size: usize, T: type) type {
    return struct {
        const Self = @This();
        buf: []T,
        ring: *const Ring,

        pub fn init(allocator: mem.Allocator, ring: *const Ring) !Self {
            debug.assert(ring.size == size);
            const buf = try allocator.alloc(T, size);
            return .{
                .buf = buf,
                .ring = ring,
            };
        }

        pub fn forwardWrite(self: *Self, src: T) void {
            self.buf[self.ring.stop] = src;
        }

        pub fn backwardWrite(self: *Self, src: T) void {
            const start: usize = (self.ring.first + self.ring.size - 1) % self.ring.size;
            self.buf[start] = src;
        }

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

        //Return an iterator based on the current state of the ring
        //Incrementing or changing the ring will make this iterator invalid
        pub fn getIterator(self: *Self) Iterator {
            return Iterator{
                .buf = self.buf.ptr,
                .index = self.ring.first,
                .remaining = self.ring.fill,
            };
        }
    };
}

pub fn StrBuffer(size: usize, max_str: usize) type {
    const T = [max_str:0]u8;
    return struct {
        const Self = @This();
        buf: []T,
        ring: *const Ring,

        pub fn init(allocator: mem.Allocator, ring: *const Ring) !Self {
            debug.assert(ring.size == size);
            const buf = try allocator.alloc(T, size);
            return .{
                .buf = buf,
                .ring = ring,
            };
        }

        pub fn forwardWrite(self: *Self, src: []const u8) []const u8 {
            const str = copyString(&self.buf[self.ring.stop], src);
            return str;
        }

        pub fn backwardWrite(self: *Self, src: []const u8) []const u8 {
            const start: usize = (self.ring.first + self.ring.size - 1) % size;
            const str = copyString(&self.buf[start], src);
            return str;
        }

        fn copyString(dest: *T, str: []const u8) []const u8 {
            const end: usize = if (str.len < max_str) str.len else max_str;
            @memcpy(dest[0..end], str[0..end]);
            dest[end] = 0; // Null-terminate.
            return dest[0..end];
        }

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

        //Return an iterator based on the current state of the ring
        //Incrementing or changing the ring will make this iterator invalid
        pub fn getIterator(self: *Self) Iterator {
            return Iterator{
                .buf = self.buf.ptr,
                .index = self.ring.first,
                .remaining = self.ring.fill,
            };
        }
    };
}

test "ring" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    const size = 4;
    var ring = Ring{
        .size = size,
        .first = 0,
        .stop = 0,
        .fill = 0,
    };
    var intbuf = try Buffer(size, u8).init(allocator, &ring);
    var strbuf = try StrBuffer(size, 32).init(allocator, &ring);

    const arr: [4][]const u8 = .{ "Tristan", "Mikael", "Jet", "Lay" };

    var i: u8 = 0;
    while (i < ring.size) : ({
        i += 1;
        ring.increment();
    }) {
        intbuf.forwardWrite(i);
        _ = strbuf.forwardWrite(arr[i]);
    }

    debug.print("-----------\n", .{});
    var itint = intbuf.getIterator();
    while (itint.next()) |item| {
        debug.print("{}\n", .{item});
    }

    var itstr = strbuf.getIterator();
    debug.print("-----------\n", .{});
    while (itstr.next()) |item| {
        debug.print("{s}\n", .{item});
    }
}
