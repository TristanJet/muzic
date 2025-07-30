const std = @import("std");

pub var wrkbuf: [4096]u8 = undefined;
pub var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
pub const wrkallocator = wrkfba.allocator();

pub var respArena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const respAllocator: std.mem.Allocator = respArena.allocator();

pub var persistentArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const persistentAllocator = persistentArena.allocator();

pub var algoArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub var typingArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const typingAllocator = typingArena.allocator();

pub var browserArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const browserAllocator = browserArena.allocator();

pub var songData = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const songDataAllocator = songData.allocator();

pub fn deinit() void {
    persistentArena.deinit();
    algoArena.deinit();
    typingArena.deinit();
    browserArena.deinit();
}
