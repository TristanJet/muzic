const std = @import("std");
const mpd = @import("mpdclient.zig");

pub var wrkbuf: [4096]u8 = undefined;
pub var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
pub const wrkallocator = wrkfba.allocator();

var stringLowerBuf1: [512]u8 = undefined;
var stringLowerBuf2: [512]u8 = undefined;
var inputLowerBuf: [32]u8 = undefined;
pub const ptrInput: *[32]u8 = &inputLowerBuf;
pub const ptrLower1: *[512]u8 = &stringLowerBuf1;
pub const ptrLower2: *[512]u8 = &stringLowerBuf2;

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

pub var album_artistArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn deinit() void {
    persistentArena.deinit();
    algoArena.deinit();
    typingArena.deinit();
    browserArena.deinit();
}
