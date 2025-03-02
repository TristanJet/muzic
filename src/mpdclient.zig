const std = @import("std");
const util = @import("util.zig");
const state = @import("state.zig");
const Idle = state.Idle;
const Event = state.Event;
const assert = std.debug.assert;
const net = std.net;

const host = "127.0.0.1";
const port = 6600;

var cmdStream: std.net.Stream = undefined;
var idleStream: std.net.Stream = undefined;

const StreamType = enum {
    command,
    idle,
};

pub const Searchable = struct {
    string: ?[]const u8,
    uri: []const u8,
};

pub const Time = struct {
    elapsed: u16,
    duration: u16,
};

pub const CurrentSong = struct {
    const MAX_LEN = 64;

    bufTitle: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    title: []const u8 = &[_]u8{},
    bufArtist: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    artist: []const u8 = &[_]u8{},
    bufAlbum: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    album: []const u8 = &[_]u8{},
    bufTrackno: [2]u8 = [_]u8{0} ** 2,
    trackno: []const u8 = &[_]u8{},
    time: Time = Time{
        .elapsed = undefined,
        .duration = undefined,
    },
    pos: u8 = undefined,
    id: u8 = undefined,

    pub fn init(self: *CurrentSong) void {
        // Point title to the correct part of bufTitle
        self.title = self.bufTitle[0..0];
        self.artist = self.bufArtist[0..0];
        self.album = self.bufAlbum[0..0];
        self.trackno = self.bufTrackno[0..0];
    }

    pub fn setTitle(self: *CurrentSong, title: []const u8) !void {
        if (title.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.bufTitle[0..title.len], title);
        self.title = self.bufTitle[0..title.len];
    }

    pub fn setArtist(self: *CurrentSong, artist: []const u8) !void {
        if (artist.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.bufArtist[0..artist.len], artist);
        self.artist = self.bufArtist[0..artist.len];
    }

    pub fn setAlbum(self: *CurrentSong, album: []const u8) !void {
        if (album.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.bufAlbum[0..album.len], album);
        self.album = self.bufAlbum[0..album.len];
    }

    pub fn setTrackno(self: *CurrentSong, trackno: []const u8) !void {
        if (trackno.len > 2) return error.TooLong;
        std.mem.copyForwards(u8, self.bufTrackno[0..trackno.len], trackno);
        self.trackno = self.bufTrackno[0..trackno.len];
    }

    pub fn setPos(self: *CurrentSong, pos: []const u8) !void {
        if (pos.len > 3) return error.TooLong;
        const int: u8 = try std.fmt.parseInt(u8, pos[0..], 10);
        self.pos = int;
    }

    pub fn setId(self: *CurrentSong, id: []const u8) !void {
        if (id.len > 3) return error.TooLong;
        const int: u8 = try std.fmt.parseInt(u8, id[0..], 10);
        self.id = int;
    }
};

pub const QSong = struct {
    const MAX_LEN = 64;

    bufTitle: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    title: []const u8,
    bufArtist: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    artist: []const u8,
    time: u16,
    pos: u8,
    id: u8,

    pub fn init() QSong {
        var song = QSong{
            .title = &[_]u8{}, // temporary empty slice
            .artist = &[_]u8{},
            .time = undefined,
            .pos = undefined,
            .id = undefined,
        };
        // Point title to the correct part of bufTitle
        song.title = song.bufTitle[0..0];
        song.artist = song.bufArtist[0..0];
        return song;
    }

    pub fn setTitle(self: *QSong, title: []const u8) !void {
        if (title.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.bufTitle[0..title.len], title);
        self.title = self.bufTitle[0..title.len];
    }

    pub fn setArtist(self: *QSong, artist: []const u8) !void {
        if (artist.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.bufArtist[0..artist.len], artist);
        self.artist = self.bufArtist[0..artist.len];
    }

    pub fn setPos(self: *QSong, pos: []const u8) !void {
        if (pos.len > 3) return error.TooLong;
        const int: u8 = try std.fmt.parseInt(u8, pos[0..], 10);
        self.pos = int;
    }

    pub fn setId(self: *QSong, id: []const u8) !void {
        if (id.len > 3) return error.TooLong;
        const int: u8 = try std.fmt.parseInt(u8, id[0..], 10);
        self.id = int;
    }

    pub fn setDuration(self: *QSong, duration: []const u8) !void {
        if (duration.len > 3) return error.TooLong;
        const int: u64 = try std.fmt.parseInt(u64, duration, 10);
        self.time.duration = int;
    }
};

pub const Queue = struct {
    const MAX_SONGS = 20;
    pub const Error = error{BufferFull};

    items: [MAX_SONGS]QSong = undefined,
    len: usize = 0,

    pub fn append(self: *Queue, song: QSong) !void {
        if (self.len >= MAX_SONGS) return Error.BufferFull;

        // Create a completely new QSong and copy the data
        self.items[self.len] = QSong.init();
        try self.items[self.len].setTitle(song.title);
        try self.items[self.len].setArtist(song.artist);
        self.items[self.len].id = song.id;
        self.items[self.len].pos = song.pos;
        self.items[self.len].time = song.time;

        self.len += 1;
    }

    pub fn clear(self: *Queue) void {
        self.len = 0;
    }
};

pub fn connect(buffer: []u8, stream_type: StreamType, nonblock: bool) !void {
    const peer = try net.Address.parseIp4(host, port);
    // Connect to peer
    const stream = switch (stream_type) {
        .idle => &idleStream,
        .command => &cmdStream,
    };

    stream.* = try net.tcpConnectToAddress(peer);

    const bytes_read = try stream.read(buffer);
    const received_data = buffer[0..bytes_read];

    if (bytes_read < 2 or !std.mem.eql(u8, received_data[0..2], "OK")) {
        util.log("BAD! connection", .{});
        return error.InvalidResponse;
    }

    if (nonblock) {
        const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch |err| {
            util.log("Error getting socket flags: {}", .{err});
            return err;
        };
        // Use direct constant instead of NONBLOCK which may not be available on all platforms
        const NONBLOCK = 0x0004; // This is O_NONBLOCK value for most systems including macOS
        _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | NONBLOCK) catch |err| {
            util.log("Error setting socket to nonblocking: {}", .{err});
            return err;
        };
    }
}

pub fn checkConnection() !void {
    var buf: [3]u8 = undefined;
    try connSend("ping\n", &cmdStream);
    util.log("PINGED", .{});
    _ = try cmdStream.read(&buf);
    if (!std.mem.eql(u8, buf[0..2], "OK")) {
        util.log("BAD! connection", .{});
        return error.InvalidResponse;
    }
}

fn connSend(data: []const u8, stream: *std.net.Stream) !void {
    // Sending data to peer
    var writer = stream.writer();
    _ = try writer.write(data);
    // Or just using `writer.writeAll`
    // try writer.writeAll("hello zig");
}

pub fn disconnect(stream_type: StreamType) void {
    const stream = switch (stream_type) {
        .command => cmdStream,
        .idle => idleStream,
    };
    stream.close();
}

pub fn initIdle() !void {
    try connSend("idle player playlist\n", &idleStream);
}

pub fn checkIdle(buffer: []u8) !?Event {
    assert(buffer.len == 18);
    var reader = idleStream.reader();
    while (true) {
        const line = reader.readUntilDelimiter(buffer, '\n') catch |err| switch (err) {
            error.WouldBlock => return null, // No data available
            error.EndOfStream => return null, // EOF
            else => return err,
        };
        if (std.mem.eql(u8, line, "OK")) break;
        if (std.mem.startsWith(u8, line, "ACK")) return error.MpdError;

        if (std.mem.indexOf(u8, line, ": ")) |separator_index| {
            const value = line[separator_index + 2 ..];

            if (std.mem.eql(u8, value, "player")) return Event{ .idle = Idle.player };
            if (std.mem.eql(u8, value, "playlist")) return Event{ .idle = Idle.queue };
        }
    }
    return null;
}

pub fn togglePlaystate(isPlaying: bool) !bool {
    var buf: [2]u8 = undefined;
    if (isPlaying) {
        try connSend("pause\n", &cmdStream);
        _ = try cmdStream.read(&buf);
        if (!std.mem.eql(u8, buf[0..2], "OK")) return error.BadConnection;
        return false;
    }
    try connSend("play\n", &cmdStream);
    _ = try cmdStream.read(&buf);
    if (!std.mem.eql(u8, buf[0..2], "OK")) return error.BadConnection;
    return true;
}

pub fn seekCur(isForward: bool) !void {
    var buf: [12]u8 = undefined;
    const dir = if (isForward) "+5" else "-5";
    const msg = try std.fmt.bufPrint(&buf, "seekcur {s}\n", .{dir});
    util.log("msg: {s}\n", .{msg});
    try connSend(msg, &cmdStream);
    _ = try cmdStream.read(&buf);
    if (!std.mem.eql(u8, buf[0..2], "OK")) return error.BadConnection;
}

pub fn nextSong() !void {
    var buf: [2]u8 = undefined;
    try connSend("next\n", &cmdStream);
    _ = try cmdStream.read(&buf);
    if (!std.mem.eql(u8, buf[0..2], "OK")) return error.BadConnection;
}

pub fn prevSong() !void {
    var buf: [2]u8 = undefined;
    try connSend("previous\n", &cmdStream);
    _ = try cmdStream.read(&buf);
    if (!std.mem.eql(u8, buf[0..2], "OK")) return error.BadConnection;
}

pub fn playByPos(allocator: std.mem.Allocator, pos: u8) !void {
    var buf: [2]u8 = undefined;
    const string = try std.fmt.allocPrint(allocator, "play {}\n", .{pos});
    try connSend(string, &cmdStream);
    _ = try cmdStream.read(&buf);
    if (!std.mem.eql(u8, buf[0..2], "OK")) return error.BadConnection;
}

pub fn getCurrentSong(
    worallocator: std.mem.Allocator,
    end_index: *usize,
    song: *CurrentSong,
) !void {
    try connSend("currentsong\n", &cmdStream);
    var buf_reader = std.io.bufferedReader(cmdStream.reader());
    var reader = buf_reader.reader();

    const startPoint = end_index.*;
    while (true) {
        defer end_index.* = startPoint;
        var line = reader.readUntilDelimiterAlloc(worallocator, '\n', 1024) catch |err| {
            if (err == error.EndOfStream) return error.EndOfStream;
            return err;
        };

        if (std.mem.eql(u8, line, "OK")) break;
        if (std.mem.startsWith(u8, line, "ACK")) return error.MpdError;

        // Split line into key-value
        if (std.mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];

            // Allocate and store the value based on the key
            if (std.mem.eql(u8, key, "Id")) {
                try song.setId(value);
            } else if (std.mem.eql(u8, key, "Pos")) {
                try song.setPos(value);
            } else if (std.mem.eql(u8, key, "Track")) {
                try song.setTrackno(value);
            } else if (std.mem.eql(u8, key, "Album")) {
                try song.setAlbum(value);
            } else if (std.mem.eql(u8, key, "Title")) {
                try song.setTitle(value);
            } else if (std.mem.eql(u8, key, "Artist")) {
                try song.setArtist(value);
            }
        }
    }
}

// test "currentsong" {
//     var wrkbuf: [1024]u8 = undefined;
//     var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
//     const wrkallocator = wrkfba.allocator();
//
//     _ = try connect(wrkbuf[0..16]);
//
//     var song = CurrentSong.init();
//     _ = try getCurrentSong(wrkallocator, &wrkfba.end_index, &song);
//     _ = try getCurrentTrackTime(wrkallocator, &wrkfba.end_index, &song);
//
//     std.debug.print("Position: {}\n", .{song.pos});
//
//     // Test with the actual value from MPD
//     const expectedTitle = "Amazin'";
//     const expectedArtist = "LL COOL J";
//     const expectedAlbum = "10";
//     // const expectedTrackno = "3";
//     const expectedPos = 3;
//     const expectedDur = 238512;
//     const expectedElap = 100;
//     const expectedId = 4;
//     try std.testing.expect(expectedPos == song.pos);
//     try std.testing.expect(expectedId == song.id);
//     std.debug.print("duration: {}\n", .{song.time.duration});
//     try std.testing.expect(expectedElap < song.time.elapsed);
//     try std.testing.expect(expectedDur == song.time.duration);
//     try std.testing.expectEqualStrings(expectedTitle, song.title);
//     try std.testing.expectEqualStrings(expectedArtist, song.artist);
//     try std.testing.expectEqualStrings(expectedAlbum, song.album);
//     // try std.testing.expectEqualStrings(expectedTrackno, song.trackno);
//
//     try song.setTitle("peepeepoopoo");
//     try song.setArtist("Mr. Peepee");
//     try song.setAlbum("Poo in the pee");
//     try song.setTrackno("69");
//     try std.testing.expectEqualStrings("peepeepoopoo", song.title);
//     try std.testing.expectEqualStrings("Mr. Peepee", song.artist);
//     try std.testing.expectEqualStrings("69", song.trackno);
//     try std.testing.expectEqualStrings("Poo in the pee", song.album);
// }

pub fn getQueue(wrkallocator: std.mem.Allocator, end_index: *usize, bufQueue: *Queue) !void {
    try connSend("playlistinfo\n", &cmdStream);

    var buf_reader = std.io.bufferedReader(cmdStream.reader());
    var reader = buf_reader.reader();

    const startPoint = end_index.*;
    var current_song: ?QSong = null;

    while (true) {
        defer end_index.* = startPoint;
        var line = try reader.readUntilDelimiterAlloc(wrkallocator, '\n', 1024);

        if (std.mem.eql(u8, line, "OK")) {
            // Append the last song if there is one
            if (current_song) |song| {
                try bufQueue.append(song);
            }
            break;
        }
        if (std.mem.startsWith(u8, line, "ACK")) return error.MpdError;

        if (std.mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];

            if (std.mem.eql(u8, "file", key)) {
                // If we have a current song, append it before starting a new one
                if (current_song) |song| {
                    try bufQueue.append(song);
                }
                // Start a new song
                current_song = QSong.init();
            } else if (current_song) |*song| {
                // Only process other fields if we have a current song
                if (std.mem.eql(u8, "Id", key)) {
                    try song.setId(value);
                } else if (std.mem.eql(u8, "Pos", key)) {
                    try song.setPos(value);
                } else if (std.mem.eql(u8, "Time", key)) {
                    song.time = try std.fmt.parseInt(u16, value, 10);
                } else if (std.mem.eql(u8, "Title", key)) {
                    try song.setTitle(value);
                } else if (std.mem.eql(u8, "Artist", key)) {
                    try song.setArtist(value);
                }
            }
        }
    }
}

test "getQueue" {
    var wrkbuf: [1024]u8 = undefined;
    var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
    const wrkallocator = wrkfba.allocator();
    _ = try connect(wrkbuf[0..16]);
    var queue: Queue = Queue{};
    _ = try getQueue(wrkallocator, &wrkfba.end_index, &queue);
    std.debug.print("\nQueue length: {}\n", .{queue.len});
    if (queue.len > 0) {
        std.debug.print("First song - Artist: '{s}', Title: '{s}'\n", .{ queue.items[0].artist, queue.items[0].title });
    }

    for (queue.items) |item| {
        std.debug.print("ARTISTS: {s}\n", .{item.artist});
    }

    std.debug.print("Pos: {}\n", .{queue.items[2].pos});
    std.debug.print("Id test: {}\n", .{queue.items[2].id});
    // try std.testing.expect(queue.items[0].id == 1);
    try std.testing.expect(queue.len == 4);
    try std.testing.expectEqualStrings("Charli xcx", queue.items[0].artist);
}

pub fn getCurrentTrackTime(worallocator: std.mem.Allocator, end_index: *usize, song: *CurrentSong) !void {
    try connSend("status\n", &cmdStream);

    var buf_reader = std.io.bufferedReader(cmdStream.reader());
    var reader = buf_reader.reader();

    const startPoint = end_index.*;
    while (true) {
        defer end_index.* = startPoint;
        var line = try reader.readUntilDelimiterAlloc(worallocator, '\n', 1024);

        if (std.mem.eql(u8, line, "OK")) break;
        if (std.mem.startsWith(u8, line, "ACK")) return error.MpdError;

        if (std.mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];

            if (std.mem.eql(u8, key, "time")) {
                if (std.mem.indexOfScalar(u8, value, ':')) |index| {
                    const elapsedSlice = value[0..index];
                    song.time.elapsed = try std.fmt.parseInt(u16, elapsedSlice, 10);
                    const durationSlice = value[index + 1 ..];
                    song.time.duration = try std.fmt.parseInt(u16, durationSlice, 10);
                } else return error.MpdError;
            }
        }
    }
}

pub fn readListAll(heapAllocator: std.mem.Allocator) ![]u8 {
    try connSend("listallinfo\n", &cmdStream);

    var list = std.ArrayList(u8).init(heapAllocator);
    errdefer list.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = cmdStream.read(buf[0..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => |e| return e,
        };

        if (bytes_read == 0) continue;

        try list.appendSlice(buf[0..bytes_read]);

        if (bytes_read >= 3 and std.mem.endsWith(u8, list.items, "OK\n")) {
            break;
        }
    }

    return list.toOwnedSlice();
}

pub fn getSearchable(heapAllocator: std.mem.Allocator, respAllocator: std.mem.Allocator) ![]Searchable {
    const data = try readListAll(respAllocator);
    if (std.mem.startsWith(u8, data, "ACK")) return error.MpdError;
    if (std.mem.startsWith(u8, data, "OK")) return error.NoSongs;
    var array = std.ArrayList(Searchable).init(heapAllocator);
    var lines = std.mem.splitSequence(u8, data, "\n");

    var current = Searchable{ .string = null, .uri = undefined };
    var title: ?[]const u8 = null;
    var artist: ?[]const u8 = null;
    var album: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];

            if (std.mem.eql(u8, key, "Album")) {
                album = value;

                title = title orelse "";
                artist = artist orelse "";

                current.string = try std.fmt.allocPrint(heapAllocator, "{s} {s} {s}", .{ title.?, artist.?, album.? });
                try array.append(current);
                title = null;
                artist = null;
                album = null;
            } else if (std.mem.eql(u8, key, "Title")) {
                title = value;
            } else if (std.mem.eql(u8, key, "Artist")) {
                artist = value;
            } else if (std.mem.eql(u8, key, "file")) {
                current = Searchable{ .string = null, .uri = undefined };
                current.uri = try heapAllocator.dupe(u8, value);
            }
        }
    }
    return array.toOwnedSlice();
}

pub fn addFromUri(allocator: std.mem.Allocator, uri: []const u8) !void {
    var buf: [2]u8 = undefined;
    const message = try std.fmt.allocPrint(allocator, "add \"{s}\"\n", .{uri});
    try connSend(message, &cmdStream);
    _ = try cmdStream.read(&buf);
    if (!std.mem.eql(u8, buf[0..2], "OK")) return error.BadConnection;
}

pub fn rmFromPos(allocator: std.mem.Allocator, pos: u8) !void {
    var buf: [2]u8 = undefined;
    const message = try std.fmt.allocPrint(allocator, "delete {}\n", .{pos});
    try connSend(message, &cmdStream);
    _ = try cmdStream.read(&buf);
    if (!std.mem.eql(u8, buf[0..2], "OK")) return error.BadConnection;
}

test "do it work" {
    const start = std.time.milliTimestamp();
    var respArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const respAllocator = respArena.allocator();

    var heapArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer heapArena.deinit();
    const heapAllocator = heapArena.allocator();

    var wrkbuf: [16]u8 = undefined;
    _ = try connect(wrkbuf[0..16], &cmdStream, false);
    std.debug.print("connected\n", .{});

    const items = try getSearchable(heapAllocator, respAllocator);
    var max: []const u8 = "";
    for (items) |item| {
        if (item.string.?.len > max.len) {
            max = item.string.?[0..];
        }
    }
    const end = std.time.milliTimestamp() - start;
    std.debug.print("end index: {}\n", .{respArena.state.end_index});
    respArena.deinit();
    std.debug.print("length: {}\n", .{items.len});
    std.debug.print("string 1000: {s}\n", .{items[2315].string.?});
    std.debug.print("end index: {}\n", .{heapArena.state.end_index});
    std.debug.print("longest string: {s}\nlen:{}\n", .{ max, max.len });
    std.debug.print("Time spent: {}\n", .{end});
    try std.testing.expect(items.len == 2316);
}
