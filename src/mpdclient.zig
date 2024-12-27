const std = @import("std");
const util = @import("util.zig");
const net = std.net;
var stream: std.net.Stream = undefined;

pub const Song = struct {
    pub const MAX_LEN = 64;

    bufTitle: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    title: []const u8,
    bufArtist: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    artist: []const u8,
    bufAlbum: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    album: []const u8,
    bufTrackno: [2]u8 = [_]u8{0} ** 2,
    trackno: []const u8,

    pub fn init() Song {
        var song = Song{
            .title = &[_]u8{}, // temporary empty slice
            .artist = &[_]u8{},
            .album = &[_]u8{},
            .trackno = &[_]u8{},
        };
        // Point title to the correct part of bufTitle
        song.title = song.bufTitle[0..0];
        song.artist = song.bufArtist[0..0];
        song.album = song.bufAlbum[0..0];
        song.trackno = song.bufTrackno[0..0];
        return song;
    }

    pub fn setTitle(self: *Song, title: []const u8) !void {
        if (title.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.bufTitle[0..title.len], title);
        self.title = self.bufTitle[0..title.len];
    }

    pub fn setArtist(self: *Song, artist: []const u8) !void {
        if (artist.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.bufArtist[0..artist.len], artist);
        self.artist = self.bufArtist[0..artist.len];
    }

    pub fn setAlbum(self: *Song, album: []const u8) !void {
        if (album.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.bufAlbum[0..album.len], album);
        self.album = self.bufAlbum[0..album.len];
    }

    pub fn setTrackno(self: *Song, trackno: []const u8) !void {
        if (trackno.len > 2) return error.TooLong;
        std.mem.copyForwards(u8, self.bufTrackno[0..trackno.len], trackno);
        self.trackno = self.bufTrackno[0..trackno.len];
    }
};

pub const Time = struct {
    elapsed: u64,
    duration: u64,
};

pub fn connect(
    buffer: []u8,
) !void {
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

pub fn getCurrentSong(
    worallocator: std.mem.Allocator,
    end_index: *usize,
    song: *Song,
) !void {
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
            if (std.mem.eql(u8, key, "Title")) {
                try song.setTitle(value);
            } else if (std.mem.eql(u8, key, "Artist")) {
                try song.setArtist(value);
            } else if (std.mem.eql(u8, key, "Album")) {
                try song.setAlbum(value);
            } else if (std.mem.eql(u8, key, "Track")) {
                try song.setTrackno(value);
            }
        }
    }
}

test "currentsong" {
    var wrkbuf: [1024]u8 = undefined;
    var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
    const wrkallocator = wrkfba.allocator();

    _ = try connect(wrkbuf[0..16]);

    var song = Song.init();
    _ = try getCurrentSong(wrkallocator, &wrkfba.end_index, &song);

    // Test with the actual value from MPD
    const expectedTitle = "Feenin'";
    const expectedArtist = "Jodeci";
    const expectedAlbum = "Diary of a Mad Band";
    const expectedTrackno = "3";
    try std.testing.expectEqualStrings(expectedTitle, song.title);
    try std.testing.expectEqualStrings(expectedArtist, song.artist);
    try std.testing.expectEqualStrings(expectedAlbum, song.album);
    try std.testing.expectEqualStrings(expectedTrackno, song.trackno);

    try song.setTitle("peepeepoopoo");
    try song.setArtist("Mr. Peepee");
    try song.setAlbum("Poo in the pee");
    try song.setTrackno("69");
    try std.testing.expectEqualStrings("peepeepoopoo", song.title);
    try std.testing.expectEqualStrings("Mr. Peepee", song.artist);
    try std.testing.expectEqualStrings("69", song.trackno);
    try std.testing.expectEqualStrings("Poo in the pee", song.album);
}

pub fn getTime(
    worallocator: std.mem.Allocator,
    end_index: *usize,
) !Time {
    try connSend("status\n");

    var buf_reader = std.io.bufferedReader(stream.reader());
    var reader = buf_reader.reader();

    var time = Time{
        .elapsed = 0,
        .duration = 0,
    };

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
                time.elapsed = @intFromFloat(seconds * 1000);
            } else if (std.mem.eql(u8, key, "duration")) {
                const seconds = try std.fmt.parseFloat(f64, value);
                time.duration = @intFromFloat(seconds * 1000);
            }
        }
    }

    return time;
}
