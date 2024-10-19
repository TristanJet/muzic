const std = @import("std");
const util = @import("util.zig");
const c = @cImport({
    @cInclude("../include/mpd/client.h");
});
var conn: ?*c.struct_mpd_connection = null;

pub const Song = struct {
    uri: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    trackno: []const u8,
};

pub const Time = struct {
    elapsed: u32,
    total: u32,
};

pub fn connect() !void {
    conn = c.mpd_connection_new(null, 8538, 0) orelse return error.ConnectionFailed;
}

pub fn disconnect() void {
    c.mpd_connection_free(conn);
}

pub fn getCurrentSong(allocator: std.mem.Allocator) !Song {
    const song = c.mpd_run_current_song(conn) orelse {
        if (c.mpd_connection_get_error(conn) != c.MPD_ERROR_SUCCESS) {
            return error.MPDError;
        }
        return error.NoCurrentSong;
    };
    defer c.mpd_song_free(song);

    const uri = if (c.mpd_song_get_uri(song)) |uri_ptr|
        try allocator.dupe(u8, std.mem.span(uri_ptr))
    else
        try allocator.dupe(u8, "");
    const title = if (c.mpd_song_get_tag(song, c.MPD_TAG_TITLE, 0)) |title_ptr|
        try allocator.dupe(u8, std.mem.span(title_ptr))
    else
        try allocator.dupe(u8, "");
    const artist = if (c.mpd_song_get_tag(song, c.MPD_TAG_ARTIST, 0)) |artist_ptr|
        try allocator.dupe(u8, std.mem.span(artist_ptr))
    else
        try allocator.dupe(u8, "");
    const album = if (c.mpd_song_get_tag(song, c.MPD_TAG_ALBUM, 0)) |album_ptr|
        try allocator.dupe(u8, std.mem.span(album_ptr))
    else
        try allocator.dupe(u8, "");
    const trackno = if (c.mpd_song_get_tag(song, c.MPD_TAG_TRACK, 0)) |trackno_ptr|
        try allocator.dupe(u8, std.mem.span(trackno_ptr))
    else
        try allocator.dupe(u8, "");

    return Song{
        .uri = uri,
        .title = title,
        .artist = artist,
        .album = album,
        .trackno = trackno,
    };
}

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
