const std = @import("std");

pub var wrkbuf: [4096]u8 = undefined;
pub var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
pub const wrkallocator = wrkfba.allocator();

pub var respArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const respAllocator = respArena.allocator();

pub var persistentArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const persistentAllocator = persistentArena.allocator();

pub var algoArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const algoArenaAllocator = algoArena.allocator();

pub var typingArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const typingAllocator = typingArena.allocator();

pub fn deinit() void {
    persistentArena.deinit();
    algoArena.deinit();
    typingArena.deinit();
}
