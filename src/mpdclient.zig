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
        return self.artist orelse "";
    }
    pub fn getTrackno(self: Song) []const u8 {
        return self.trackno orelse "";
    }
};

pub const Time = struct {
    elapsed: u32,
    total: u32,
};

pub fn connect() !void {
    const peer = try net.Address.parseIp4("127.0.0.1", 8538);
    // Connect to peer
    stream = try net.tcpConnectToAddress(peer);
    util.log("Connecting to {}\n", .{peer});

    var buffer: [64]u8 = undefined;
    const bytes_read = try stream.read(&buffer);
    const received_data = buffer[0..bytes_read];
    util.log("Read: {s}\n", .{received_data});

    if (bytes_read < 2 or !std.mem.eql(u8, received_data[0..2], "OK")) {
        util.log("BAD! connection", .{});
        return error.InvalidResponse;
    } else {
        util.log("ALL goood", .{});
    }
}

fn connSend(data: []const u8) !void {
    // Sending data to peer
    var writer = stream.writer();
    const size = try writer.write(data);
    util.log("Sending '{s}' to peer, total written: {d} bytes\n", .{ data, size });
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
    util.log("start point: {}", .{startPoint});
    while (true) {
        defer end_index.* = startPoint;
        util.log("0?: {}", .{startPoint});
        var line = try reader.readUntilDelimiterAlloc(worallocator, '\n', 1024);
        util.log("line content: {s}", .{line});
        util.log("line length: {}", .{line.len});
        util.log("line length?: {}", .{end_index.*});

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

// pub fn getCurrentSong(allocator: std.mem.Allocator) !Song {
//     const song = c.mpd_run_current_song(conn) orelse {
//         if (c.mpd_connection_get_error(conn) != c.MPD_ERROR_SUCCESS) {
//             return error.MPDError;
//         }
//         return error.NoCurrentSong;
//     };
//     defer c.mpd_song_free(song);
//
//     const uri = if (c.mpd_song_get_uri(song)) |uri_ptr|
//         try allocator.dupe(u8, std.mem.span(uri_ptr))
//     else
//         try allocator.dupe(u8, "");
//     const title = if (c.mpd_song_get_tag(song, c.MPD_TAG_TITLE, 0)) |title_ptr|
//         try allocator.dupe(u8, std.mem.span(title_ptr))
//     else
//         try allocator.dupe(u8, "");
//     const artist = if (c.mpd_song_get_tag(song, c.MPD_TAG_ARTIST, 0)) |artist_ptr|
//         try allocator.dupe(u8, std.mem.span(artist_ptr))
//     else
//         try allocator.dupe(u8, "");
//     const album = if (c.mpd_song_get_tag(song, c.MPD_TAG_ALBUM, 0)) |album_ptr|
//         try allocator.dupe(u8, std.mem.span(album_ptr))
//     else
//         try allocator.dupe(u8, "");
//     const trackno = if (c.mpd_song_get_tag(song, c.MPD_TAG_TRACK, 0)) |trackno_ptr|
//         try allocator.dupe(u8, std.mem.span(trackno_ptr))
//     else
//         try allocator.dupe(u8, "");
//
//     return Song{
//         .uri = uri,
//         .title = title,
//         .artist = artist,
//         .album = album,
//         .trackno = trackno,
//     };
// }

pub fn get_status() !Time {
    const status_ptr: ?*c.mpd_status = c.mpd_run_status(conn);
    if (status_ptr == null) {
        return error.FailedToGetStatus;
    }

    // const state = c.mpd_status_get_state(status_ptr);
    // const volume = c.mpd_status_get_volume(status_ptr);
    const elapsed_time = c.mpd_status_get_elapsed_time(status_ptr);
    const total_time = c.mpd_status_get_total_time(status_ptr);
    //
    // util.log("MPD Status:", .{});
    // util.log("  State: {s}", .{mpdStateToString(state)});
    // util.log("  Volume: {}%", .{volume});
    // util.log("  Elapsed time: {} seconds", .{elapsed_time});
    // util.log("  Total time: {} seconds", .{total_time});

    c.mpd_status_free(status_ptr);

    return Time{
        .elapsed = elapsed_time,
        .total = total_time,
    };
}

fn mpdStateToString(state: c.mpd_state) []const u8 {
    return switch (state) {
        c.MPD_STATE_UNKNOWN => "unknown",
        c.MPD_STATE_STOP => "stop",
        c.MPD_STATE_PLAY => "play",
        c.MPD_STATE_PAUSE => "pause",
        else => "invalid",
    };
}
