const std = @import("std");
const log = @import("util.zig").log;
const term = @import("terminal.zig");
const mem = std.mem;
const fmt = std.fmt;
const proc = std.process;
const fs = std.fs;

const helpmsg =
    \\-H, --host <str>      MPD host (default: 127.0.0.1)
    \\-p, --port <u16>      MPD port (default: 6600)
    \\-h, --help            Print help
    \\-v, --version         Print version
    \\
;

const no_mpd_msg: []const u8 =
    \\error:    No MPD server found at "{s}:{}"
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

const version = "0.9.2";

pub const ArgumentValues = struct {
    host: ?[]const u8,
    port: ?u16,
    help: bool,
    version: bool,
};
pub fn handleArgs(persAllocator: mem.Allocator) !ArgumentValues {
    var arg_val = ArgumentValues{
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
            const val = args.next() orelse return error.InvalidArgument;
            const port = try fmt.parseUnsigned(u16, val, 10);
            arg_val.port = port;
            log("port: {}", .{port});
        } else if (mem.eql(u8, arg, "-H") or mem.eql(u8, arg, "--host")) {
            const val = args.next() orelse return error.InvalidArgument;
            const host = try persAllocator.dupe(u8, val);
            arg_val.host = host;
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
            return error.InvalidArgument;
        }
    }
    return arg_val;
}

pub fn printMpdFail(allocator: mem.Allocator, host: ?[]const u8, port: ?u16) !void {
    const tty = try getTty();
    const msg: []const u8 = try fmt.allocPrint(allocator, no_mpd_msg, .{
        host orelse "127.0.0.1",
        port orelse 6600,
    });
    try tty.writeAll(msg);
    tty.close();
}

pub fn printInvArg() !void {
    const tty = try getTty();
    try tty.writeAll(inv_arg_msg);
    tty.close();
}

fn getTty() !fs.File {
    const file = try fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = .write_only },
    );
    return file;
}
