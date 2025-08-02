const std = @import("std");
const mpd = @import("mpdclient.zig");
const util = @import("util.zig");
const arena: *std.heap.ArenaAllocator = &@import("allocators.zig").algoArena;
const fastLowerString = @import("state.zig").fastLowerString;
const arenaAllocator = arena.allocator();
const persistentAllocator = @import("allocators.zig").persistentAllocator;
const log = util.log;
const assert = std.debug.assert;
const ascii = std.ascii;
const mem = std.mem;
const ArrayList = std.ArrayList;

pub fn SearchSample(comptime T: type) type {
    return struct {
        const Self = @This();

        indices: ArrayList(usize),
        set: []const T,
        uppers: []const []const u16,

        pub fn init(allocator: mem.Allocator) Self {
            return Self{
                .indices = ArrayList(usize).init(allocator),
                .set = undefined,
                .uppers = undefined,
            };
        }

        pub fn update(self: *Self, set: []const T, uppers: []const []const u16) !void {
            try self.indices.ensureTotalCapacity(set.len);
            self.indices.items.len = set.len;
            for (0..set.len) |i| {
                self.indices.items[i] = i;
            }
            self.set = set;
            self.uppers = uppers;
        }

        fn itemFromI(self: *const Self, j: usize) T {
            assert(j < self.indices.items.len);
            return self.set[self.indices.items[j]];
        }

        fn upperFromI(self: *const Self, j: usize) []const u16 {
            assert(j < self.indices.items.len);
            return self.uppers[self.indices.items[j]];
        }
    };
}

var result_su = ArrayList(mpd.SongStringAndUri).init(persistentAllocator);
var scoredSongs: ArrayList(ScoredStringAndUri) = undefined;

var nRanked: usize = undefined;

var inputLowerBuf: [32]u8 = undefined;
var stringLowerBuf: [512]u8 = undefined;

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

pub fn init(n: usize, nsearchable: usize) AlgoError!void {
    if (n == 0) return AlgoError.NoWindowLength;
    nRanked = n;
    try result_su.ensureTotalCapacityPrecise(nRanked);
    result_su.expandToCapacity();
    scoredSongs = ArrayList(ScoredStringAndUri).init(persistentAllocator);
    try scoredSongs.ensureTotalCapacityPrecise(nsearchable);
}

// test "setSearch" {
//     try mpd.connect(.command, false);
//
//     var respArena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//     const respAllocator: std.mem.Allocator = respArena.allocator();
//     search_sample_str = SearchSample([]const u8).init(persistentAllocator);
//     const artists: []const []const u8 = try mpd.getAllArtists(persistentAllocator, respAllocator);
//     try search_sample_str.update(artists);
//     std.debug.print("{}\n", .{artists.len});
//     std.debug.print("{s}\n", .{artists[69]});
//     try std.testing.expect(search_sample_str.indices.items.len == artists.len);
//     try std.testing.expect(search_sample_str.indices.items[69] == 69);
//     try std.testing.expect(mem.eql(u8, search_sample_str.getItem(69), "Black Sabbath"));
//     _ = search_sample_str.indices.orderedRemove(69);
//     try std.testing.expect(search_sample_str.indices.items[69] == 70);
//     try std.testing.expect(search_sample_str.indices.capacity >= artists.len);
//     std.debug.print("{s}\n", .{search_sample_str.getItem(69)});
//     std.debug.print("{}\n", .{search_sample_str.indices.capacity});
// }

pub fn suTopNranked(
    input: []const u8,
    search_sample: *SearchSample(mpd.SongStringAndUri),
) AlgoError![]const mpd.SongStringAndUri {
    scoredSongs.shrinkRetainingCapacity(0);
    const inputLower = ascii.lowerString(&inputLowerBuf, input);
    if (inputLower.len == 1) return try suContained(inputLower[0], search_sample);

    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        const score = calculateScore(inputLower, search_sample.itemFromI(i).string, arenaAllocator) catch unreachable;
        const cutoff_fraction = inputLower.len / cutoff_denominator;
        if (score >= cutoff_fraction) {
            try scoredSongs.append(.{ .song = search_sample.itemFromI(i), .score = score });
        } else {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
        _ = arena.reset(.retain_capacity);
    }
    // Sort by score
    std.sort.pdq(ScoredStringAndUri, scoredSongs.items, {}, struct {
        fn lessThan(_: void, a: ScoredStringAndUri, b: ScoredStringAndUri) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const numResults = @min(scoredSongs.items.len, nRanked);
    for (scoredSongs.items[0..numResults], 0..) |scored, j| {
        result_su.items[j] = scored.song;
    }

    return result_su.items[0..numResults];
}

fn suContained(
    input: u8,
    search_sample: *SearchSample(mpd.SongStringAndUri),
) ![]const mpd.SongStringAndUri {
    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        const stringLower = fastLowerString(search_sample.itemFromI(i).string, search_sample.upperFromI(i), &stringLowerBuf);
        if (mem.indexOfScalar(u8, stringLower, input) == null) {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    const nresult = @min(nRanked, search_sample.indices.items.len);
    for (0..nresult) |j| {
        result_su.items[j] = search_sample.itemFromI(j);
    }

    return result_su.items[0..nresult];
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
