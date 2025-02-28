const std = @import("std");
const mpd = @import("mpdclient.zig");
const util = @import("util.zig");
const assert = std.debug.assert;

pub var nRanked: usize = undefined;

const cutoff_denominator: u8 = 2;

const match_score: i8 = 2;
const mismatch_penalty: i8 = -1;
const gap_penalty: i8 = -1;
const exact_word_multiplier: u16 = 100;

pub var pointerToAll: *[]mpd.Searchable = undefined;
var items: *[]mpd.Searchable = undefined;

const ScoredString = struct {
    song: mpd.Searchable,
    score: u16,
};

const AlgoError = error{
    NoWindowLength,
    OutOfMemory,
};

pub fn algorithm(arena: *std.heap.ArenaAllocator, heapAllocator: std.mem.Allocator, input: []const u8) AlgoError![]mpd.Searchable {
    if (nRanked == 0) return AlgoError.NoWindowLength;
    util.log("items: {s}", .{items.*[0].string.?});
    util.log("items length: {}", .{items.*.len});
    util.log("input: {s}", .{input});
    const arenaAllocator = arena.allocator();
    if (input.len == 1) return try contains(heapAllocator, arena, input[0]);
    var scoredStrings = std.ArrayList(ScoredString).init(heapAllocator);
    defer scoredStrings.deinit();
    var itemArray = std.ArrayList(mpd.Searchable).init(heapAllocator);

    for (items.*) |item| {
        if (item.string) |string| {
            defer {
                _ = arena.reset(.retain_capacity);
            }
            const score = calculateScore(input, string, arenaAllocator) catch unreachable;
            //at least quarter are matches
            const cutoff_fraction = input.len / cutoff_denominator;
            if (score >= cutoff_fraction) {
                try itemArray.append(item);
                try scoredStrings.append(.{ .song = item, .score = score });
            }
        }
    }

    const new_items = try heapAllocator.dupe(mpd.Searchable, itemArray.items);
    items = try heapAllocator.create([]mpd.Searchable);
    items.* = new_items;
    // Sort by score (highest first)
    std.sort.pdq(ScoredString, scoredStrings.items, {}, struct {
        fn lessThan(_: void, a: ScoredString, b: ScoredString) bool {
            return a.score > b.score;
        }
    }.lessThan);

    // Take top 10 strings
    var result = std.ArrayList(mpd.Searchable).init(heapAllocator);
    const numResults = @min(scoredStrings.items.len, nRanked);
    for (scoredStrings.items[0..numResults]) |scored| {
        try result.append(scored.song);
    }

    util.log("result algo: {}", .{result.items.len});

    return try result.toOwnedSlice();
}

fn contains(heapAllocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, input: u8) ![]mpd.Searchable {
    const arenaAllocator = arena.allocator();
    var itemArray = std.ArrayList(mpd.Searchable).init(heapAllocator);
    var rankedStrings = std.ArrayList(mpd.Searchable).init(heapAllocator);

    const inputLower = std.ascii.toLower(input);
    for (items.*) |item| {
        defer {
            _ = arena.reset(.retain_capacity);
        }
        if (item.string) |string| {
            const stringLower: []const u8 = try std.ascii.allocLowerString(arenaAllocator, string);
            if (std.mem.indexOfScalar(u8, stringLower, inputLower)) |_| {
                try itemArray.append(item);
                if (rankedStrings.items.len < nRanked) try rankedStrings.append(item);
            }
        }
    }
    util.log("items len {}", .{itemArray.items.len});
    util.log("ranked len {}", .{rankedStrings.items.len});
    const new_items = try heapAllocator.dupe(mpd.Searchable, itemArray.items);
    items = try heapAllocator.create([]mpd.Searchable);
    items.* = new_items;
    return rankedStrings.toOwnedSlice();
}

pub fn resetItems() void {
    items = pointerToAll;
}

const Matrix = struct {
    //use arena.reset(.retain_capacity)
    data: [][]u16 = undefined,
    super: usize,
    sub: usize,

    pub fn init(super: usize, sub: usize, allocator: std.mem.Allocator) !Matrix {
        const data = try allocator.alloc([]u16, super);

        var i: usize = 0;
        while (i < super) {
            data[i] = try allocator.alloc(u16, sub);
            i += 1;
        }
        for (data) |row| {
            @memset(row, 0);
        }

        return .{
            .super = super,
            .sub = sub,
            .data = data,
        };
    }
};

fn calculateScore(input: []const u8, string: []const u8, allocator: std.mem.Allocator) !u16 {
    // First, calculate exact word matches
    const inputLower: []const u8 = try std.ascii.allocLowerString(allocator, input);
    const stringLower: []const u8 = try std.ascii.allocLowerString(allocator, string);
    var exact_score: u16 = 0;
    var input_words = std.mem.split(u8, inputLower, " ");
    while (input_words.next()) |word| {
        // Skip very short words (like "the", "a", etc.)
        if (word.len <= 2 or word.len >= 255) continue;

        const len: u8 = @intCast(word.len);
        // Look for exact word match
        if (std.mem.indexOf(u8, stringLower, word)) |_| {
            exact_score += len * exact_word_multiplier;
        }
    }

    // Then get the Smith-Waterman score for overall similarity
    const sw_score = try smithwaterman(input, string, allocator);

    return exact_score + sw_score;
}

fn smithwaterman(seq1: []const u8, seq2: []const u8, allocator: std.mem.Allocator) !u16 {
    const len1: usize = seq1.len + 1;
    const len2: usize = seq2.len + 1;

    const matrix = try Matrix.init(len1, len2, allocator);

    var totalmax: u16 = 0;
    for (1..len1) |i| {
        for (1..len2) |j| {
            const char_matches = seq1[i - 1] == seq2[j - 1];

            const match_add: i32 = if (char_matches) match_score else mismatch_penalty;

            const match: i32 = matrix.data[i - 1][j - 1] + match_add;
            const delete: i32 = @as(i32, matrix.data[i - 1][j]) + gap_penalty;
            const insert: i32 = @as(i32, matrix.data[i][j - 1]) + gap_penalty;
            const max: u16 = @intCast(std.sort.max(i32, &[_]i32{ match, delete, insert, 0 }, {}, std.sort.asc(i32)).?);
            //theoretical max is 2 * sequence length
            matrix.data[i][j] = max;
            if (max > totalmax) {
                totalmax = max;
            }
        }
    }
    return totalmax;
}

test "full function" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    // const arenaAllocator = arena.allocator();

    var longarena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer longarena.deinit();
    const longallocator = longarena.allocator();

    var respArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const respAllocator = respArena.allocator();

    var wrkbuf: [16]u8 = undefined;
    _ = try mpd.connect(wrkbuf[0..16], &mpd.cmdStream, false);
    std.debug.print("connected\n", .{});

    items = try mpd.getSearchable(longallocator, respAllocator);
    respArena.deinit();

    const input = "Beat It";
    var songs: []mpd.Searchable = undefined;

    std.debug.print("Total set: {}\n", .{items.len});
    for (1..input.len + 1) |i| {
        const inputfr = input[0..i];
        std.debug.print("Input: {s}\n", .{inputfr});
        songs = try algorithm(&arena, longallocator, inputfr);
        for (songs, 0..) |song, j| {
            std.debug.print("Best match: {} {s}\n", .{ j, song.string.? });
        }
        std.debug.print("Total set: {}\n", .{items.len});
    }
}
