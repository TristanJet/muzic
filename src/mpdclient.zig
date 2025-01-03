const std = @import("std");
const util = @import("util.zig");
const net = std.net;
var stream: std.net.Stream = undefined;

pub const Time = struct {
    elapsed: u64,
    duration: u64,
};

pub const CurrentSong = struct {
    const MAX_LEN = 64;

    bufTitle: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    title: []const u8,
    bufArtist: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    artist: []const u8,
    bufAlbum: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    album: []const u8,
    bufTrackno: [2]u8 = [_]u8{0} ** 2,
    trackno: []const u8,
    time: Time = Time{
        .elapsed = undefined,
        .duration = undefined,
    },
    pos: u8,
    id: u8,

    pub fn init() CurrentSong {
        var song = CurrentSong{
            .title = &[_]u8{}, // temporary empty slice
            .artist = &[_]u8{},
            .album = &[_]u8{},
            .trackno = &[_]u8{},
            .pos = undefined,
            .id = undefined,
        };
        // Point title to the correct part of bufTitle
        song.title = song.bufTitle[0..0];
        song.artist = song.bufArtist[0..0];
        song.album = song.bufAlbum[0..0];
        song.trackno = song.bufTrackno[0..0];
        return song;
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
        if (pos.len > 1) return error.TooLong;
        const int: u8 = try std.fmt.parseInt(u8, pos[0..1], 10);
        self.pos = int;
    }

    pub fn setId(self: *CurrentSong, id: []const u8) !void {
        if (id.len > 1) return error.TooLong;
        const int: u8 = try std.fmt.parseInt(u8, id[0..1], 10);
        self.id = int;
    }
};

const QSong = struct {
    const MAX_LEN = 64;

    bufTitle: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    title: []const u8,
    bufArtist: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    artist: []const u8,
    time: u64,
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
        if (pos.len > 1) return error.TooLong;
        const int: u8 = try std.fmt.parseInt(u8, pos[0..1], 10);
        self.pos = int;
    }

    pub fn setId(self: *QSong, id: []const u8) !void {
        if (id.len > 1) return error.TooLong;
        std.debug.print("ID 1 : {s}\n", .{id});
        const int: u8 = try std.fmt.parseInt(u8, id[0..1], 10);
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

pub fn connect(buffer: []u8) !void {
    const peer = try net.Address.parseIp4("127.0.0.1", 8538);
    // Connect to peer
    stream = try net.tcpConnectToAddress(peer);

    const bytes_read = try stream.read(buffer);
    const received_data = buffer[0..bytes_read];

    if (bytes_read < 2 or !std.mem.eql(u8, received_data[0..2], "OK")) {
        util.log("BAD! connection", .{});
        return error.InvalidResponse;
    }
}

fn connSend(data: []const u8) !void {
    // Sending data to peer
    var writer = stream.writer();
    _ = try writer.write(data);
    // Or just using `writer.writeAll`
    // try writer.writeAll("hello zig");
}

pub fn disconnect() void {
    stream.close();
}

pub fn getCurrentSong(worallocator: std.mem.Allocator, end_index: *usize, song: *CurrentSong) !void {
    try connSend("currentsong\n");
    var buf_reader = std.io.bufferedReader(stream.reader());
    var reader = buf_reader.reader();

    const startPoint = end_index.*;
    while (true) {
        defer end_index.* = startPoint;
        var line = try reader.readUntilDelimiterAlloc(worallocator, '\n', 1024);

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

test "currentsong" {
    var wrkbuf: [1024]u8 = undefined;
    var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
    const wrkallocator = wrkfba.allocator();

    _ = try connect(wrkbuf[0..16]);

    var song = CurrentSong.init();
    _ = try getCurrentSong(wrkallocator, &wrkfba.end_index, &song);
    _ = try getCurrentTrackTime(wrkallocator, &wrkfba.end_index, &song);

    std.debug.print("Position: {}\n", .{song.pos});

    // Test with the actual value from MPD
    const expectedTitle = "Amazin'";
    const expectedArtist = "LL COOL J";
    const expectedAlbum = "10";
    // const expectedTrackno = "3";
    const expectedPos = 3;
    const expectedDur = 238512;
    const expectedElap = 100;
    const expectedId = 4;
    try std.testing.expect(expectedPos == song.pos);
    try std.testing.expect(expectedId == song.id);
    std.debug.print("duration: {}\n", .{song.time.duration});
    try std.testing.expect(expectedElap < song.time.elapsed);
    try std.testing.expect(expectedDur == song.time.duration);
    try std.testing.expectEqualStrings(expectedTitle, song.title);
    try std.testing.expectEqualStrings(expectedArtist, song.artist);
    try std.testing.expectEqualStrings(expectedAlbum, song.album);
    // try std.testing.expectEqualStrings(expectedTrackno, song.trackno);

    try song.setTitle("peepeepoopoo");
    try song.setArtist("Mr. Peepee");
    try song.setAlbum("Poo in the pee");
    try song.setTrackno("69");
    try std.testing.expectEqualStrings("peepeepoopoo", song.title);
    try std.testing.expectEqualStrings("Mr. Peepee", song.artist);
    try std.testing.expectEqualStrings("69", song.trackno);
    try std.testing.expectEqualStrings("Poo in the pee", song.album);
}

pub fn getQueue(wrkallocator: std.mem.Allocator, end_index: *usize, bufQueue: *Queue) !void {
    try connSend("playlistinfo\n");

    var buf_reader = std.io.bufferedReader(stream.reader());
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
                    const seconds = try std.fmt.parseInt(u64, value, 10);
                    song.time = seconds;
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
    try connSend("status\n");

    var buf_reader = std.io.bufferedReader(stream.reader());
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

            if (std.mem.eql(u8, key, "elapsed")) {
                const seconds = try std.fmt.parseFloat(f64, value);
                song.time.elapsed = @intFromFloat(seconds * 1000);
            } else if (std.mem.eql(u8, key, "duration")) {
                const seconds = try std.fmt.parseFloat(f64, value);
                song.time.duration = @intFromFloat(seconds * 1000);
            }
        }
    }
}
