const std = @import("std");
const mpd = @import("mpdclient.zig");

pub const nRanked: u8 = 10;

const match_score: i8 = 2;
const mismatch_penalty: i8 = -1;
const gap_penalty: i8 = -1;

pub var items: []mpd.Searchable = undefined;

const ScoredString = struct {
    string: []const u8,
    score: u16,
};

fn algorithm(arena: *std.heap.ArenaAllocator, heapAllocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    if (input.len == 1) return try contains(heapAllocator, input[0]);
    const arenaAllocator = arena.allocator();
    var scoredStrings = std.ArrayList(ScoredString).init(heapAllocator);
    defer scoredStrings.deinit();
    var itemArray = std.ArrayList(mpd.Searchable).init(heapAllocator);

    for (items) |item| {
        if (item.string) |string| {
            defer {
                _ = arena.reset(.retain_capacity);
            }
            const score = smithwaterman(input, string, arenaAllocator) catch unreachable;
            //at least half are matches
            if (score >= input.len) {
                try itemArray.append(item);
                try scoredStrings.append(.{ .string = string, .score = score });
            }
        }
    }

    items = try itemArray.toOwnedSlice();
    // Sort by score (highest first)
    std.sort.pdq(ScoredString, scoredStrings.items, {}, struct {
        fn lessThan(_: void, a: ScoredString, b: ScoredString) bool {
            return a.score > b.score;
        }
    }.lessThan);

    // Take top 10 strings
    var result = std.ArrayList([]const u8).init(heapAllocator);
    const numResults = @min(scoredStrings.items.len, nRanked);
    for (scoredStrings.items[0..numResults]) |scored| {
        try result.append(scored.string);
    }

    return try result.toOwnedSlice();
}

fn contains(heapAllocator: std.mem.Allocator, input: u8) ![][]const u8 {
    var itemArray = std.ArrayList(mpd.Searchable).init(heapAllocator);
    var rankedStrings = std.ArrayList([]const u8).init(heapAllocator);
    for (items) |item| {
        if (item.string) |string| {
            if (std.mem.indexOfScalar(u8, string, input)) |_| {
                try itemArray.append(item);
                if (rankedStrings.items.len < nRanked) try rankedStrings.append(string);
            }
        }
    }
    items = try itemArray.toOwnedSlice();
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

fn smithwaterman(seq1: []const u8, seq2: []const u8, allocator: std.mem.Allocator) !u16 {
    const len1: usize = seq1.len + 1;
    const len2: usize = seq2.len + 1;

    const matrix = try Matrix.init(len1, len2, allocator);

    var totalmax: u16 = 0;
    for (1..len1) |i| {
        for (1..len2) |j| {
            const match_add: i32 = if (seq1[i - 1] == seq2[j - 1]) match_score else mismatch_penalty;
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

    const input1 = "T";
    std.debug.print("Total set: {}\n", .{items.len});
    var strings = try algorithm(&arena, longallocator, input1);
    std.debug.print("Best match: {s}\n", .{strings[0]});
    std.debug.print("Total set: {}\n", .{items.len});

    const input2 = "Th";
    strings = try algorithm(&arena, longallocator, input2);
    std.debug.print("Best match: {s}\n", .{strings[0]});
    std.debug.print("Total set: {}\n", .{items.len});

    const input3 = "Thr";
    strings = try algorithm(&arena, longallocator, input3);
    std.debug.print("Best match: {s}\n", .{strings[0]});
    std.debug.print("Total set: {}\n", .{items.len});

    const input4 = "Thri";
    strings = try algorithm(&arena, longallocator, input4);
    std.debug.print("Best match: {s}\n", .{strings[0]});
    std.debug.print("Total set: {}\n", .{items.len});

    const input5 = "Thril";
    strings = try algorithm(&arena, longallocator, input5);
    std.debug.print("Best match: {s}\n", .{strings[0]});
    std.debug.print("Total set: {}\n", .{items.len});
}

test "real read" {
    const startouter = std.time.milliTimestamp();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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

    const input = "Thr";

    var score: u16 = undefined;
    var over20: u16 = 0;
    var maxranked: u16 = 0;
    var algotime: i64 = 0;
    for (items) |item| {
        if (item.string) |string| {
            defer {
                _ = arena.reset(.retain_capacity);
            }
            const start = std.time.microTimestamp();
            score = smithwaterman(input, string, allocator) catch unreachable;
            const timespent = std.time.microTimestamp() - start;
            algotime += timespent;
            // if (score >= input.len * 2) {
            //     maxranked += 1;
            //     std.debug.print("strings: {s} - {s}\n", .{ input, string });
            //     std.debug.print("score: {}\n", .{score});
            // }
            if (score == 0) {
                maxranked += 1;
                std.debug.print("strings: {s} - {s}\n", .{ input, string });
                std.debug.print("score: {}\n", .{score});
            }
            over20 += if (timespent > 20) 1 else 0;
        }
    }
    const end = std.time.milliTimestamp() - startouter;
    std.debug.print("over 20 microseconds: {}\n", .{over20});
    std.debug.print("total algo time {}\n", .{algotime});
    std.debug.print("total time spent: {}\n", .{end});
}

test "teststrings" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sequence0 = "Tristan Lay";
    const sequence1 = "Tristan Thompson";
    const sequence2 = "Tristan Jet";
    const sequence3 = "Mikael J";
    const sequence4 = "Michael Jackson";
    const slices = &[_][]const u8{ sequence1, sequence2, sequence3, sequence4 };

    var score: u16 = undefined;
    for (0..slices.len) |i| {
        defer {
            _ = arena.reset(.retain_capacity);
        }
        const start = std.time.microTimestamp();
        score = smithwaterman(sequence0, slices[i], allocator) catch unreachable;
        const timespent = std.time.microTimestamp() - start;
        std.debug.print("strings: {s} - {s}\n", .{ sequence0, slices[i] });
        std.debug.print("score: {}\n", .{score});
        std.debug.print("time: {}\n", .{timespent});
    }
}

test "length" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sequence1 = "Tristan Lay";
    const sequence2 = "Tristan Jet";
    const sequence3 = "Mikael J";
    const sequence4 = "Michael Jackson";

    var len1: usize = sequence1.len + 1;
    var len2: usize = sequence2.len + 1;

    var matrix: Matrix = try Matrix.init(len1, len2, allocator);
    std.debug.print("width: {}\n", .{matrix.data.len});
    try std.testing.expect(matrix.data.len == 12);
    try std.testing.expect(matrix.data[0].len == 12);
    _ = arena.reset(.retain_capacity);
    len1 = sequence3.len + 1;
    len2 = sequence4.len + 1;
    matrix = try Matrix.init(len1, len2, allocator);
    try std.testing.expect(matrix.data.len == 9);
    try std.testing.expect(matrix.data[0].len == 16);
}
