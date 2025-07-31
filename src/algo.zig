const std = @import("std");
const mpd = @import("mpdclient.zig");
const util = @import("util.zig");
const arena: *std.heap.ArenaAllocator = &@import("allocators.zig").algoArena;
const arenaAllocator = arena.allocator();
const log = util.log;
const assert = std.debug.assert;

var nRanked: usize = undefined;

const cutoff_denominator: u8 = 2;

const match_score: i8 = 2;
const mismatch_penalty: i8 = -1;
const gap_penalty: i8 = -1;
const exact_word_multiplier: u16 = 100;

const ScoredStringAndUri = struct {
    song: mpd.SongStringAndUri,
    score: u16,
};

const ScoredString = struct {
    string: []const u8,
    score: u16,
};

const AlgoError = error{
    NoWindowLength,
    OutOfMemory,
};

pub fn init(n: usize) AlgoError!void {
    if (n == 0) return AlgoError.NoWindowLength;
    nRanked = n;
}

pub fn suTopNranked(
    heapAllocator: std.mem.Allocator,
    input: []const u8,
    items: *[]mpd.SongStringAndUri,
) AlgoError![]mpd.SongStringAndUri {
    const inputLower = try std.ascii.allocLowerString(heapAllocator, input);
    if (inputLower.len == 1) return try suContained(heapAllocator, inputLower[0], items);
    var scoredStrings = std.ArrayList(ScoredStringAndUri).init(heapAllocator);
    defer scoredStrings.deinit();
    var newItemArray = std.ArrayList(mpd.SongStringAndUri).init(heapAllocator);

    for (items.*) |item| {
        const score = calculateScore(inputLower, item.string, arenaAllocator) catch unreachable;
        //at least quarter are matches
        const cutoff_fraction = inputLower.len / cutoff_denominator;
        if (score >= cutoff_fraction) {
            try newItemArray.append(item);
            try scoredStrings.append(.{ .song = item, .score = score });
        }
        _ = arena.reset(.retain_capacity);
    }

    items.* = try newItemArray.toOwnedSlice();

    // Sort by score (highest first)
    std.sort.pdq(ScoredStringAndUri, scoredStrings.items, {}, struct {
        fn lessThan(_: void, a: ScoredStringAndUri, b: ScoredStringAndUri) bool {
            return a.score > b.score;
        }
    }.lessThan);

    var result = std.ArrayList(mpd.SongStringAndUri).init(heapAllocator);
    const numResults = @min(scoredStrings.items.len, nRanked);
    for (scoredStrings.items[0..numResults]) |scored| {
        try result.append(scored.song);
    }

    return try result.toOwnedSlice();
}

fn suContained(
    heapAllocator: std.mem.Allocator,
    input: u8,
    items: *[]mpd.SongStringAndUri,
) ![]mpd.SongStringAndUri {
    var newItemArray = std.ArrayList(mpd.SongStringAndUri).init(heapAllocator);
    var rankedStrings = std.ArrayList(mpd.SongStringAndUri).init(heapAllocator);

    for (items.*) |item| {
        const stringLower: []const u8 = try std.ascii.allocLowerString(arenaAllocator, item.string);
        if (std.mem.indexOfScalar(u8, stringLower, input)) |_| {
            try newItemArray.append(item);
            if (rankedStrings.items.len < nRanked) try rankedStrings.append(item);
        }
        _ = arena.reset(.retain_capacity);
    }
    items.* = try newItemArray.toOwnedSlice();
    return rankedStrings.toOwnedSlice();
}

test "su" {
    var heap = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = heap.allocator();

    try mpd.connect(.command, false);

    const song_data = try mpd.listAllData(allocator);
    var searchable = try mpd.getSongStringAndUri(allocator, song_data);

    try init(10);

    const topranked = try suTopNranked(allocator, "exeter", &searchable);
    for (topranked) |su| {
        std.debug.print("{s}\n", .{su.string});
    }
}

pub fn stringBestMatch(
    heapAllocator: std.mem.Allocator,
    input: []const u8,
    items: *[][]const u8,
) !?[]const u8 {
    const inputLower = try std.ascii.allocLowerString(heapAllocator, input);
    if (inputLower.len == 1) {
        const contained_in: [][]const u8 = try stringContained(heapAllocator, inputLower[0], items);
        return contained_in[0];
    }
    var newItemArray = std.ArrayList([]const u8).init(heapAllocator);
    var best_match: ?[]const u8 = null;
    var highestScore: u16 = 0;

    for (items.*) |item| {
        const score = calculateScore(inputLower, item, arenaAllocator) catch unreachable;
        //at least quarter are matches
        const cutoff_fraction = inputLower.len / cutoff_denominator;
        if (score >= cutoff_fraction) {
            try newItemArray.append(item);
            if (score > highestScore) {
                best_match = item;
                highestScore = score;
            }
        }
        _ = arena.reset(.retain_capacity);
    }

    items.* = try newItemArray.toOwnedSlice();
    return best_match;
}

fn stringContained(
    heapAllocator: std.mem.Allocator,
    input: u8,
    items: *[][]const u8,
) ![][]const u8 {
    var newItemArray = std.ArrayList([]const u8).init(heapAllocator);
    var rankedStrings = std.ArrayList([]const u8).init(heapAllocator);

    for (items.*) |item| {
        const stringLower: []const u8 = try std.ascii.allocLowerString(arenaAllocator, item);
        if (std.mem.indexOfScalar(u8, stringLower, input)) |_| {
            try newItemArray.append(item);
            if (rankedStrings.items.len < nRanked) try rankedStrings.append(item);
        }
        _ = arena.reset(.retain_capacity);
    }
    items.* = try newItemArray.toOwnedSlice();
    return rankedStrings.toOwnedSlice();
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
    var input_words = std.mem.splitSequence(u8, inputLower, " ");
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
