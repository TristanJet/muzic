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

        pub fn init() Self {
            return Self{
                .indices = .empty,
                .set = &[_]T{},
                .uppers = null,
            };
        }

        pub fn update(self: *Self, set: []const T, uppers: ?[]const []const u16, gpa: mem.Allocator) !void {
            try self.indices.ensureTotalCapacity(gpa, set.len);
            self.indices.items.len = set.len;
            for (0..set.len) |i| {
                self.indices.items[i] = i;
            }
            self.set = set;
            self.uppers = uppers;
        }

        pub fn itemsFromIndices(self: Self, js: []const usize, out: []T) usize {
            assert(out.len >= js.len);
            for (js, 0..) |j, i| {
                out[i] = self.set[j];
            }
            return js.len;
        }
    };
}

pub const SearchState = struct {
    isearch: ArrayList([]const usize),
    imatch: ArrayList([]const usize),
    index_arena: mem.Allocator,

    pub fn init(arena: mem.Allocator) SearchState {
        return .{
            .isearch = .empty,
            .imatch = .empty,
            .index_arena = arena,
        };
    }

    pub fn dupe(self: *SearchState, src: []const usize) ![]const usize {
        return try self.index_arena.dupe(usize, src);
    }

    pub fn reset(self: *SearchState) void {
        self.isearch.shrinkRetainingCapacity(0);
        self.imatch.shrinkRetainingCapacity(0);
    }
};

var result: []usize = undefined;
var scored: ArrayList(ScoredIndex) = .empty;

const match_score: i8 = 2;
const mismatch_penalty: i8 = -1;
const gap_penalty: i8 = -1;
const exact_word_multiplier: u16 = 100;

const MAX_INPUT_LEN = 32;
const MAX_ITEM_LEN = 256;

const ScoredIndex = struct {
    isong: usize,
    score: u16,
};

const AlgoError = error{
    NoWindowLength,
    OutOfMemory,
    BadIndex,
    NoUpper,
    ResultTooLong,
};

pub fn init(max_result: usize) AlgoError!void {
    assert(max_result > 0);
    result = try persistentAllocator.alloc(usize, max_result);
}

pub fn stringUriBest(
    input: []const u8,
    search_sample: *SearchSample(mpd.SongStringAndUri),
    nresult: usize,
    pa: mem.Allocator,
) AlgoError![]const usize {
    assert(search_sample.indices.items.len > 0);
    if (nresult > result.len) return error.ResultTooLong;

    scored.shrinkRetainingCapacity(0);
    const inputLower = ascii.lowerString(inputLowerBuf, input);
    if (inputLower.len == 1) return suContained(inputLower[0], search_sample, nresult);

    var matrix = Matrix.init(inputLower.len);
    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        const j = search_sample.indices.items[i];
        var item = search_sample.set[j];
        const uppers = search_sample.uppers orelse return error.NoUpper;
        item.string = fastLowerString(item.string, uppers[j], stringLowerBuf1);
        const score = calculateScore(inputLower, item.string, &matrix);
        if (score >= inputLower.len) {
            try scored.append(pa, .{ .isong = j, .score = score });
        } else {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    return sort(nresult);
}

fn suContained(
    input: u8,
    search_sample: *SearchSample(mpd.SongStringAndUri),
    nresult: usize,
) AlgoError![]usize {
    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        const j = search_sample.indices.items[i];
        const item = search_sample.set[j];
        const uppers = search_sample.uppers orelse return error.NoUpper;
        const stringLower = fastLowerString(item.string, uppers[j], stringLowerBuf1);
        if (mem.indexOfScalar(u8, stringLower, input) == null) {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    return search_sample.indices.items[0..@min(nresult, search_sample.indices.items.len)];
}

pub fn stringBest(
    input: []const u8,
    search_sample: *SearchSample([]const u8),
    nresult: usize,
    pa: mem.Allocator,
) ![]const usize {
    assert(search_sample.indices.items.len > 0);
    if (nresult > result.len) return error.ResultTooLong;

    scored.shrinkRetainingCapacity(0);
    const inputLower = ascii.lowerString(inputLowerBuf, input);
    if (inputLower.len == 1) return try stringContained(input[0], search_sample, nresult);

    var matrix = Matrix.init(inputLower.len);
    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        const j = search_sample.indices.items[i];
        var item = search_sample.set[j];
        if (search_sample.uppers) |uppers| {
            item = fastLowerString(item, uppers[j], stringLowerBuf1);
        } else {
            item = ascii.lowerString(stringLowerBuf1, item);
        }
        const score = calculateScore(inputLower, item, &matrix);
        if (score >= inputLower.len) {
            try scored.append(pa, .{ .isong = j, .score = score });
        } else {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    return sort(nresult);
}

fn stringContained(
    input: u8,
    search_sample: *SearchSample([]const u8),
    nresult: usize,
) ![]const usize {
    var i: usize = 0;
    while (i < search_sample.indices.items.len) {
        const j = search_sample.indices.items[i];
        const item = search_sample.set[j];
        var stringLower: []const u8 = undefined;
        if (search_sample.uppers) |uppers| {
            stringLower = fastLowerString(item, uppers[j], stringLowerBuf1);
        } else {
            stringLower = ascii.lowerString(stringLowerBuf1, item);
        }
        if (mem.indexOfScalar(u8, stringLower, input) == null) {
            _ = search_sample.indices.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    return search_sample.indices.items[0..@min(nresult, search_sample.indices.items.len)];
}

fn sort(nresult: usize) []const usize {
    std.sort.pdq(ScoredIndex, scored.items, {}, struct {
        fn lessThan(_: void, a: ScoredIndex, b: ScoredIndex) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const n = @min(scored.items.len, nresult);
    for (scored.items[0..n], 0..) |item, index| {
        result[index] = item.isong;
    }

    return result[0..n];
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
            //If the char_matches is equal to both lengths then the string is a perfect match and should be returned
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
