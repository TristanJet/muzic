const std = @import("std");
const util = @import("util.zig");
const c = @cImport({
    @cInclude("../include/mpd/client.h");
});
const net = std.net;
var conn: ?*c.struct_mpd_connection = null;
var stream: std.net.Stream = undefined;

pub const Song = struct {
    title: ?[]const u8,
    artist: ?[]const u8,
    album: ?[]const u8,
    trackno: ?[]const u8,

    pub fn getTitle(self: Song) []const u8 {
        return self.title orelse "";
    }

    pub fn getArtist(self: Song) []const u8 {
        return self.artist orelse "";
    }
    pub fn getAlbum(self: Song) []const u8 {
        return self.album orelse "";
    }
    pub fn getTrackno(self: Song) []const u8 {
        return self.trackno orelse "";
    }
};

pub const Time = struct {
    elapsed: u32,
    duration: u32,
};

pub fn connect() !void {
    const peer = try net.Address.parseIp4("127.0.0.1", 8538);
    // Connect to peer
    stream = try net.tcpConnectToAddress(peer);

    var buffer: [64]u8 = undefined;
    const bytes_read = try stream.read(&buffer);
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
    storallocator: std.mem.Allocator,
    end_index: *usize,
) !Song {
    try connSend("currentsong\n");
    var buf_reader = std.io.bufferedReader(stream.reader());
    var reader = buf_reader.reader();

    var song = Song{
        .title = null,
        .artist = null,
        .album = null,
        .trackno = null,
    };

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
                song.title = try storallocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "Artist")) {
                song.artist = try storallocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "Album")) {
                song.album = try storallocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "Track")) {
                song.trackno = try storallocator.dupe(u8, value);
            }
        }
    }

    return song;
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
                time.elapsed = @intFromFloat(try std.fmt.parseFloat(f64, value));
            } else if (std.mem.eql(u8, key, "duration")) {
                time.duration = @intFromFloat(try std.fmt.parseFloat(f64, value));
            }
        }
    }

    return time;
}
