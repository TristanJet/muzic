const std = @import("std");
const util = @import("util.zig");
const state = @import("state.zig");
const Idle = state.Idle;
const Event = state.Event;
const assert = std.debug.assert;

const net = std.net;
const mem = std.mem;
const fmt = std.fmt;
const ArrayList = std.ArrayList;

const host = "127.0.0.1";
const port = 6600;

var cmdStream: std.net.Stream = undefined;
var idleStream: std.net.Stream = undefined;

const StreamType = enum {
    command,
    idle,
};

const MpdError = error{
    InvalidResponse,
    ConnectionError,
    CommandFailed,
    MpdError,
    EndOfStream,
    TooLong,
    NoSongs,
};

/// Common function to handle setting string values in a fixed buffer
fn setStringValue(buffer: []u8, value: []const u8, max_len: usize) ![]const u8 {
    if (value.len > max_len) return error.TooLong;
    mem.copyForwards(u8, buffer[0..value.len], value);
    return buffer[0..value.len];
}

/// Parses a string as a u8
fn parseU8(value: []const u8) !u8 {
    if (value.len > 3) return error.TooLong;
    return try fmt.parseInt(u8, value, 10);
}

/// Sends an MPD command and checks for OK response
fn sendCommand(command: []const u8) !void {
    try connSend(command, &cmdStream);
    var buf: [3]u8 = undefined;
    _ = try cmdStream.read(&buf);
    if (!mem.eql(u8, buf[0..3], "OK\n")) return error.CommandFailed;
}

/// Creates a buffered reader and processes MPD response line by line
fn processResponse(
    comptime Callback: type,
    allocator: mem.Allocator,
    end_index: *usize,
    callback_fn: fn (key: []const u8, value: []const u8, context: *Callback) anyerror!void,
    context: *Callback,
) !void {
    var buf_reader = std.io.bufferedReader(cmdStream.reader());
    var reader = buf_reader.reader();

    const startPoint = end_index.*;

    while (true) {
        defer end_index.* = startPoint;
        var line = try reader.readUntilDelimiterAlloc(allocator, '\n', 1024);

        if (mem.eql(u8, line, "OK")) break;
        if (mem.startsWith(u8, line, "ACK")) return error.MpdError;

        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];
            try callback_fn(key, value, context);
        }
    }
}

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
    const TRACKNO_LEN = 2;

    bufTitle: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    title: []const u8 = &[_]u8{},
    bufArtist: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    artist: []const u8 = &[_]u8{},
    bufAlbum: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    album: []const u8 = &[_]u8{},
    bufTrackno: [TRACKNO_LEN]u8 = [_]u8{0} ** TRACKNO_LEN,
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
        self.title = try setStringValue(&self.bufTitle, title, MAX_LEN);
    }

    pub fn setArtist(self: *CurrentSong, artist: []const u8) !void {
        self.artist = try setStringValue(&self.bufArtist, artist, MAX_LEN);
    }

    pub fn setAlbum(self: *CurrentSong, album: []const u8) !void {
        self.album = try setStringValue(&self.bufAlbum, album, MAX_LEN);
    }

    pub fn setTrackno(self: *CurrentSong, trackno: []const u8) !void {
        self.trackno = try setStringValue(&self.bufTrackno, trackno, TRACKNO_LEN);
    }

    pub fn setPos(self: *CurrentSong, pos: []const u8) !void {
        self.pos = try parseU8(pos);
    }

    pub fn setId(self: *CurrentSong, id: []const u8) !void {
        self.id = try parseU8(id);
    }

    fn handleField(self: *CurrentSong, key: []const u8, value: []const u8) !void {
        if (mem.eql(u8, key, "Id")) {
            try self.setId(value);
        } else if (mem.eql(u8, key, "Pos")) {
            try self.setPos(value);
        } else if (mem.eql(u8, key, "Track")) {
            try self.setTrackno(value);
        } else if (mem.eql(u8, key, "Album")) {
            try self.setAlbum(value);
        } else if (mem.eql(u8, key, "Title")) {
            try self.setTitle(value);
        } else if (mem.eql(u8, key, "Artist")) {
            try self.setArtist(value);
        } else if (mem.eql(u8, key, "time")) {
            if (mem.indexOfScalar(u8, value, ':')) |index| {
                const elapsedSlice = value[0..index];
                self.time.elapsed = try fmt.parseInt(u16, elapsedSlice, 10);
                const durationSlice = value[index + 1 ..];
                self.time.duration = try fmt.parseInt(u16, durationSlice, 10);
            } else return error.MpdError;
        }
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
        self.title = try setStringValue(&self.bufTitle, title, MAX_LEN);
    }

    pub fn setArtist(self: *QSong, artist: []const u8) !void {
        self.artist = try setStringValue(&self.bufArtist, artist, MAX_LEN);
    }

    pub fn setPos(self: *QSong, pos: []const u8) !void {
        self.pos = try parseU8(pos);
    }

    pub fn setId(self: *QSong, id: []const u8) !void {
        self.id = try parseU8(id);
    }

    pub fn setTime(self: *QSong, duration: []const u8) !void {
        if (duration.len > 3) return error.TooLong;
        self.time = try fmt.parseInt(u16, duration, 10);
    }

    fn handleField(self: *QSong, key: []const u8, value: []const u8) !void {
        if (mem.eql(u8, key, "Id")) {
            try self.setId(value);
        } else if (mem.eql(u8, key, "Pos")) {
            try self.setPos(value);
        } else if (mem.eql(u8, key, "Time")) {
            try self.setTime(value);
        } else if (mem.eql(u8, key, "Title")) {
            try self.setTitle(value);
        } else if (mem.eql(u8, key, "Artist")) {
            try self.setArtist(value);
        }
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

    if (bytes_read < 2 or !mem.eql(u8, received_data[0..2], "OK")) {
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
    try sendCommand("ping\n");
    util.log("PINGED", .{});
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
        if (mem.eql(u8, line, "OK")) break;
        if (mem.startsWith(u8, line, "ACK")) return error.MpdError;

        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const value = line[separator_index + 2 ..];

            if (mem.eql(u8, value, "player")) return Event{ .idle = Idle.player };
            if (mem.eql(u8, value, "playlist")) return Event{ .idle = Idle.queue };
        }
    }
    return null;
}

pub fn togglePlaystate(isPlaying: bool) !bool {
    if (isPlaying) {
        try sendCommand("pause\n");
        return false;
    }
    try sendCommand("play\n");
    return true;
}

pub fn seekCur(isForward: bool) !void {
    var buf: [12]u8 = undefined;
    const dir = if (isForward) "+5" else "-5";
    const command = try fmt.bufPrint(&buf, "seekcur {s}\n", .{dir});
    try sendCommand(command);
}

pub fn nextSong() !void {
    try sendCommand("next\n");
}

pub fn prevSong() !void {
    try sendCommand("previous\n");
}

pub fn playByPos(allocator: mem.Allocator, pos: u8) !void {
    const command = try fmt.allocPrint(allocator, "play {}\n", .{pos});
    try sendCommand(command);
}

fn handleCurrentSongField(key: []const u8, value: []const u8, song: *CurrentSong) !void {
    try song.handleField(key, value);
}

pub fn getCurrentSong(
    allocator: mem.Allocator,
    end_index: *usize,
    song: *CurrentSong,
) !void {
    try connSend("currentsong\n", &cmdStream);
    try processResponse(CurrentSong, allocator, end_index, handleCurrentSongField, song);
}

const QueueContext = struct {
    bufQueue: *Queue,
    current_song: ?QSong = null,
};

fn handleQueueField(key: []const u8, value: []const u8, context: *QueueContext) !void {
    if (mem.eql(u8, "file", key)) {
        // If we have a current song, append it before starting a new one
        if (context.current_song) |song| {
            try context.bufQueue.append(song);
        }
        // Start a new song
        context.current_song = QSong.init();
    } else if (context.current_song) |*song| {
        // Only process other fields if we have a current song
        try song.handleField(key, value);
    }
}

pub fn getQueue(allocator: mem.Allocator, end_index: *usize, bufQueue: *Queue) !void {
    try connSend("playlistinfo\n", &cmdStream);

    var context = QueueContext{
        .bufQueue = bufQueue,
        .current_song = null,
    };

    try processResponse(QueueContext, allocator, end_index, handleQueueField, &context);

    // Append the last song if there is one
    if (context.current_song) |song| {
        try bufQueue.append(song);
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

fn handleTrackTimeField(key: []const u8, value: []const u8, song: *CurrentSong) !void {
    if (mem.eql(u8, key, "time")) {
        try song.handleField(key, value);
    }
}

pub fn getCurrentTrackTime(allocator: mem.Allocator, end_index: *usize, song: *CurrentSong) !void {
    try connSend("status\n", &cmdStream);
    try processResponse(CurrentSong, allocator, end_index, handleTrackTimeField, song);
}

/// Reads a large response from MPD for commands that may return a lot of data
/// - tempAllocator: Used for the raw response data (should be freed after processing)
/// - command: The MPD command to send
/// Returns the complete raw response with trailing "OK\n"
pub fn readLargeResponse(tempAllocator: mem.Allocator, command: []const u8) ![]u8 {
    try connSend(command, &cmdStream);

    var list = std.ArrayList(u8).init(tempAllocator);
    errdefer list.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = cmdStream.read(buf[0..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => |e| return e,
        };

        if (bytes_read == 0) continue;

        try list.appendSlice(buf[0..bytes_read]);

        if (bytes_read >= 3 and mem.endsWith(u8, list.items, "OK\n")) {
            break;
        }
    }

    return list.toOwnedSlice();
}

fn processLargeResponse(data: []u8) !mem.SplitIterator(u8, .sequence) {
    if (mem.startsWith(u8, data, "ACK")) return error.MpdError;
    if (mem.startsWith(u8, data, "OK")) return error.NoSongs;
    return mem.splitSequence(u8, data, "\n");
}

fn getAllType(data_type: []const u8, heapAllocator: mem.Allocator, respAllocator: std.mem.Allocator) ![][]const u8 {
    const command = try fmt.allocPrint(respAllocator, "list {s}\n", .{data_type});
    const data = try readLargeResponse(respAllocator, command);
    var lines = try processLargeResponse(data);
    var array = std.ArrayList([]const u8).init(heapAllocator);

    while (lines.next()) |line| {
        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const value = line[separator_index + 2 ..];
            const copied_value = try heapAllocator.dupe(u8, value);
            try array.append(copied_value);
        }
    }

    return array.toOwnedSlice();
}

////
/// list album “(Artist == \”{}\”)” .{Artist}
///
pub fn getAllAlbums(heapAllocator: mem.Allocator, respAllocator: std.mem.Allocator) ![]const []const u8 {
    return getAllType("album", heapAllocator, respAllocator);
}

pub fn getAllSongTitles(heapAllocator: mem.Allocator, respAllocator: std.mem.Allocator) ![]const []const u8 {
    return getAllType("title", heapAllocator, respAllocator);
}

pub fn getAllArtists(heapAllocator: mem.Allocator, respAllocator: std.mem.Allocator) ![]const []const u8 {
    return getAllType("artist", heapAllocator, respAllocator);
}

////
/// findadd "((Title == \"{}\") AND (Album == \"{}\") AND (Artist == \"{}\"))"
///
const Find_add_Song = struct {
    artist: ?[]const u8,
    album: ?[]const u8,
    title: []const u8,
};

pub const Filter_Songs = struct {
    artist: ?[]const u8,
    album: []const u8,
};

pub const SongTitleAndUri = struct {
    titles: [][]const u8,
    uris: [][]const u8,
};

pub fn findAlbumsFromArtists(
    artist: []const u8,
    temp_alloc: mem.Allocator,
    persist_alloc: mem.Allocator,
) ![][]const u8 {
    const escaped = try escapeMpdString(temp_alloc, artist);
    const command = try fmt.allocPrint(temp_alloc, "list album \"(Artist == \\\"{s}\\\")\"\n", .{escaped});
    const data = try readLargeResponse(temp_alloc, command);
    var lines = try processLargeResponse(data);
    var array = std.ArrayList([]const u8).init(persist_alloc);

    while (lines.next()) |line| {
        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const value = line[separator_index + 2 ..];
            const copied_value = try persist_alloc.dupe(u8, value);
            try array.append(copied_value);
        }
    }

    return array.toOwnedSlice();
}

pub fn findTracksFromAlbum(
    filter: *const Filter_Songs,
    temp_alloc: mem.Allocator,
    persist_alloc: mem.Allocator,
) !SongTitleAndUri {
    var artist: []const u8 = "";
    if (filter.artist) |raw| {
        artist = try fmt.allocPrint(temp_alloc, " AND (Artist == \\\"{s}\\\")", .{try escapeMpdString(temp_alloc, raw)});
    }
    const escaped_album = try escapeMpdString(temp_alloc, filter.album);
    util.log("escaped: {s}", .{escaped_album});
    const command = try fmt.allocPrint(temp_alloc, "find \"((Album == \\\"{s}\\\"){s})\"\n", .{ escaped_album, artist });
    util.log("MPD command: {s}", .{command});

    const data = try readLargeResponse(temp_alloc, command);
    var lines = try processLargeResponse(data);
    var array_uri = ArrayList([]const u8).init(persist_alloc);
    var array_title = ArrayList([]const u8).init(persist_alloc);

    while (lines.next()) |line| {
        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];
            if (mem.eql(u8, key, "file")) {
                try array_uri.append(try array_uri.allocator.dupe(u8, value));
            }
            if (mem.eql(u8, key, "Title")) {
                try array_title.append(try array_title.allocator.dupe(u8, value));
            }
        }
    }
    const titles_and_uris = SongTitleAndUri{
        .titles = try array_title.toOwnedSlice(),
        .uris = try array_uri.toOwnedSlice(),
    };

    return titles_and_uris;
}

pub fn findAdd(song: *const Find_add_Song, allocator: mem.Allocator) !void {
    const artist = if (song.artist) |artist| try fmt.allocPrint(allocator, " AND (Artist == \\\"{s}\\\")", .{artist}) else "";
    const album = if (song.album) |album| try fmt.allocPrint(allocator, " AND (Album == \\\"{s}\\\")", .{album}) else "";

    const command = try fmt.allocPrint(allocator, "findadd \"((Title == \\\"{s}\\\"){s}{s})\"\n", .{ song.title, album, artist });
    util.log("command: {s}", .{command});
    try sendCommand(command);
}

test "albumsFromArtist" {
    var heapArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer heapArena.deinit();
    const heapAllocator = heapArena.allocator();

    var tempArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tempArena.deinit();
    const tempAllocator = tempArena.allocator();

    var wrkbuf: [16]u8 = undefined;
    _ = try connect(wrkbuf[0..16], .command, false);
    std.debug.print("connected lal lala \n", .{});

    const songs = try findAlbumsFromArtists("Playboi Carti", tempAllocator, heapAllocator);
    _ = tempArena.reset(.free_all);
    for (songs) |song| {
        util.log("{s}", .{song});
    }
}
test "findTracks" {
    var heapArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer heapArena.deinit();
    const heapAllocator = heapArena.allocator();

    var tempArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tempArena.deinit();
    const tempAllocator = tempArena.allocator();

    var wrkbuf: [16]u8 = undefined;
    _ = try connect(wrkbuf[0..16], .command, false);
    std.debug.print("connected\n", .{});

    const filter = Filter_Songs{
        .artist = "Playboi Carti",
        .album = "Die Lit",
    };

    const songs = try findTracksFromAlbum(&filter, tempAllocator, heapAllocator);
    _ = tempArena.reset(.free_all);
    for (songs.title) |song| {
        util.log("Title: {s}", .{song});
    }
    for (songs.uri) |uri| {
        util.log("URI: {s}", .{uri});
    }
}

test "findAdd" {
    var heapArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer heapArena.deinit();
    const heapAllocator = heapArena.allocator();

    var wrkbuf: [16]u8 = undefined;
    _ = try connect(wrkbuf[0..16], .command, false);
    std.debug.print("connected\n", .{});

    const song = Find_add_Song{
        .artist = null,
        .album = "Thriller",
        .title = "Thriller",
    };

    try findAdd(&song, heapAllocator);
}

test "getAllAlbums" {
    var respArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const respAllocator = respArena.allocator();

    var heapArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer heapArena.deinit();
    const heapAllocator = heapArena.allocator();

    var wrkbuf: [16]u8 = undefined;
    _ = try connect(wrkbuf[0..16], .command, false);
    std.debug.print("connected\n", .{});

    const albums = try getAllAlbums(heapAllocator, respAllocator);
    std.debug.print("resp end index: {}\n", .{respArena.state.end_index});
    std.debug.print("arena end index: {}\n", .{heapArena.state.end_index});
    _ = respArena.reset(.retain_capacity);
    std.debug.print("album 1: {s}\n", .{albums[900]});
    std.debug.print("n albums: {}\n", .{albums.len});
    const artists = try getAllArtists(heapAllocator, respAllocator);
    std.debug.print("resp end index: {}\n", .{respArena.state.end_index});
    std.debug.print("arena end index: {}\n", .{heapArena.state.end_index});
    _ = respArena.reset(.retain_capacity);
    std.debug.print("artist : {s}\n", .{artists[100]});
    std.debug.print("n artists: {}\n", .{artists.len});
    const songs = try getAllSongTitles(heapAllocator, respAllocator);
    std.debug.print("resp end index: {}\n", .{respArena.state.end_index});
    std.debug.print("arena end index: {}\n", .{heapArena.state.end_index});
    _ = respArena.reset(.free_all);
    std.debug.print("song : {s}\n", .{songs[100]});
    std.debug.print("n songs: {}\n", .{songs.len});
    std.debug.print("resp end index: {}\n", .{respArena.state.end_index});
}
fn escapeMpdString(alloc: mem.Allocator, str: []const u8) ![]u8 {
    // Initialize a dynamic array to build the escaped string
    var result = ArrayList(u8).init(alloc);
    defer result.deinit(); // Ensure cleanup if toOwnedSlice fails

    // Iterate over each character in the input string
    for (str) |char| {
        // Escape double quotes and backslashes by prefixing with a backslash
        if (char == '"') {
            try result.append('\\');
            try result.append('\\');
            try result.append('\\');
        }
        try result.append(char);
    }

    return result.toOwnedSlice();
}

pub fn getSearchable(heapAllocator: mem.Allocator, respAllocator: std.mem.Allocator) ![]Searchable {
    const data = try readLargeResponse(respAllocator, "listallinfo\n");
    var lines = try processLargeResponse(data);
    var array = std.ArrayList(Searchable).init(heapAllocator);

    var current = Searchable{ .string = null, .uri = undefined };
    var title: ?[]const u8 = null;
    var artist: ?[]const u8 = null;
    var album: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];

            if (mem.eql(u8, key, "Album")) {
                album = value;

                title = title orelse "";
                artist = artist orelse "";

                current.string = try fmt.allocPrint(heapAllocator, "{s} {s} {s}", .{ title.?, artist.?, album.? });
                try array.append(current);
                title = null;
                artist = null;
                album = null;
            } else if (mem.eql(u8, key, "Title")) {
                title = value;
            } else if (mem.eql(u8, key, "Artist")) {
                artist = value;
            } else if (mem.eql(u8, key, "file")) {
                current = Searchable{ .string = null, .uri = undefined };
                current.uri = try heapAllocator.dupe(u8, value);
            }
        }
    }
    return array.toOwnedSlice();
}

pub fn addFromUri(allocator: mem.Allocator, uri: []const u8) !void {
    const command = try fmt.allocPrint(allocator, "add \"{s}\"\n", .{uri});
    try sendCommand(command);
}

pub fn rmFromPos(allocator: mem.Allocator, pos: u8) !void {
    const command = try fmt.allocPrint(allocator, "delete {}\n", .{pos});
    try sendCommand(command);
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
