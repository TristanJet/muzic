const std = @import("std");
const util = @import("util.zig");
const state = @import("state.zig");
const ring = @import("ring.zig");
const Ring = ring.Ring;
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

pub const Error = StreamError || MpdError || MemoryError;

pub const StreamError = error{
    ServerNotFound,
    ConnectionError,
    ReadError,
    WriteError,
    InvalidResponse,
    EndOfStream,
    FcntlError,
};

pub const MemoryError = error{
    AllocatorError,
    OutOfMemory,
};

pub const MpdError = error{
    Invalid,
    TooLong,
    NoSongs,
    NotPlaying,
    BadIndex,
};

/// Common function to handle setting string values in a fixed buffer
fn setStringValue(buffer: []u8, value: []const u8, max_len: usize) []const u8 {
    if (value.len > max_len) {
        mem.copyForwards(u8, buffer, value[0..max_len]);
        return buffer[0..max_len];
    }
    mem.copyForwards(u8, buffer, value);
    return buffer[0..value.len];
}

/// Sends an MPD command and checks for OK response
fn sendCommand(command: []const u8) (StreamError || MpdError)!void {
    connSend(command, &cmdStream) catch return StreamError.WriteError;
    _ = cmdStream.read(&cmdBuf) catch return StreamError.ReadError;
    if (mem.eql(u8, cmdBuf[0..3], "OK\n")) return;
    if (mem.eql(u8, cmdBuf[0..3], "ACK")) {
        const mpd_err = cmdBuf[5..9];
        if (mem.eql(u8, mpd_err, "55@0")) return MpdError.NotPlaying;
        if (mem.eql(u8, mpd_err[0..3], "2@0")) return MpdError.BadIndex;
        return MpdError.Invalid;
    }
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
        var line = reader.readUntilDelimiterAlloc(allocator, '\n', 1024) catch return StreamError.ReadError;

        if (mem.eql(u8, line, "OK")) break;
        if (mem.startsWith(u8, line, "ACK")) return MpdError.Invalid;

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
    pub const MAX_LEN = 64;
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

    pub fn setTitle(self: *CurrentSong, title: []const u8) void {
        self.title = setStringValue(&self.bufTitle, title, MAX_LEN);
    }

    pub fn setArtist(self: *CurrentSong, artist: []const u8) void {
        self.artist = setStringValue(&self.bufArtist, artist, MAX_LEN);
    }

    pub fn setAlbum(self: *CurrentSong, album: []const u8) void {
        self.album = setStringValue(&self.bufAlbum, album, MAX_LEN);
    }

    pub fn setTrackno(self: *CurrentSong, trackno: []const u8) void {
        self.trackno = setStringValue(&self.bufTrackno, trackno, TRACKNO_LEN);
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
            self.setTrackno(value);
        } else if (mem.eql(u8, key, "Album")) {
            self.setAlbum(value);
        } else if (mem.eql(u8, key, "Title")) {
            self.setTitle(value);
        } else if (mem.eql(u8, key, "Artist")) {
            self.setArtist(value);
        } else if (mem.eql(u8, key, "time")) {
            if (mem.indexOfScalar(u8, value, ':')) |index| {
                const elapsedSlice = value[0..index];
                self.time.elapsed = try fmt.parseInt(u16, elapsedSlice, 10);
                const durationSlice = value[index + 1 ..];
                self.time.duration = try fmt.parseInt(u16, durationSlice, 10);
            } else return MpdError.Invalid;
        }
    }
};

pub fn handleArgs(arg_host: ?[4]u8, arg_port: ?u16) void {
    if (arg_host) |arg| host = arg;
    if (arg_port) |arg| port = arg;
}

pub fn connect(stream_type: StreamType, nonblock: bool) (StreamError || MpdError)!void {
    const peer = net.Address.initIp4(host, port);
    // Connect to peer
    const stream = switch (stream_type) {
        .idle => &idleStream,
        .command => &cmdStream,
    };

    stream.* = net.tcpConnectToAddress(peer) catch return StreamError.ServerNotFound;

    const bytes_read = stream.read(&cmdBuf) catch return StreamError.ReadError;
    const received_data = cmdBuf[0..bytes_read];

    if (bytes_read < 2 or !mem.eql(u8, received_data[0..2], "OK")) return MpdError.Invalid;

    if (nonblock) {
        const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return StreamError.FcntlError;
        const updated = std.posix.fcntl(stream.handle, std.posix.F.SETFL, util.flagNonBlock(flags)) catch return StreamError.FcntlError;
        if ((updated & 0x0004) != 0) return StreamError.FcntlError;
    }
}

pub fn checkConnection() !void {
    try sendCommand("ping\n");
}

//the writer could be global
fn connSend(data: []const u8, stream: *std.net.Stream) StreamError!void {
    var writer = stream.writer();
    _ = writer.write(data) catch return StreamError.WriteError;
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
        if (mem.startsWith(u8, line, "ACK")) return MpdError.Invalid;

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

pub fn changeVol(dir: enum { up, down }, change: u8) !void {
    const command: []const u8 = switch (dir) {
        .up => try fmt.bufPrint(&cmdBuf, "volume +{}\n", .{change}),
        .down => try fmt.bufPrint(&cmdBuf, "volume -{}\n", .{change}),
    };
    try sendCommand(command);
}

pub fn nextSong() !void {
    sendCommand("next\n") catch |e| switch (e) {
        MpdError.NotPlaying => return,
        else => return e,
    };
}

pub fn prevSong() !void {
    sendCommand("previous\n") catch |e| switch (e) {
        MpdError.NotPlaying => return,
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
    const Dir = enum { forward, backward };
    const Add = enum { full, half };
    NSONGS: usize,
    ADD_SIZE: usize,
    pl_len: usize,
    ibufferstart: usize,
    fill: usize,
    itopviewport: usize,
    nviewable: usize,
    ring: Ring,
    songbuf: ring.Buffer(QSong),
    edgebuf: struct { ?[]QSong, ?[]QSong },
    edge: ?Edge,
    artistbuf: ring.StrBuffer(QSong.MAX_STR_LEN),
    titlebuf: ring.StrBuffer(QSong.MAX_STR_LEN),
    bound: Boundary,

    pub fn init(respAllocator: mem.Allocator, persAllocator: mem.Allocator, nviewable: usize) !Queue {
        const nsongs = util.nextPowerOfTwo(2 * nviewable);
        util.log("nsongs: {}", .{nsongs});
        debug.assert(nsongs >= 2 * nviewable);
        const plen = try getPlaylistLen(respAllocator);
        const bstart: usize = if (plen > nsongs) nviewable else 0;
        const bend: usize = if (plen > nsongs + nviewable) plen - nviewable else plen;
        return Queue{
            .NSONGS = nsongs,
            .ADD_SIZE = nsongs / 2,
            .pl_len = plen,
            .ibufferstart = bstart,
            .itopviewport = 0,
            .fill = 0,
            .nviewable = nviewable,
            .ring = Ring{
                .first = 0,
                .stop = 0,
                .fill = 0,
                .size = nsongs,
            },
            .songbuf = try ring.Buffer(QSong).init(nsongs, persAllocator),
            .edgebuf = .{ null, null },
            .edge = null,
            .artistbuf = try ring.StrBuffer(QSong.MAX_STR_LEN).init(nsongs, persAllocator),
            .titlebuf = try ring.StrBuffer(QSong.MAX_STR_LEN).init(nsongs, persAllocator),
            .bound = Boundary{
                .bstart = bstart,
                .bend = bend,
            },
        };
    }

    pub fn reset(self: *Queue, respAllocator: mem.Allocator) !void {
        const plen = try getPlaylistLen(respAllocator);
        const bstart: usize = if (plen > self.NSONGS) self.nviewable else 0;
        const bend: usize = if (plen > self.NSONGS + self.nviewable) plen - self.nviewable else plen;
        self.pl_len = plen;
        self.fill = 0;
        self.edgebuf = .{ null, null };
        self.ring = Ring{
            .first = 0,
            .stop = 0,
            .fill = 0,
            .size = self.NSONGS,
        };
        self.bound = Boundary{
            .bstart = bstart,
            .bend = bend,
        };
    }

    pub fn getForward(self: *Queue, respAllocator: mem.Allocator) !usize {
        util.log("get forward", .{});
        const added = try getQueue(self, .forward, respAllocator, self.ADD_SIZE);
        self.ibufferstart += added;
        self.fill = @min(self.NSONGS, self.fill + added);
        return added;
    }

    pub fn initialFill(self: *Queue, ra: mem.Allocator, pa: mem.Allocator) !void {
        debug.assert(self.fill == 0);
        if (self.pl_len > self.NSONGS) {
            self.edge = self.edge orelse try Edge.init(self.nviewable, pa);
            self.edgebuf = try self.edge.?.getEdgeBuffers(self.NSONGS, self.pl_len, self.nviewable, ra);
            self.bound = Boundary{
                .bstart = self.nviewable,
                .bend = if (self.edgebuf[1]) |_| self.pl_len - self.nviewable else self.pl_len,
            };
        }
        self.fill += try getQueue(self, .forward, ra, self.NSONGS);
    }

    pub fn refill(self: *Queue, ra: mem.Allocator) !void {
        self.fill = 0;
        self.ring = Ring{
            .first = 0,
            .stop = 0,
            .fill = 0,
            .size = self.NSONGS,
        };
        self.fill += try getQueue(self, .forward, ra, self.NSONGS);
    }

    pub fn getBackward(self: *Queue, respAllocator: mem.Allocator) !usize {
        util.log("get backward", .{});
        const added = try getQueue(self, .backward, respAllocator, self.ADD_SIZE);
        self.ibufferstart -= added;
        self.fill = @min(self.NSONGS, self.fill + added);
        return added;
    }

    pub fn downBufferWrong(self: *Queue) bool {
        var buffer_wrong: bool = false;
        if (self.edgebuf[0]) |edge| {
            if (self.itopviewport + self.nviewable >= edge.len + 1 and
                self.itopviewport + self.nviewable < self.ibufferstart)
            {
                self.ibufferstart = edge.len;
                self.fill = 0;
                buffer_wrong = true;
            }
        }
        return buffer_wrong;
    }

    pub fn upBufferWrong(self: *Queue) bool {
        if (self.edgebuf[1]) |edge| {
            if (self.itopviewport <= self.pl_len - 1 - edge.len and
                self.itopviewport > self.ibufferstart + self.NSONGS - 1)
            {
                self.ibufferstart = self.itopviewport + 1;
                self.fill = 0;
                return true;
            }
        }
        return false;
    }

    pub fn jumpToPos(self: *Queue, pos: usize, inc: *usize) u8 {
        // This function only works reliably immediately after the Ring has been reset
        // because the inc won't be reliable once the ring buffer has been written to, I know this is bad.
        debug.assert(pos >= 0 and pos < self.pl_len);
        if (self.pl_len >= self.nviewable and pos > self.pl_len - self.nviewable) {
            self.itopviewport = self.pl_len - self.nviewable;
            self.ibufferstart = @max(self.bound.bstart, self.bound.bend -| self.NSONGS);
            inc.* = self.bound.bstart + (self.itopviewport - self.ibufferstart);
            return @intCast(pos - self.itopviewport);
        }

        if (pos <= self.nviewable) {
            self.itopviewport = @min(pos, self.pl_len -| self.nviewable);
            inc.* = self.itopviewport;
            self.ibufferstart = self.bound.bstart;
            return @intCast(pos - self.itopviewport);
        }

        self.itopviewport = pos;
        if (self.itopviewport < self.ibufferstart or self.itopviewport + self.nviewable - 1 > self.ibufferstart + self.NSONGS - 1) {
            self.ibufferstart = @max(pos -| (self.NSONGS / 2), self.bound.bstart);
        }
        inc.* = self.bound.bstart + (self.itopviewport - self.ibufferstart);
        return 0;
    }

    //Iterator just returns songs in buffers - not responsible for guaranteeing correct position.
    pub const Iterator = struct {
        index: usize,
        remaining: ?usize,
        ntop: usize,
        edgebuf: *const struct { ?[]QSong, ?[]QSong },
        itring: ring.Buffer(QSong).Iterator,

        pub fn next(it: *Iterator, inc: usize) ?QSong {
            if (it.edgebuf[0]) |top| {
                var index = it.index + inc;
                if (index < top.len and it.ntop > 0) {
                    it.index += 1;
                    it.ntop -= 1;
                    return top[index];
                }
                if (it.itring.next(inc -| top.len)) |song| {
                    it.index += 1;
                    return song;
                }
                if (it.edgebuf[1]) |bot| {
                    const rem = it.remaining orelse bot.len;
                    index = bot.len - rem;
                    if (index < bot.len) {
                        it.index += 1;
                        it.remaining = rem - 1;
                        return bot[index];
                    }
                }
            }

            if (it.itring.next(inc)) |song| {
                it.index += 1;
                return song;
            }

            return null;
        }
    };

    pub fn getIterator(self: *const Queue) !Iterator {
        return Iterator{
            .index = 0,
            .remaining = null,
            .ntop = self.nviewable -| self.itopviewport,
            .edgebuf = &self.edgebuf,
            .itring = self.songbuf.getIterator(self.ring),
        };
    }
};

const Edge = struct {
    songbuf: []QSong,
    strbuf: []u8,

    //Need to reset this if window height changes
    fn init(wheight: usize, pa: mem.Allocator) !Edge {
        util.log("edge size: {}", .{wheight});
        return .{
            .songbuf = try pa.alloc(QSong, 2 * wheight),
            .strbuf = try pa.alloc(u8, 2 * 2 * QSong.MAX_STR_LEN * wheight),
        };
    }

    fn getEdgeBuffers(self: *Edge, nsongs: usize, plen: usize, wheight: usize, ra: mem.Allocator) !struct { []QSong, ?[]QSong } {
        debug.assert(plen > nsongs);
        if (self.songbuf.len != 2 * wheight or self.strbuf.len != 2 * 2 * QSong.MAX_STR_LEN * wheight) return error.WindowHeightMismatch;

        var ittop = SongIterator{
            .buffer = try fetchQueueBuf(ra, 0, wheight),
            .index = 0,
            .ireverse = 0,
        };
        try queueToBuf(self.songbuf[0..wheight], self.strbuf[0 .. self.strbuf.len / 2], &ittop, plen);

        if (plen <= nsongs + wheight) return .{
            self.songbuf[0..wheight],
            null,
        };

        var itbottom = SongIterator{
            .buffer = try fetchQueueBuf(ra, plen - wheight, plen),
            .index = 0,
            .ireverse = 0,
        };
        try queueToBuf(self.songbuf[wheight..], self.strbuf[self.strbuf.len / 2 ..], &itbottom, plen);

        return .{
            self.songbuf[0..wheight],
            self.songbuf[wheight..],
        };
    }
};

test "queueinit" {
    const all = @import("allocators.zig");
    const pa = all.persistentAllocator;
    const ra = all.respAllocator;

    try connect(.command, false);

    const plen = try getPlaylistLen(ra);
    debug.print("plen: {}\n", .{plen});

    const wheight = 2;
    var queue = try Queue.init(ra, pa, wheight);
    try queue.initialFill(ra, pa);
    debug.print("itop: {}\n", .{queue.itopviewport});
    debug.print("fill: {}\n", .{queue.fill});
    var itq = try queue.getIterator();

    const inc: usize = 0;
    var count: usize = 0;
    while (itq.next(inc)) |song| {
        debug.print("{} ", .{count});
        count += 1;
        debug.print("{s}\n", .{song.title.?});
    }
    debug.print("-------------\n", .{});

    queue.itopviewport = plen -| wheight -| Queue.NSONGS;
    debug.print("itop: {}\n", .{queue.itopviewport});
    _ = try queue.getForward(ra);
    debug.print("fill: {}\n", .{queue.fill});
    // ringit = queue.songbuf.getIterator(queue.ring);
    itq = try queue.getIterator();
    count = 0;
    while (itq.next(inc)) |song| {
        debug.print("{} ", .{count});
        count += 1;
        debug.print("{s}\n", .{song.title.?});
    }
}

test "getedge" {
    const all = @import("allocators.zig");
    const pa = all.persistentAllocator;
    const ra = all.respAllocator;

    try connect(.command, false);

    const plen = try getPlaylistLen(ra);
    debug.print("plen: {}\n", .{plen});
    const edgebuf: struct { ?[]QSong, ?[]QSong } = try Queue.getEdgeBuffers(plen, 10, pa, ra);

    if (edgebuf[0]) |top| {
        debug.print("top:\n", .{});
        for (top) |song| {
            debug.print("song: {s}\n", .{song.title.?});
        }
    }
    if (edgebuf[1]) |bottom| {
        debug.print("bottom:\n", .{});
        for (bottom) |song| {
            debug.print("song: {s}\n", .{song.title.?});
        }
    }
}

test "iter" {
    const alloc = @import("allocators.zig");
    const wheight = 5;
    const edgetop: [5][]const u8 = .{ "Luffy", "Zoro", "Nami", "Sanji", "Usopp" };
    const edgebot: [5][]const u8 = .{ "Loki", "Carrot", "Bonny", "Momonosuke", "Ace" };
    const ringarr: [5][]const u8 = .{ "Chopper", "Vivi", "Brook", "Franky", "Yamato" };

    var edge: struct { ?[]QSong, ?[]QSong } = .{
        try alloc.persistentAllocator.alloc(QSong, wheight),
        try alloc.persistentAllocator.alloc(QSong, wheight),
    };
    var i: usize = 0;
    while (i < wheight) : (i += 1) {
        edge[0].?[i] = QSong{
            .artist = edgetop[i],
            .title = null,
            .time = 0,
            .pos = 0,
            .id = 0,
        };
    }

    i = 0;
    while (i < wheight) : (i += 1) {
        edge[1].?[i] = QSong{
            .artist = edgebot[i],
            .title = null,
            .time = 0,
            .pos = 0,
            .id = 0,
        };
    }

    var r = Ring{
        .size = ringarr.len,
        .first = 0,
        .stop = 0,
        .fill = 0,
    };
    var buf = try ring.Buffer(Queue.NSONGS, QSong).init(alloc.persistentAllocator);
    i = 0;
    while (i < ringarr.len) : (i += 1) {
        buf.forwardWrite(r, QSong{
            .artist = ringarr[i],
            .title = null,
            .time = 0,
            .pos = 0,
            .id = 0,
        });
        r.increment();
    }

    var itring = buf.getIterator(r);
    var itq = Queue.Iterator{
        .index = 0,
        .edgebuf = edge[0],
        .itring = &itring,
        .nextfn = &Queue.topNext,
    };
    var inc: usize = 0;
    while (itq.next(inc)) |song| {
        debug.print("{s}\n", .{song.artist.?});
    }

    itring = buf.getIterator(r);
    itq = Queue.Iterator{
        .index = 0,
        .edgebuf = edge[1],
        .itring = &itring,
        .nextfn = &Queue.botNext,
    };
    inc = 5;
    while (itq.next(inc)) |song| {
        debug.print("{s}\n", .{song.artist.?});
    }
}

pub const QSong = struct {
    pub const MAX_STR_LEN = 64;
    title: ?[]const u8,
    artist: ?[]const u8,
    time: ?u16,
    pos: ?usize,
    id: ?usize,
};

pub fn getPlaylistLen(respAllocator: mem.Allocator) !usize {
    const command = "status\n";
    const data = try readLargeResponse(respAllocator, command);
    var lines = try processLargeResponse(data);
    while (lines.next()) |line| {
        if (mem.startsWith(u8, line, "playlistlength:")) {
            const slice = mem.trimLeft(u8, line[15..], " ");
            return try fmt.parseUnsigned(usize, slice, 10);
        }
    }
    return error.NoLength;
}

pub fn getQueue(queue: *Queue, dir: Queue.Dir, ra: mem.Allocator, addsize: usize) !usize {
    debug.assert(queue.fill <= queue.NSONGS);

    var songs: SongIterator = undefined;
    switch (dir) {
        .forward => {
            const start, const end = queue.bound.checkBoundary(queue.ibufferstart + queue.fill, queue.ibufferstart + queue.fill + addsize);
            songs = SongIterator{
                .buffer = try fetchQueueBuf(ra, start, end),
                .index = 0,
                .ireverse = 0,
            };
        },
        .backward => {
            const start, const end = queue.bound.checkBoundary(queue.ibufferstart -| addsize, queue.ibufferstart);
            const buf = try fetchQueueBuf(ra, start, end);
            songs = SongIterator{
                .buffer = buf,
                .index = 0,
                .ireverse = buf.len,
            };
        },
    }
    return try allocQueue(&songs, dir, &queue.ring, &queue.songbuf, &queue.titlebuf, &queue.artistbuf, addsize);
}

const Boundary = struct {
    bstart: usize,
    bend: usize,

    fn checkBoundary(self: Boundary, start: usize, end: usize) struct { usize, usize } {
        return .{ @max(start, self.bstart), @min(end, self.bend) };
    }
};

fn fetchQueueBuf(respAllocator: mem.Allocator, start: usize, end: usize) ![]const u8 {
    const command = try fmt.allocPrint(respAllocator, "playlistinfo {}:{}\n", .{ start, end });
    return try readLargeResponse(respAllocator, command);
}

fn allocQueue(
    songs: *SongIterator,
    dir: Queue.Dir,
    r: *Ring,
    songbuf: *ring.Buffer(QSong),
    titlebuf: *ring.StrBuffer(QSong.MAX_STR_LEN),
    artistbuf: *ring.StrBuffer(QSong.MAX_STR_LEN),
    N: usize,
) !usize {
    var current: QSong = undefined;
    var lines: mem.SplitIterator(u8, .scalar) = undefined;
    var next: *const fn (*SongIterator) ?[]const u8 = undefined;
    var strwrite: *const fn (*ring.StrBuffer(QSong.MAX_STR_LEN), Ring, []const u8) []const u8 = undefined;
    var songwrite: *const fn (*ring.Buffer(QSong), Ring, QSong) void = undefined;
    var ringUpdate: *const fn (*ring.Ring) void = undefined;
    switch (dir) {
        .forward => {
            next = &SongIterator.next;
            strwrite = &ring.StrBuffer(QSong.MAX_STR_LEN).forwardWrite;
            songwrite = &ring.Buffer(QSong).forwardWrite;
            ringUpdate = &Ring.increment;
        },
        .backward => {
            next = &SongIterator.reverseNext;
            strwrite = &ring.StrBuffer(QSong.MAX_STR_LEN).backwardWrite;
            songwrite = &ring.Buffer(QSong).backwardWrite;
            ringUpdate = &Ring.decrement;
        },
    }
    var added: usize = 0;
    while (next(songs)) |song| {
        lines = mem.splitScalar(u8, song, '\n');
        while (lines.next()) |line| {
            if (mem.startsWith(u8, line, "Title:")) {
                const title = mem.trimLeft(u8, line[6..], " ");
                const copied = strwrite(titlebuf, r.*, title);
                current.title = copied;
            } else if (mem.startsWith(u8, line, "Artist:")) {
                const artist = mem.trimLeft(u8, line[7..], " ");
                const copied = strwrite(artistbuf, r.*, artist);
                current.artist = copied;
            } else if (mem.startsWith(u8, line, "Time:")) {
                const time_str = mem.trimLeft(u8, line[5..], " ");
                current.time = try std.fmt.parseInt(u16, time_str, 10);
            } else if (mem.startsWith(u8, line, "Pos:")) {
                const pos_str = mem.trimLeft(u8, line[4..], " ");
                current.pos = try fmt.parseInt(usize, pos_str, 10);
            } else if (mem.startsWith(u8, line, "Id:")) {
                const id_str = mem.trimLeft(u8, line[3..], " ");
                current.id = try fmt.parseInt(usize, id_str, 10);
            }
        }
        songwrite(songbuf, r.*, current);
        added += 1;
        ringUpdate(r);
        if (added == N) break;
    }
    return added;
}

fn queueToBuf(buf: []QSong, strbuf: []u8, songs: *SongIterator, N: usize) !void {
    var current: QSong = undefined;
    var lines: mem.SplitIterator(u8, .scalar) = undefined;
    var songi: usize = 0;
    var istr: usize = 0;
    while (songs.next()) |song| {
        lines = mem.splitScalar(u8, song, '\n');
        while (lines.next()) |line| {
            if (mem.startsWith(u8, line, "Title:")) {
                const title = mem.trimLeft(u8, line[6..], " ");
                @memcpy(strbuf[istr .. istr + title.len], title);
                current.title = strbuf[istr .. istr + title.len];
                istr += title.len;
            } else if (mem.startsWith(u8, line, "Artist:")) {
                const artist = mem.trimLeft(u8, line[7..], " ");
                @memcpy(strbuf[istr .. istr + artist.len], artist);
                current.artist = strbuf[istr .. istr + artist.len];
                istr += artist.len;
            } else if (mem.startsWith(u8, line, "Time:")) {
                const time_str = mem.trimLeft(u8, line[5..], " ");
                current.time = try fmt.parseInt(u16, time_str, 10);
            } else if (mem.startsWith(u8, line, "Pos:")) {
                const pos_str = mem.trimLeft(u8, line[4..], " ");
                current.pos = try fmt.parseInt(usize, pos_str, 10);
            } else if (mem.startsWith(u8, line, "Id:")) {
                const id_str = mem.trimLeft(u8, line[3..], " ");
                current.id = try fmt.parseInt(usize, id_str, 10);
            }
        }
        buf[songi] = current;
        songi += 1;
        if (songi == N) return;
    }
}

test "fill" {
    var heapArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer heapArena.deinit();
    const heapAllocator = heapArena.allocator();

    var respArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer respArena.deinit();
    const respAllocator = respArena.allocator();

    try connect(.command, false);

    var queue = try Queue.init(respAllocator, heapAllocator, 4);
    // _ = respArena.reset(.free_all);
    debug.print("------------\n", .{});
    debug.print("Iterator inc 0: \n", .{});
    var it = queue.titlebuf.getIterator(queue.ring);
    while (it.next(0)) |item| {
        debug.print("{s}\n", .{item});
    }

    debug.print("------------\n", .{});
    debug.print("Buf contents: \n", .{});
    for (queue.titlebuf.buf) |*buf| {
        const ptr: [*:0]const u8 = @ptrCast(buf);
        const str = mem.span(ptr);
        debug.print("{s}\n", .{str});
    }

    try allocQueue(&queue.song_it, .backward, &queue.ring, &queue.songbuf, &queue.titlebuf, &queue.artistbuf, 4);

    debug.print("------------\n", .{});
    debug.print("Buf contents: \n", .{});
    for (queue.titlebuf.buf) |*buf| {
        const ptr: [*:0]const u8 = @ptrCast(buf);
        const str = mem.span(ptr);
        debug.print("{s}\n", .{str});
    }

    debug.print("------------\n", .{});
    debug.print("Iterator inc 0: \n", .{});
    it = queue.titlebuf.getIterator(queue.ring);
    while (it.next(0)) |item| {
        debug.print("{s}\n", .{item});
    }

    debug.print("------------\n", .{});
    debug.print("Iterator inc 2: \n", .{});
    it = queue.titlebuf.getIterator(queue.ring);
    while (it.next(2)) |item| {
        debug.print("{s}\n", .{item});
    }
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
pub fn readLargeResponse(tempAllocator: mem.Allocator, command: []const u8) (StreamError || MpdError || MemoryError)![]u8 {
    try connSend(command, &cmdStream);

    var list = std.ArrayList(u8).init(tempAllocator);
    errdefer list.deinit();

    var firstbuf: [5]u8 = .{0} ** 5;
    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = cmdStream.read(buf[0..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return StreamError.ReadError,
        };

        if (firstbuf[0] == 0) {
            @memcpy(&firstbuf, buf[0..5]);
            if (mem.eql(u8, &firstbuf, "ACK [")) return MpdError.Invalid;
        }

        if (bytes_read == 0) {
            if (mem.endsWith(u8, list.items, "OK\n")) {
                break;
            } else {
                return MpdError.Invalid;
            }
        }

        list.appendSlice(buf[0..bytes_read]) catch return MemoryError.AllocatorError;

        if (mem.endsWith(u8, list.items, "OK\n")) {
            break;
        }
    }

    return list.toOwnedSlice() catch return MemoryError.AllocatorError;
}

const SongIterator = struct {
    buffer: []const u8,
    index: usize,
    ireverse: usize,

    pub fn next(self: *SongIterator) ?[]const u8 {
        if (self.index >= self.buffer.len) return null;

        // On first call, locate the start of the initial "file:" to skip headers.
        if (self.index == 0) {
            self.index = mem.indexOf(u8, self.buffer, "file:") orelse return null;
        }

        const start = self.index;
        // Search for the next "\nfile:" starting after the current "file:".
        const delim_pos = mem.indexOfPos(u8, self.buffer, start + 5, "\nfile:") orelse self.buffer.len;
        const song = self.buffer[start..delim_pos];
        // Advance to the start of the next "file:" (skip the '\n').
        self.index = delim_pos + 1;
        return song;
    }

    pub fn reverseNext(self: *SongIterator) ?[]const u8 {
        if (self.ireverse == 0) return null;

        const slice = self.buffer[0..self.ireverse];
        const pos = mem.lastIndexOf(u8, slice, "file:") orelse return null;

        const song = self.buffer[pos..self.ireverse];

        if (pos == 0) {
            self.ireverse = 0;
        } else {
            self.ireverse = pos - 1;
        }

        return song;
    }
};

fn processLargeResponse(bytes: []const u8) MpdError!mem.SplitIterator(u8, .scalar) {
    if (mem.startsWith(u8, bytes, "ACK")) return MpdError.Invalid;
    if (mem.startsWith(u8, bytes, "OK")) return MpdError.NoSongs;
    return mem.splitScalar(u8, bytes, '\n');
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

pub fn batchInsertUri(uris: []const []const u8, pos: usize, ra: mem.Allocator) !void {
    try connSend("command_list_begin\n", &cmdStream);
    for (uris, 1..uris.len + 1) |item, i| {
        const command = try fmt.allocPrint(ra, "add \"{s}\" {}\n", .{ item, pos + i });
        try connSend(command, &cmdStream);
    }
    try sendCommand("command_list_end\n");
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
        MpdError.NotPlaying => return,
        else => return e,
    };
}

pub fn rmRange(start: usize, stop: usize, ra: mem.Allocator) !void {
    const command = try fmt.allocPrint(ra, "delete {}:{}\n", .{ start, stop });
    try sendCommand(command);
}

pub const Yanked = struct {
    refs: ArrayList([]const u8),
    arena: *std.heap.ArenaAllocator,
    allocator: mem.Allocator,

    pub fn init(arena: *std.heap.ArenaAllocator) Yanked {
        const allocator = arena.allocator();
        return .{
            .refs = ArrayList([]const u8).init(allocator),
            .arena = arena,
            .allocator = allocator,
        };
    }

    fn append(self: *Yanked, src: []const u8) !void {
        try self.refs.append(try self.allocator.dupe(u8, src));
    }

    pub fn reset(self: *Yanked) !void {
        self.refs.shrinkAndFree(0);
        const success = self.arena.reset(.{ .retain_with_limit = 4096 });
        if (!success) return error.ArenaResetFail;
    }
};

pub fn getYanked(start: usize, stop: usize, out: *Yanked, ra: mem.Allocator) !void {
    const command = try fmt.allocPrint(ra, "playlistinfo {}:{}\n", .{ start, stop });
    const data = try readLargeResponse(ra, command);
    var lines = try processLargeResponse(data);
    try out.reset();
    while (lines.next()) |line| {
        if (mem.startsWith(u8, line, "file:")) {
            try out.append(mem.trimLeft(u8, line[5..], " "));
        }
    }
}

test "del" {
    const alloc = @import("allocators.zig");

    try connect(.command, false);

    var del = Yanked.init(&alloc.delArena);
    const start = 5;
    const plen = 31;
    try getYanked(start, plen, &del, alloc.respAllocator);
    debug.print("refs len: {}\n", .{del.refs.items.len});
    for (del.refs.items) |item| {
        debug.print("item: {s}\n", .{item});
    }
    debug.print("capacity: {}\n", .{del.refs.capacity});
    debug.print("end_index: {}\n", .{del.arena.queryCapacity()});
    try del.reset();
    debug.print("capacity: {}\n", .{del.refs.capacity});
    debug.print("end_index: {}\n", .{del.arena.queryCapacity()});
}

pub fn clearQueue() !void {
    try sendCommand("clear\n");
}
