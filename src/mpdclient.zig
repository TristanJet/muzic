const std = @import("std");
const c = @cImport({
    @cInclude("../include/mpd/client.h");
});

pub const Song = struct {
    uri: ?[]const u8,
    title: ?[]const u8,
    artist: ?[]const u8,
    duration: i32,
};

pub fn getCurrentSong() !Song {
    const con = c.mpd_connection_new(null, 8538, 0) orelse return error.ConnectionFailed;
    defer c.mpd_connection_free(con);

    const song = c.mpd_run_current_song(con) orelse {
        if (c.mpd_connection_get_error(con) != c.MPD_ERROR_SUCCESS) {
            return error.MPDError;
        }
        return error.NoCurrentSong;
    };
    defer c.mpd_song_free(song);

    // Now you can access the song data using the C API functions
    if (c.mpd_song_get_uri(song)) |uri| {
        std.debug.print("URI: {s}\n", .{uri});
    }

    if (c.mpd_song_get_tag(song, c.MPD_TAG_TITLE, 0)) |title| {
        std.debug.print("Title: {s}\n", .{title});
    }

    if (c.mpd_song_get_tag(song, c.MPD_TAG_ARTIST, 0)) |artist| {
        std.debug.print("Artist: {s}\n", .{artist});
    }

    const duration = c.mpd_song_get_duration(song);
    std.debug.print("Duration: {} seconds\n", .{duration});
    return Song{
        .uri = if (c.mpd_song_get_uri(song)) |uri| std.mem.span(uri) else null,
        .title = if (c.mpd_song_get_tag(song, c.MPD_TAG_TITLE, 0)) |title| std.mem.span(title) else null,
        .artist = if (c.mpd_song_get_tag(song, c.MPD_TAG_ARTIST, 0)) |artist| std.mem.span(artist) else null,
        .duration = @intCast(c.mpd_song_get_duration(song)),
    };
}
