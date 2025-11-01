const std = @import("std");
const mem = std.mem;
const debug = std.debug;

pub const Ring = struct {
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
};

pub fn Buffer(size: usize, T: type) type {
    return struct {
        const Self = @This();
        buf: []T,

        pub fn init(allocator: mem.Allocator) !Self {
            return .{ .buf = try allocator.alloc(T, size) };
        }

        pub fn forwardWrite(self: *Self, ring: Ring, src: T) void {
            self.buf[ring.stop] = src;
        }

        pub fn backwardWrite(self: *Self, ring: Ring, src: T) void {
            const start: usize = (ring.first + ring.size - 1) % ring.size;
            self.buf[start] = src;
        }

        pub const Iterator = struct {
            buf: [*]const T,
            index: usize,
            remaining: usize,

            pub fn next(self: *Iterator, inc: usize) ?T {
                const index = (self.index + inc) % size;
                const remaining = @subWithOverflow(self.remaining, inc);
                if (remaining[1] != 0 or remaining[0] == 0) return null;
                const value = self.buf[index];
                self.index = (self.index + 1) % size;
                self.remaining -= 1;
                return value;
            }
        };

        //Return an iterator based on the current state of the ring
        //Incrementing or changing the ring will make this iterator invalid
        pub fn getIterator(self: *Self, ring: Ring) Iterator {
            return Iterator{
                .buf = self.buf.ptr,
                .index = ring.first,
                .remaining = ring.fill,
            };
        }
    };
}

pub fn StrBuffer(size: usize, max_str: usize) type {
    const T = [max_str:0]u8;
    return struct {
        const Self = @This();
        buf: []T,

        pub fn init(allocator: mem.Allocator) !Self {
            return .{ .buf = try allocator.alloc(T, size) };
        }

        pub fn forwardWrite(self: *Self, ring: Ring, src: []const u8) []const u8 {
            const str = copyString(&self.buf[ring.stop], src);
            return str;
        }

        pub fn backwardWrite(self: *Self, ring: Ring, src: []const u8) []const u8 {
            const start: usize = (ring.first + ring.size - 1) % size;
            const str = copyString(&self.buf[start], src);
            return str;
        }

        fn copyString(dest: *T, str: []const u8) []const u8 {
            const end: usize = if (str.len < max_str) str.len else max_str;
            @memcpy(dest[0..end], str[0..end]);
            dest[end] = 0; // Null-terminate.
            return dest[0..end];
        }

        pub const Iterator = struct {
            buf: [*]const T,
            index: usize,
            remaining: usize,

            pub fn next(self: *Iterator, inc: usize) ?[]const u8 {
                const index = (self.index + inc) % size;
                const remaining = @subWithOverflow(self.remaining, inc);
                if (remaining[1] != 0 or remaining[0] == 0) return null;
                const ptr: [*:0]const u8 = @ptrCast(&self.buf[index]);
                const value = mem.span(ptr); // Computes length up to null terminator.
                self.index = (self.index + 1) % size;
                self.remaining -= 1;
                return value;
            }
        };

        //Return an iterator based on the current state of the ring
        //Incrementing or changing the ring will make this iterator invalid
        pub fn getIterator(self: *Self, ring: Ring) Iterator {
            return Iterator{
                .buf = self.buf.ptr,
                .index = ring.first,
                .remaining = ring.fill,
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
    var intbuf = try Buffer(size, u8).init(allocator);
    var strbuf = try StrBuffer(size, 32).init(allocator);

    const arr: [7][]const u8 = .{ "Luffy", "Zoror", "Nami", "Usopp", "Sanji", "Chopper", "Robin" };

    var i: u8 = 0;
    while (i < ring.size + 2) : ({
        i += 1;
        ring.increment();
    }) {
        intbuf.forwardWrite(ring, i);
        _ = strbuf.forwardWrite(ring, arr[i]);
    }

    debug.print("-----------\n", .{});
    var itint = intbuf.getIterator(ring);
    while (itint.next(0)) |item| {
        debug.print("{}\n", .{item});
    }

    var itstr = strbuf.getIterator(ring);
    debug.print("-----------\n", .{});
    while (itstr.next(0)) |item| {
        debug.print("{s}\n", .{item});
    }

    i = 0;
    while (i < 2) : ({
        i += 1;
        ring.decrement();
    }) {
        intbuf.backwardWrite(ring, i + 68);
        _ = strbuf.backwardWrite(ring, arr[i]);
    }
    debug.print("-----------\n", .{});
    itint = intbuf.getIterator(ring);
    while (itint.next(0)) |item| {
        debug.print("{}\n", .{item});
    }

    itstr = strbuf.getIterator(ring);
    debug.print("-----------\n", .{});
    while (itstr.next(0)) |item| {
        debug.print("{s}\n", .{item});
    }
}
