const std = @import("std");
const mpd = @import("mpdclient.zig");
const util = @import("util.zig");
const fastLowerString = @import("state.zig").fastLowerString;
const alloc = @import("allocators.zig");
const persistentAllocator = alloc.persistentAllocator;
const inputLowerBuf = alloc.ptrInput;
const stringLowerBuf1 = alloc.ptrLower1;
const stringLowerBuf2 = alloc.ptrLower2;
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
        uppers: ?[]const []const u16,

        pub fn init(allocator: mem.Allocator) Self {
            return Self{
                .indices = ArrayList(usize).init(allocator),
                .set = undefined,
                .uppers = undefined,
            };
        }

        pub fn update(self: *Self, set: []const T, uppers: ?[]const []const u16) !void {
            try self.indices.ensureTotalCapacity(set.len);
            self.indices.items.len = set.len;
            for (0..set.len) |i| {
                self.indices.items[i] = i;
            }
            self.set = set;
            if (uppers) |upp| {
                self.uppers = upp;
            } else {
                self.uppers = null;
            }
        }

        fn itemFromI(self: *const Self, j: usize) !T {
            if (j < self.indices.items.len) {
                return self.set[self.indices.items[j]];
            } else {
                return error.BadIndex;
            }
        }

        pub fn upperFromI(self: *const Self, j: usize) ![]const u16 {
            if (self.uppers) |uppers| {
                if (j < self.indices.items.len) {
                    return uppers[self.indices.items[j]];
                }
            }
            return error.BadIndex;
        }
    };
}

var result_su = ArrayList(mpd.SongStringAndUri).init(persistentAllocator);
var scoredSongs: ArrayList(ScoredStringAndUri) = undefined;

var nRanked: usize = undefined;

const match_score: i8 = 2;
const mismatch_penalty: i8 = -1;
const gap_penalty: i8 = -1;
const exact_word_multiplier: u16 = 100;

const MAX_INPUT_LEN = 32;
const MAX_ITEM_LEN = 256;

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
    BadIndex,
};

pub fn init(n: usize, nsearchable: usize) AlgoError!void {
    if (n == 0) return AlgoError.NoWindowLength;
    nRanked = n;
    try result_su.ensureTotalCapacityPrecise(nRanked);
    result_su.expandToCapacity();
    scoredSongs = ArrayList(ScoredStringAndUri).init(persistentAllocator);
    try scoredSongs.ensureTotalCapacityPrecise(nsearchable);
}

pub fn suTopNranked(
    input: []const u8,
    search_sample: *SearchSample(mpd.SongStringAndUri),
) AlgoError!?[]const mpd.SongStringAndUri {
    scoredSongs.shrinkRetainingCapacity(0);
    const inputLower = ascii.lowerString(inputLowerBuf, input);
    if (inputLower.len == 1) return suContained(inputLower[0], search_sample);

    var matrix = Matrix.init(inputLower.len);
    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        const item = search_sample.itemFromI(i) catch |e| {
            if (i == 0) {
                return null;
            } else {
                return e;
            }
        };
        const stringLower = fastLowerString(item.string, try search_sample.upperFromI(i), stringLowerBuf1);
        const score = calculateScore(inputLower, stringLower, &matrix);
        if (score >= inputLower.len) {
            try scoredSongs.append(.{ .song = item, .score = score });
        } else {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
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
) AlgoError!?[]const mpd.SongStringAndUri {
    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        const item = search_sample.itemFromI(i) catch |e| {
            if (i == 0) {
                return null;
            } else {
                return e;
            }
        };
        const stringLower = fastLowerString(item.string, try search_sample.upperFromI(i), stringLowerBuf1);
        if (mem.indexOfScalar(u8, stringLower, input) == null) {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    const nresult = @min(nRanked, search_sample.indices.items.len);
    for (0..nresult) |j| {
        result_su.items[j] = try search_sample.itemFromI(j);
    }

    return result_su.items[0..nresult];
}

pub fn stringBestMatch(
    input: []const u8,
    search_sample: *SearchSample([]const u8),
) !?[]const u8 {
    const inputLower = ascii.lowerString(inputLowerBuf, input);
    if (inputLower.len == 1) {
        return try stringContained(input[0], search_sample);
    }
    var best_match: ?[]const u8 = null;
    var highestScore: u16 = 0;

    var matrix = Matrix.init(inputLower.len);
    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        var item: []const u8 = undefined;
        if (search_sample.uppers) |_| {
            item = fastLowerString(try search_sample.itemFromI(i), try search_sample.upperFromI(i), stringLowerBuf1);
        } else {
            item = ascii.lowerString(stringLowerBuf1, try search_sample.itemFromI(i));
        }
        const score = calculateScore(inputLower, item, &matrix);
        if (score >= inputLower.len) {
            if (score > highestScore) {
                best_match = try search_sample.itemFromI(i);
                highestScore = score;
            }
        } else {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
    }
    return best_match;
}

fn stringContained(
    input: u8,
    search_sample: *SearchSample([]const u8),
) !?[]const u8 {
    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        const item = search_sample.itemFromI(i) catch |e| {
            if (i == 0) {
                return null;
            } else {
                return e;
            }
        };
        var stringLower: []const u8 = undefined;
        if (search_sample.uppers) |_| {
            stringLower = fastLowerString(item, try search_sample.upperFromI(i), stringLowerBuf1);
        } else {
            stringLower = ascii.lowerString(stringLowerBuf1, item);
        }
        if (mem.indexOfScalar(u8, stringLower, input) == null) {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    return search_sample.itemFromI(0) catch unreachable;
}

var mbuf1: [MAX_INPUT_LEN + 1][]u16 = undefined;
var mbuf2: [(MAX_INPUT_LEN + 1) * (MAX_ITEM_LEN + 1)]u16 = undefined;
const Matrix = struct {
    data: [][]u16 = undefined,
    super: usize,
    sub: usize,

    fn init(input_len: usize) Matrix {
        const super = input_len + 1;
        const data: [][]u16 = mbuf1[0..super];

        return .{
            .super = super,
            .sub = undefined,
            .data = data,
        };
    }

    fn loUpdate(self: *Matrix, string_len: usize) void {
        const sub = string_len + 1;
        var i: usize = 0;
        while (i < self.super) {
            self.data[i] = mbuf2[(i * sub)..((i + 1) * sub)];
            i += 1;
        }
        for (self.data) |row| {
            @memset(row, 0);
        }
    }
};

fn calculateScore(input: []const u8, string: []const u8, matrix: *Matrix) u16 {
    var exact_score: u16 = 0;
    var input_words = mem.splitSequence(u8, input, " ");
    while (input_words.next()) |word| {
        // Skip very short words (like "the", "a", etc.)
        if (word.len <= 2 or word.len >= 255) continue;

        const len: u8 = @intCast(word.len);
        // Look for exact word match
        if (std.mem.indexOf(u8, string, word)) |_| {
            exact_score += len * exact_word_multiplier;
        }
    }

    // Then get the Smith-Waterman score for overall similarity
    const sw_score = smithwaterman(input, string, matrix);

    return exact_score + sw_score;
}

fn smithwaterman(seq1: []const u8, seq2: []const u8, matrix: *Matrix) u16 {
    const len1: usize = seq1.len + 1;
    const len2: usize = seq2.len + 1;

    matrix.loUpdate(seq2.len);

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
