const std = @import("std");
const c = @cImport({
    @cInclude("../include/mpd/client.h");
});

pub const Song = struct {
    uri: []const u8,
    title: []const u8,
    artist: []const u8,
    duration: u32,
};

pub fn getCurrentSong(allocator: std.mem.Allocator) !Song {
    const con = c.mpd_connection_new(null, 8538, 0) orelse return error.ConnectionFailed;
    defer c.mpd_connection_free(con);

    const song = c.mpd_run_current_song(con) orelse {
        if (c.mpd_connection_get_error(con) != c.MPD_ERROR_SUCCESS) {
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
    const duration = @as(u32, c.mpd_song_get_duration(song));

    return Song{
        .uri = uri,
        .title = title,
        .artist = artist,
        .duration = duration,
    };
}
