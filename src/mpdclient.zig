const std = @import("std");
const util = @import("util.zig");
const state = @import("state.zig");
const Idle = state.Idle;
const Event = state.Event;
const log = util.log;

const net = std.net;
const mem = std.mem;
const fmt = std.fmt;
const debug = std.debug;
const ArrayList = std.ArrayList;

var host: [4]u8 = .{ 127, 0, 0, 1 };
var port: u16 = 6600;

var cmdStream: std.net.Stream = undefined;
var idleStream: std.net.Stream = undefined;

var cmdBuf: [128]u8 = undefined;

const StreamType = enum {
    command,
    idle,
};

pub const MpdError = error{
    StreamReadError,
    StreamWriteError,
    InvalidResponse,
    ConnectionError,
    AllocatorError,
    EndOfStream,
    OutOfMemory,
    TooLong,
    NoSongs,
};

/// Common function to handle setting string values in a fixed buffer
fn setStringValue(buffer: []u8, value: []const u8, max_len: usize) ![]const u8 {
    if (value.len > max_len) {
        mem.copyForwards(u8, buffer, value[0..max_len]);
        return buffer[0..max_len];
    }
    mem.copyForwards(u8, buffer, value);
    return buffer[0..value.len];
}

/// Sends an MPD command and checks for OK response
fn sendCommand(command: []const u8) !void {
    try connSend(command, &cmdStream);
    _ = try cmdStream.read(&cmdBuf);
    if (mem.eql(u8, cmdBuf[0..3], "OK\n")) return;
    if (mem.eql(u8, cmdBuf[0..3], "ACK")) {
        const mpd_err = cmdBuf[5..9];
        util.log("{s}", .{mpd_err});
        if (mem.eql(u8, mpd_err, "55@0")) return error.MpdNotPlaying;
        if (mem.eql(u8, mpd_err[0..3], "2@0")) return error.MpdBadIndex;
        return error.MpdError;
    }
    return error.ReadError;
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
        if (mem.startsWith(u8, line, "ACK")) return MpdError.InvalidResponse;

        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];
            try callback_fn(key, value, context);
        }
    }
}

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
    pos: usize = undefined,
    id: usize = undefined,

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
        self.pos = try fmt.parseUnsigned(usize, pos, 10);
    }

    pub fn setId(self: *CurrentSong, id: []const u8) !void {
        self.id = try fmt.parseUnsigned(usize, id, 10);
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
            } else return MpdError.InvalidResponse;
        }
    }
};

pub fn handleArgs(arg_host: ?[4]u8, arg_port: ?u16) void {
    if (arg_host) |arg| host = arg;
    if (arg_port) |arg| port = arg;
}

pub fn connect(stream_type: StreamType, nonblock: bool) !void {
    const peer = net.Address.initIp4(host, port);
    // Connect to peer
    const stream = switch (stream_type) {
        .idle => &idleStream,
        .command => &cmdStream,
    };

    stream.* = net.tcpConnectToAddress(peer) catch return error.NoMpd;

    const bytes_read = try stream.read(&cmdBuf);
    const received_data = cmdBuf[0..bytes_read];

    if (bytes_read < 2 or !mem.eql(u8, received_data[0..2], "OK")) {
        log("BAD! connection", .{});
        return error.InvalidResponse;
    }

    if (nonblock) {
        const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch |err| {
            log("Error getting socket flags: {}", .{err});
            return err;
        };
        // Use direct constant instead of NONBLOCK which may not be available on all platforms
        // const NONBLOCK = 0x0004; // This is O_NONBLOCK value for most systems including macOS
        const NONBLOCK = 0o4000;
        _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | NONBLOCK) catch |err| {
            log("Error setting socket to nonblocking: {}", .{err});
            return err;
        };
    }
}

pub fn checkConnection() !void {
    try sendCommand("ping\n");
    log("PINGED", .{});
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

pub fn checkIdle() ![2]?Event {
    var reader = idleStream.reader();
    var event: [2]?Event = .{ null, null };
    while (true) {
        const line = reader.readUntilDelimiter(&cmdBuf, '\n') catch |err| switch (err) {
            error.WouldBlock => return .{ null, null }, // No data available
            error.EndOfStream => return error.IdleConnectionClosed,
            else => return err,
        };
        if (mem.eql(u8, line, "OK")) break;
        if (mem.startsWith(u8, line, "ACK")) return MpdError.InvalidResponse;

        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const value = line[separator_index + 2 ..];

            if (mem.eql(u8, value, "player")) event[0] = Event{ .idle = Idle.player };
            if (mem.eql(u8, value, "playlist")) event[1] = Event{ .idle = Idle.queue };
        }
    }
    try initIdle();
    return event;
}

pub fn togglePlaystate(isPlaying: bool) !bool {
    if (isPlaying) {
        try sendCommand("pause\n");
        return false;
    }
    try sendCommand("play\n");
    return true;
}

pub fn seek(dir: enum { forward, backward }, seconds: u8) !void {
    const command: []const u8 = switch (dir) {
        .forward => try fmt.bufPrint(&cmdBuf, "seekcur +{}\n", .{seconds}),
        .backward => try fmt.bufPrint(&cmdBuf, "seekcur -{}\n", .{seconds}),
    };
    try sendCommand(command);
}

pub fn nextSong() !void {
    sendCommand("next\n") catch |e| switch (e) {
        error.MpdNotPlaying => return,
        else => return e,
    };
}

pub fn prevSong() !void {
    sendCommand("previous\n") catch |e| switch (e) {
        error.MpdNotPlaying => return,
        else => return e,
    };
}

pub fn playByPos(allocator: mem.Allocator, pos: usize) !void {
    const command = try fmt.allocPrint(allocator, "play {}\n", .{pos});
    try sendCommand(command);
}

pub fn playById(allocator: mem.Allocator, id: usize) !void {
    const command = try fmt.allocPrint(allocator, "playid {}\n", .{id});
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

pub const Queue = struct {
    const MAX_LEN = 64;

    allocator: mem.Allocator,
    array: ArrayList(QSong),
    items: []QSong,

    pub fn append(self: *Queue, song: QSong) !void {
        var duped_title: ?[]const u8 = null;
        var duped_artist: ?[]const u8 = null;

        if (song.title) |title| {
            const slice = if (title.len > MAX_LEN) title[0..MAX_LEN] else title;
            duped_title = try self.allocator.dupe(u8, slice);
        }
        if (song.artist) |artist| {
            const slice = if (artist.len > MAX_LEN) artist[0..MAX_LEN] else artist;
            duped_artist = try self.allocator.dupe(u8, slice);
        }

        try self.array.append(.{
            .title = duped_title,
            .artist = duped_artist,
            .time = song.time,
            .pos = song.pos,
            .id = song.id,
        });
    }

    pub fn getItems(self: *const Queue) []QSong {
        return self.array.items;
    }
};

pub const QSong = struct {
    title: ?[]const u8,
    artist: ?[]const u8,
    time: u16,
    pos: usize,
    id: usize,
};

pub fn getQueue(respAllocator: mem.Allocator, queue: *Queue) !void {
    const command = "playlistinfo\n";
    const data = try readLargeResponse(respAllocator, command);
    var lines = processLargeResponse(data) catch |err| switch (err) {
        error.NoSongs => return,
        else => return err,
    };

    var current: ?QSong = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "file:")) {
            // If there's a current song, add it to the list
            if (current) |song| {
                try queue.append(song);
            }
            current = QSong{
                .title = null,
                .artist = null,
                .time = undefined,
                .pos = undefined,
                .id = undefined,
            };
        } else if (current != null) {
            // Parse key-value pairs for the current song
            if (std.mem.startsWith(u8, line, "Title:")) {
                current.?.title = std.mem.trimLeft(u8, line[6..], " ");
            } else if (std.mem.startsWith(u8, line, "Artist:")) {
                current.?.artist = std.mem.trimLeft(u8, line[7..], " ");
            } else if (std.mem.startsWith(u8, line, "Time:")) {
                const time_str = std.mem.trimLeft(u8, line[5..], " ");
                current.?.time = try std.fmt.parseInt(u16, time_str, 10);
            } else if (std.mem.startsWith(u8, line, "Pos:")) {
                const pos_str = std.mem.trimLeft(u8, line[4..], " ");
                current.?.pos = try std.fmt.parseInt(u8, pos_str, 10);
            } else if (std.mem.startsWith(u8, line, "Id:")) {
                const id_str = std.mem.trimLeft(u8, line[3..], " ");
                current.?.id = try std.fmt.parseInt(usize, id_str, 10);
            }
        }
    }
    // Add the last song if it exists
    if (current) |song| try queue.append(song);
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

pub fn getPlayState(respAlloc: mem.Allocator) !bool {
    const data = try readLargeResponse(respAlloc, "status\n");
    var lines = try processLargeResponse(data);

    var is_playing: bool = undefined;
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (mem.startsWith(u8, line, "state: ")) {
            is_playing = switch (line[8]) {
                'a' => false, // state: paused
                'l' => true, // state: playing
                't' => false, // state: stop
                else => return error.BadStateRead,
            };
        }
    }
    return is_playing;
}

/// Reads a large response from MPD for commands that may return a lot of data
/// - tempAllocator: Used for the raw response data (should be freed after processing)
/// - command: The MPD command to send
/// Returns the complete raw response with trailing "OK\n"
pub fn readLargeResponse(tempAllocator: mem.Allocator, command: []const u8) MpdError![]u8 {
    connSend(command, &cmdStream) catch return MpdError.StreamWriteError;

    var list = std.ArrayList(u8).init(tempAllocator);
    errdefer list.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = cmdStream.read(buf[0..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return MpdError.StreamReadError,
        };

        if (bytes_read == 0) {
            if (mem.endsWith(u8, list.items, "OK\n")) {
                break;
            } else {
                return MpdError.InvalidResponse;
            }
        }

        list.appendSlice(buf[0..bytes_read]) catch return MpdError.AllocatorError;

        if (mem.endsWith(u8, list.items, "OK\n")) {
            break;
        }
    }

    return try list.toOwnedSlice();
}

fn processLargeResponse(data: []const u8) MpdError!mem.SplitIterator(u8, .scalar) {
    if (mem.startsWith(u8, data, "ACK")) return MpdError.InvalidResponse;
    if (mem.startsWith(u8, data, "OK")) return MpdError.NoSongs;
    return mem.splitScalar(u8, data, '\n');
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
pub fn getAllAlbums(heapAllocator: mem.Allocator, respAllocator: std.mem.Allocator) ![][]const u8 {
    return getAllType("album", heapAllocator, respAllocator);
}

pub fn getAllArtists(heapAllocator: mem.Allocator, respAllocator: std.mem.Allocator) ![][]const u8 {
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
    album: ?[]const u8,
};

pub const SongStringAndUri = struct {
    string: []const u8,
    uri: []const u8,
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
    filter: Filter_Songs,
    temp_alloc: mem.Allocator,
    persist_alloc: mem.Allocator,
) ![]SongStringAndUri {
    var artist: []const u8 = "";
    if (filter.artist) |raw| {
        artist = try fmt.allocPrint(temp_alloc, " AND (Artist == \\\"{s}\\\")", .{try escapeMpdString(temp_alloc, raw)});
    }
    const album = filter.album orelse return error.FilterError;
    const escaped_album = try escapeMpdString(temp_alloc, album);
    const command = try fmt.allocPrint(temp_alloc, "find \"((Album == \\\"{s}\\\"){s})\"\n", .{ escaped_album, artist });

    const data = try readLargeResponse(temp_alloc, command);
    var lines = try processLargeResponse(data);
    var songs = ArrayList(SongStringAndUri).init(persist_alloc);

    var current_uri: ?[]const u8 = null;
    var current_title: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];

            if (mem.eql(u8, key, "file")) {
                // If we have a previous song with both URI and title, add it
                if (current_uri != null and current_title != null) {
                    try songs.append(SongStringAndUri{
                        .uri = current_uri.?,
                        .string = current_title.?,
                    });
                }
                // Start a new song
                current_uri = try persist_alloc.dupe(u8, value);
                current_title = null;
            } else if (mem.eql(u8, key, "Title")) {
                current_title = try persist_alloc.dupe(u8, value);
            }
        }
    }

    // Add the last song if it has both URI and title
    if (current_uri != null and current_title != null) {
        try songs.append(SongStringAndUri{
            .uri = current_uri.?,
            .string = current_title.?,
        });
    }

    return try songs.toOwnedSlice();
}

pub fn titlesFromTracks(tracks: []const SongStringAndUri, allocator: mem.Allocator) ![][]const u8 {
    var titles = try allocator.alloc([]const u8, tracks.len);
    for (tracks, 0..) |track, i| {
        titles[i] = track.string;
    }
    return titles;
}

pub fn findAdd(song: *const Find_add_Song, allocator: mem.Allocator) !void {
    const artist = if (song.artist) |artist| try fmt.allocPrint(allocator, " AND (Artist == \\\"{s}\\\")", .{artist}) else "";
    const album = if (song.album) |album| try fmt.allocPrint(allocator, " AND (Album == \\\"{s}\\\")", .{album}) else "";

    const command = try fmt.allocPrint(allocator, "findadd \"((Title == \\\"{s}\\\"){s}{s})\"\n", .{ song.title, album, artist });
    log("command: {s}", .{command});
    try sendCommand(command);
}

pub fn addAllFromArtist(allocator: mem.Allocator, artist: []const u8) !void {
    const cmd = try fmt.allocPrint(allocator, "findadd \"(Artist == \\\"{s}\\\")\"\n", .{artist});
    try sendCommand(cmd);
}

test "addFromArtist" {
    var heapArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer heapArena.deinit();
    const heapAllocator = heapArena.allocator();

    _ = try connect(.command, false);

    const artist = "Playboi Carti";
    try addAllFromArtist(heapAllocator, artist);
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
    log("connected lal lala \n", .{});

    const songs = try findAlbumsFromArtists("Playboi Carti", tempAllocator, heapAllocator);
    _ = tempArena.reset(.free_all);
    for (songs) |song| {
        log("{s}", .{song});
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
    log("connected\n", .{});

    const filter = Filter_Songs{
        .artist = "Playboi Carti",
        .album = "Die Lit",
    };

    const songs = try findTracksFromAlbum(&filter, tempAllocator, heapAllocator);
    _ = tempArena.reset(.free_all);
    for (songs) |song| {
        log("Title: {s}", .{song.title});
        log("URI: {s}", .{song.uri});
    }
}

test "findAdd" {
    var heapArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer heapArena.deinit();
    const heapAllocator = heapArena.allocator();

    var wrkbuf: [16]u8 = undefined;
    _ = try connect(wrkbuf[0..16], .command, false);
    log("connected\n", .{});

    const song = Find_add_Song{
        .artist = null,
        .album = "Thriller",
        .title = "Thriller",
    };

    try findAdd(&song, heapAllocator);
}

fn escapeMpdString(allocator: mem.Allocator, str: []const u8) ![]u8 {
    // Initialize a dynamic array to build the escaped string
    var result = ArrayList(u8).init(allocator);
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

pub fn listAllData(respAllocator: std.mem.Allocator) ![]u8 {
    return try readLargeResponse(respAllocator, "listallinfo\n");
}

pub fn getAllSongs(heapAllocator: mem.Allocator, data: []const u8) ![]SongStringAndUri {
    var songs = ArrayList(SongStringAndUri).init(heapAllocator);
    var lines = try processLargeResponse(data);

    var current_uri: ?[]const u8 = null;
    var current_title: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];

            if (mem.eql(u8, key, "file")) {
                // If we have a previous song with both URI and title, add it
                if (current_uri != null and current_title != null) {
                    try songs.append(SongStringAndUri{
                        .uri = current_uri.?,
                        .string = current_title.?,
                    });
                }
                // Start a new song
                current_uri = try heapAllocator.dupe(u8, value);
                current_title = null;
            } else if (mem.eql(u8, key, "Title")) {
                current_title = try heapAllocator.dupe(u8, value);
            }
        }
    }

    // Add the last song if it has both URI and title
    if (current_uri != null and current_title != null) {
        try songs.append(SongStringAndUri{
            .uri = current_uri.?,
            .string = current_title.?,
        });
    }

    return try songs.toOwnedSlice();
}

pub fn getSongStringAndUri(heapAllocator: mem.Allocator, data: []const u8) ![]SongStringAndUri {
    var array = std.ArrayList(SongStringAndUri).init(heapAllocator);
    var lines = try processLargeResponse(data);
    var current_uri: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var artist: ?[]const u8 = null;
    var album: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (mem.indexOf(u8, line, ": ")) |separator_index| {
            const key = line[0..separator_index];
            const value = line[separator_index + 2 ..];

            if (mem.eql(u8, key, "file")) {
                // Append the previous song if it exists
                if (current_uri != null) {
                    try appendSongStringAndUri(&array, heapAllocator, current_uri.?, title, artist, album);
                }
                // Start a new song
                current_uri = try heapAllocator.dupe(u8, value);
                title = null;
                artist = null;
                album = null;
            } else if (mem.eql(u8, key, "Title")) {
                title = value;
            } else if (mem.eql(u8, key, "Artist")) {
                artist = value;
            } else if (mem.eql(u8, key, "Album")) {
                album = value;
            }
            // Ignore other keys like "directory", "Last-Modified", etc.
        }
    }

    // Append the last song if it exists
    if (current_uri != null) {
        try appendSongStringAndUri(&array, heapAllocator, current_uri.?, title, artist, album);
    }

    return array.toOwnedSlice();
}

// Helper function to append a SongStringAndUri with a properly constructed string
fn appendSongStringAndUri(
    array: *std.ArrayList(SongStringAndUri),
    heapAllocator: mem.Allocator,
    uri: []const u8,
    title: ?[]const u8,
    artist: ?[]const u8,
    album: ?[]const u8,
) !void {
    var parts = std.ArrayList([]const u8).init(heapAllocator);
    defer parts.deinit();

    // Add non-null tags to the parts list
    if (title) |t| try parts.append(t);
    if (artist) |a| try parts.append(a);
    if (album) |al| try parts.append(al);

    if (parts.items.len == 0) return;

    const str = try std.mem.join(heapAllocator, " ", parts.items);
    try array.append(SongStringAndUri{
        .string = str,
        .uri = uri,
    });
}

pub fn addFromUri(allocator: mem.Allocator, uri: []const u8) !void {
    const command = try fmt.allocPrint(allocator, "add \"{s}\"\n", .{uri});
    try sendCommand(command);
}

pub fn addList(allocator: mem.Allocator, list: []const SongStringAndUri) !void {
    try connSend("command_list_begin\n", &cmdStream);
    for (list) |item| {
        const command = try fmt.allocPrint(allocator, "add \"{s}\"\n", .{item.uri});
        try connSend(command, &cmdStream);
    }
    try sendCommand("command_list_end\n");
}

pub fn rmFromPos(allocator: mem.Allocator, pos: usize) !void {
    const command = try fmt.allocPrint(allocator, "delete {}\n", .{pos});
    sendCommand(command) catch |e| switch (e) {
        error.MpdNotPlaying => return e,
        else => return e,
    };
}

pub fn rmRangeFromPos(allocator: mem.Allocator, pos: usize) !void {
    const command = try fmt.allocPrint(allocator, "delete {}:\n", .{pos});
    try sendCommand(command);
}

pub fn clearQueue() !void {
    try sendCommand("clear\n");
}
