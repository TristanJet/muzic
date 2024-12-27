const std = @import("std");
const util = @import("util.zig");
const net = std.net;
var stream: std.net.Stream = undefined;

pub const Song = struct {
    pub const MAX_LEN = 64;

    titleBuf: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    titleLen: u8 = 0,
    artistBuf: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    artistLen: u8 = 0,
    albumBuf: [MAX_LEN]u8 = [_]u8{0} ** MAX_LEN,
    albumLen: u8 = 0,
    tracknoBuf: [2]u8 = [_]u8{0} ** 2,
    tracknoLen: u8 = 0,

    pub fn setTitle(self: *Song, title: []const u8) !void {
        if (title.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.titleBuf[0..title.len], title);
        self.titleLen = @intCast(title.len);
    }

    pub fn getTitle(self: *const Song) []const u8 {
        return self.titleBuf[0..self.titleLen];
    }

    pub fn setArtist(self: *Song, artist: []const u8) !void {
        if (artist.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.artistBuf[0..artist.len], artist);
        self.artistLen = @intCast(artist.len);
    }

    pub fn getArtist(self: *const Song) []const u8 {
        return self.artistBuf[0..self.artistLen];
    }

    pub fn setAlbum(self: *Song, album: []const u8) !void {
        if (album.len > MAX_LEN) return error.TooLong;
        std.mem.copyForwards(u8, self.albumBuf[0..album.len], album);
        self.albumLen = @intCast(album.len);
    }

    pub fn getAlbum(self: *const Song) []const u8 {
        return self.albumBuf[0..self.albumLen];
    }

    pub fn setTrackno(self: *Song, trackno: []const u8) !void {
        if (trackno.len > 2) return error.TooLong;
        std.mem.copyForwards(u8, self.tracknoBuf[0..trackno.len], trackno);
        self.tracknoLen = @intCast(trackno.len);
    }

    pub fn getTrackno(self: *const Song) []const u8 {
        return self.tracknoBuf[0..self.tracknoLen];
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
) !Song {
    try connSend("currentsong\n");
    var buf_reader = std.io.bufferedReader(stream.reader());
    var reader = buf_reader.reader();

    var song: Song = Song{};

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

    return song;
}

test "currentsong" {
    var wrkbuf: [1024]u8 = undefined;
    var wrkfba = std.heap.FixedBufferAllocator.init(&wrkbuf);
    const wrkallocator = wrkfba.allocator();

    _ = try connect(wrkbuf[0..16]);

    const song = try getCurrentSong(wrkallocator, &wrkfba.end_index);
    // Print the raw buffer contents
    // std.debug.print("\nFull string buffer contents: ", .{});
    // for (song.titleBuf) |c| {
    //     if (c == 0) {
    //         std.debug.print("0 ", .{});
    //     } else {
    //         std.debug.print("{c}({}) ", .{ c, c });
    //     }
    // }
    // std.debug.print("\n", .{});

    std.debug.print("title slice: '{s}' (len: {})\n", .{ song.titleBuf[0..song.titleLen], song.titleLen });
    std.debug.print("artist slice: '{s}' (len: {})\n", .{ song.artistBuf[0..song.artistLen], song.artistLen });
    std.debug.print("album slice: '{s}' (len: {})\n", .{ song.albumBuf[0..song.albumLen], song.albumLen });

    // Test with the actual value from MPD
    const expectedTitle = "Feenin'";
    const expectedArtist = "Jodeci";
    const expectedAlbum = "Diary of a Mad Band";
    const expectedTrackno = "3";
    try std.testing.expectEqualStrings(expectedTitle, song.getTitle());
    try std.testing.expectEqualStrings(expectedTitle, song.titleBuf[0..song.titleLen]);
    try std.testing.expectEqualSlices(u8, expectedTitle, song.titleBuf[0..song.titleLen]);
    try std.testing.expectEqualStrings(expectedArtist, song.getArtist());
    try std.testing.expectEqualStrings(expectedArtist, song.artistBuf[0..song.artistLen]);
    try std.testing.expectEqualSlices(u8, expectedArtist, song.artistBuf[0..song.artistLen]);
    try std.testing.expectEqualStrings(expectedAlbum, song.getAlbum());
    try std.testing.expectEqualStrings(expectedAlbum, song.albumBuf[0..song.albumLen]);
    try std.testing.expectEqualSlices(u8, expectedAlbum, song.albumBuf[0..song.albumLen]);
    try std.testing.expectEqualStrings(expectedTrackno, song.tracknoBuf[0..song.tracknoLen]);
    try std.testing.expectEqualSlices(u8, expectedTrackno, song.tracknoBuf[0..song.tracknoLen]);
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
