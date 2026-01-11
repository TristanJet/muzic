const std = @import("std");
const builtin = @import("builtin");
const log = @import("util.zig").log;
const term = @import("terminal.zig");
const win = @import("window.zig");
const mem = std.mem;
const fmt = std.fmt;
const proc = std.process;
const fs = std.fs;
const net = std.net;

const helpmsg =
    \\-H, --host <str>      MPD host (default: 127.0.0.1)
    \\-p, --port <u16>      MPD port (default: 6600)
    \\-h, --help            Print help
    \\-v, --version         Print version
    \\
;

const no_mpd_msg: []const u8 =
    \\error:    No MPD server found at "{}.{}.{}.{}:{}"
    \\info:     You can pass in a host and port using the "--host" and "--port" cli options
    \\info:     You can use the -h argument to print the help message
    \\
;

const inv_arg_msg: []const u8 =
    \\error:    Invalid argument
    \\info:     Usage: muzi [options]
    \\info:     You can use the -h argument to print the help message
    \\
;

const inv_ipv4_msg: []const u8 =
    \\error:    Invalid {s}
    \\info:     You can use the -h argument to print the help message
    \\
;

const win_too_small: []const u8 =
    \\error:    Window size too small
    \\info:     Muzi requires a minimum width and height of {} and {} cells
    \\
;

const version = "1.0.0-dev";

pub const OptionValues = struct {
    host: ?[4]u8,
    port: ?u16,
    help: bool,
    version: bool,
};

pub fn handleArgs() !OptionValues {
    var arg_val = OptionValues{
        .host = null,
        .port = null,
        .help = false,
        .version = false,
    };
    var args = proc.args();
    var isFirst: bool = true;
    while (args.next()) |arg| {
        if (isFirst) {
            isFirst = false;
            continue;
        }
        if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse return error.InvalidOption;
            const port = fmt.parseUnsigned(u16, val, 10) catch return InvalidIPv4Error.InvalidPort;
            arg_val.port = port;
            log("port: {}", .{port});
        } else if (mem.eql(u8, arg, "-H") or mem.eql(u8, arg, "--host")) {
            const val = args.next() orelse return error.InvalidOption;
            arg_val.host = validIpv4(val) catch return InvalidIPv4Error.InvalidHost;
            log("host: {s}", .{val});
        } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            arg_val.help = true;
            const tty = try getTty();
            try tty.writeAll(helpmsg[0..]);
            tty.close();
        } else if (mem.eql(u8, arg, "-v") or mem.eql(u8, arg, "--version")) {
            arg_val.version = true;
            const tty = try getTty();
            try tty.writeAll(version ++ "\n");
            tty.close();
        } else {
            return error.InvalidOption;
        }
    }
    return arg_val;
}

pub const InvalidIPv4Error = error{
    InvalidHost,
    InvalidPort,
};

fn validIpv4(sl: []const u8) ![4]u8 {
    var iter = mem.splitScalar(u8, sl, '.');
    var addr: [4]u8 = undefined;
    var counter: u8 = 0;
    while (iter.next()) |i| : (counter += 1) {
        if (counter > 3) return error.Overflow;
        addr[counter] = try fmt.parseInt(u8, i, 10);
    }
    return addr;
}

test "validIp" {
    const str: []const u8 = "127.0.0.1";
    const addy = try validIpv4(str);
    try std.testing.expect(addy[0] == 127);
    try std.testing.expect(addy[3] == 1);
}

pub fn printMpdFail(allocator: mem.Allocator, host: ?[4]u8, port: ?u16) !void {
    const tty = try getTty();
    defer tty.close();
    const msg: []const u8 = if (host) |arr|
        try fmt.allocPrint(allocator, no_mpd_msg, .{
            arr[0],
            arr[1],
            arr[2],
            arr[3],
            port orelse 6600,
        })
    else
        try fmt.allocPrint(allocator, no_mpd_msg, .{
            127,
            0,
            0,
            1,
            port orelse 6600,
        });
    try tty.writeAll(msg);
}

pub fn printInvArg() !void {
    const tty = try getTty();
    defer tty.close();
    try tty.writeAll(inv_arg_msg);
}

pub fn printInvIp4(allocator: mem.Allocator, e: InvalidIPv4Error) !void {
    const tty = try getTty();
    defer tty.close();
    const arg: []const u8 = switch (e) {
        InvalidIPv4Error.InvalidHost => "host",
        InvalidIPv4Error.InvalidPort => "port",
    };
    const msg: []const u8 = try fmt.allocPrint(allocator, inv_ipv4_msg, .{arg});
    try tty.writeAll(msg);
}

pub fn printWinSmall(allocator: mem.Allocator) !void {
    const tty = try getTty();
    defer tty.close();
    const msg: []const u8 = try fmt.allocPrint(allocator, win_too_small, .{ win.MIN_WIN_WIDTH, win.MIN_WIN_HEIGHT });
    try tty.writeAll(msg);
}

fn getTty() !fs.File {
    const file = try fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = .write_only },
    );
    return file;
}
